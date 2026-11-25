# Reference deployment — Proxmox VM + Tailscale + Caddy

This is how the maintainer actually runs `diabetes-stack`. It's a worked example, not a
requirement: the stack needs Docker, `sops`/`age`, Tailscale, and (for the custom name)
a DNS zone Caddy can write to. The host is a general-purpose Docker VM that will also
carry Plex and other services, so the stack keeps to its own pinned network and binds
nothing to the LAN.

## The host

| | |
|---|---|
| Hypervisor | Proxmox VE 9.2 on the home server (`192.168.4.10`) |
| Guest | VM 101 `docker-host`: Ubuntu 24.04 cloud image, 2 vCPU, 4 GiB RAM, 32 GiB disk on `local-lvm`, starts on host boot, QEMU guest agent on |
| LAN address | `192.168.4.12/24` (static in the guest, reserved on the router's DHCP) |
| Docker | Engine 29.x + Compose v5 |
| sops / age | sops 3.13 (`/usr/local/bin`), age 1.1 (apt) |
| Repo path | `/opt/diabetes` (a git clone) |
| Tailscale node | `docker-host` on tailnet `tail40c9b0.ts.net`, `100.65.38.92`, key expiry disabled |
| Public name | `nightscout.smittoid.com` → A record `100.65.38.92` (Route 53) |

Grow RAM and disk as other stacks land on the VM (`qm set 101 --memory …`,
`qm resize 101 scsi0 +…`).

## Network path

```
 phone / laptop / Home Assistant  (any tailnet device, anywhere)
        │  https://nightscout.smittoid.com  → public DNS → 100.65.38.92 (tailnet-only)
        ▼
 docker-host  tailscale0 100.65.38.92
        │  Caddy (host network) listens on 100.65.38.92:443 and :80 only
        ▼
 Nightscout  127.0.0.1:1337 (loopback publish)  ── diabetes-net 172.29.0.0/24 ──  mongo, tconnectsync
```

- **Tailnet-only, by binding, not by firewall.** Caddy binds the tailnet IP
  (`default_bind` in `config/caddy/Caddyfile`) and Nightscout publishes on loopback.
  `192.168.4.12:443` and `:1337` refuse connections.
- **Public DNS, private address.** Anyone can resolve the name; only tailnet devices
  can reach `100.65.38.92`.
- **TLS is Let's Encrypt via Route 53 DNS-01.** Let's Encrypt can't reach the site, so
  Caddy proves ownership with a TXT record. The IAM user `caddy-route53-nightscout` may
  write only `_acme-challenge.nightscout.smittoid.com` TXT; its key is
  `secrets/caddy.env.sops.yaml` (and 1Password). Certs persist in `data/caddy`.
- **`diabetes-net` stays pinned to `172.29.0.0/24`** so later stacks on this VM can't
  collide with it.

## Provisioning steps run

```bash
# --- on the Proxmox host: VM from the Ubuntu cloud image --------------------------
cd /var/lib/vz/template/iso
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img  # check SHA256SUMS
qm create 101 --name docker-host --ostype l26 --cpu host --cores 2 --memory 4096 \
  --net0 virtio,bridge=vmbr0 --scsihw virtio-scsi-single \
  --scsi0 local-lvm:0,import-from=$PWD/noble-server-cloudimg-amd64.img,discard=on,ssd=1,iothread=1 \
  --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 \
  --agent enabled=1 --onboot 1
qm resize 101 scsi0 32G
qm set 101 --ciuser <user> --sshkeys <pubkey-file> \
  --ipconfig0 ip=192.168.4.12/24,gw=192.168.4.1 --nameserver 8.8.8.8 --ciupgrade 1
qm start 101

# --- in the guest ---------------------------------------------------------------
sudo apt install -y qemu-guest-agent age git
# Docker Engine + compose plugin from download.docker.com (apt repo)
# sops: release binary sops-vX.Y.Z.linux.amd64, checked against sops-vX.Y.Z.checksums.txt
sudo install -m 0755 sops-vX.Y.Z.linux.amd64 /usr/local/bin/sops
# Tailscale from pkgs.tailscale.com, then:
sudo tailscale up --hostname=docker-host      # approve; disable key expiry in admin console

sudo mkdir -p /opt/diabetes && sudo chown "$USER":"$USER" /opt/diabetes
git clone https://github.com/smittyweygant/diabetesmanagement.git /opt/diabetes
cd /opt/diabetes
cp config/.env.template config/.env
mkdir -p data/mongo data/tconnectsync data/caddy backups
sudo chown -R 999:999 data/mongo

# age key: the existing private key from 1Password ("Age Key - Beelink"), not a new one
sudo install -d -m 0700 /root/.config/sops/age
sudo sh -c 'umask 077; cat > /root/.config/sops/age/keys.txt'     # paste, Ctrl-D
sudo age-keygen -y /root/.config/sops/age/keys.txt                # must match .sops.yaml

# build Caddy first: the build (~2 min) can outlast the unit's start timeout
cd config && sudo SECRETS_DIR=/run/diabetes docker compose build caddy && cd ..

sudo cp systemd/diabetes-stack.service systemd/diabetes-backup.service \
        systemd/diabetes-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now diabetes-stack diabetes-backup.timer
sudo ln -sfn /opt/diabetes/scripts/set-timezone.sh /usr/local/bin/diabetes-tz
```

Moving data from an old host: `mongodump --archive --gzip` there, copy the file over
with `scp`, `mongorestore --archive --gzip` into the new `nightscout-mongo` before
starting Nightscout. Dexcom Share refills the last 24 h of glucose by itself; refill pump
data with one-shot tconnectsync runs (below).

## Verification (this host)

```bash
cd /opt/diabetes/config
sudo systemctl status diabetes-stack                       # active (exited)
sudo docker compose ps                                     # mongo/nightscout healthy; tconnectsync, caddy up
sudo ss -tlnp | grep -E ':(443|80|1337) '                  # 100.65.38.92:443/:80 caddy, 127.0.0.1:1337 only
systemctl list-timers diabetes-backup.timer                # next run ~03:30 Pacific

# from a tailnet device
curl -sI https://nightscout.smittoid.com/ | head -1         # HTTP/2 200, valid cert
curl -s -o /dev/null -w '%{http_code}\n' https://nightscout.smittoid.com/api/v1/status.json   # 401 without a token
# from the LAN, not on the tailnet: https://192.168.4.12/ must be refused
```

A reboot test (`sudo systemctl reboot`) brings everything back unattended: the VM is up
in ~30 s and all four containers within ~11 s of boot. If Caddy starts before
`tailscaled` has the IP, its bind fails and `restart: unless-stopped` retries.

## Backups

`diabetes-backup.timer` runs `scripts/backup-mongodb.sh` nightly at 03:30
**America/Los_Angeles** and keeps 30 days in `/opt/diabetes/backups` (0600 root). These
sit on the VM's own disk: they protect against bad data, not a lost VM. Off-host copies
(S3 `--upload`, or Proxmox `vzdump` to a backup drive) are still to do.

## Manual pump backfill

If Tandem Source ingestion had a gap, run tconnectsync once over an explicit window.
Keep windows **≤ 2 days** and check per-day counts afterwards: a wide window can come
back nearly empty without an error once the live `--auto-update` pass has already
uploaded newer events. Nightscout dedupes on `pump_event_id`, so overlap is safe.

```bash
sudo docker run --rm --network diabetes-net --env-file /run/diabetes/tconnectsync.env \
  -v /opt/diabetes/data/tconnectsync:/root/.config/tconnectsync \
  ghcr.io/jwoglom/tconnectsync/tconnectsync:latest \
  --features BASAL BOLUS PUMP_EVENTS PROFILES \
  --start-date 2026-11-19T00:00:00 --end-date 2026-11-21T00:00:00
```

Dexcom Share keeps only the last 24 h of glucose; anything older lives only in Dexcom
Clarity.

## Host-specific gotchas

| | |
|---|---|
| **DNS rebind protection** | Some routers (OpenWRT/dnsmasq `rebind_protection`) drop public answers that point at private or CGNAT addresses, so `nightscout.smittoid.com` doesn't resolve on that LAN. Whitelist the domain: `uci add_list dhcp.@dnsmasq[0].rebind_domain='smittoid.com'`. |
| **docker group** | The login user isn't in `docker`; manual `docker` commands need `sudo`. The systemd units run as root regardless. |
| **tconnectsync 401s** | One `HTTP 401` warning per hour is normal: the Tandem token expires and tconnectsync logs in again. Repeated tracebacks and restarts are not normal. |
| **Duplicate glucose entries** | `nightscout-connect` sometimes stores one Share reading twice, milliseconds apart. Seen on the old host too; cosmetic. |
| **`nightscout-connect` password in logs** | It logs `sharePassword` on start; scrub the container json-log if that matters. |
| **sops as root in `/tmp`** | Ubuntu's `fs.protected_regular` stops root writing a user-owned file in `/tmp`. Do `sops set`/`edit` on copies in a home directory. |

## Timezone, on the road

The pump follows the traveller; the server stays home. Only `TIMEZONE_NAME`
(tconnectsync) needs updating on zone changes:

```bash
ssh docker-host 'sudo diabetes-tz America/Chicago'    # then commit the re-encrypted secret
```

Nightscout `TZ` stays `America/Los_Angeles`; the live chart follows the viewing device.
Dexcom/`nightscout-connect` is UTC and needs nothing.
