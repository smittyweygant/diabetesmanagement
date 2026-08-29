# Reference deployment — Beelink + OpenWRT + Tailscale

This is how the maintainer actually runs `diabetes-stack`. It's a worked example, not a
requirement — the stack only needs Docker, `sops`/`age`, and Tailscale. What makes this
one interesting is that the host is **not dedicated**: it also runs the home router as a
VM and several other Docker stacks, so the notes below are mostly about *coexistence*.

## The host

| | |
|---|---|
| Hardware | Beelink mini-PC, Intel N150 (has AVX2), 15 GiB RAM, ~230 GiB SSD |
| OS | Ubuntu 24.04 LTS, kernel 7.x |
| Docker | Engine 29.x + Compose v5 |
| Also hosting | an **OpenWRT router VM** (libvirt/KVM) and Docker stacks for Frigate, wyze-bridge, Mosquitto, and Home Assistant |
| Repo path | `/opt/diabetes` |
| Tailscale node | `smitty-beelink` on tailnet `tail40c9b0.ts.net`, MagicDNS on |

## Network topology

The Beelink **is** the home router — via a VM:

```
                 ┌─────────────────────── Beelink (Ubuntu host) ──────────────────────┐
  Internet ──▶ [ I226-V NIC 02:00.0 ]  ──vfio-pci passthrough──▶  OpenWrt-Router VM    │
             [ CNVi Wi-Fi 00:14.3 ]    ──vfio-pci passthrough──▶  (libvirt, autostart) │
                                                                        │ virtio tap   │
  Home LAN ◀──[ I226-V NIC 01:00.0 = enp1s0 ]──┬── br0 ────────────────┘              │
                                               │   192.168.10.0/24                     │
                                        host mgmt IP 192.168.10.106                    │
                                        default route via 192.168.10.1 (OpenWRT LAN)   │
                                                                                       │
   Docker:  docker0 172.17/16 · camera-stack 172.18/16 · diabetes-net 172.29.0.0/24    │
   Tailscale: tailscale0  100.113.28.48 / smitty-beelink.tail40c9b0.ts.net             │
                 └───────────────────────────────────────────────────────────────────┘
```

Consequences for this stack:

- **The host's own internet path is through the OpenWRT VM.** On a cold boot the host
  has no connectivity until libvirt starts the VM (~30–60 s). `diabetes-stack.service`
  has `After=libvirtd.service`, and `restart: unless-stopped` + Nightscout/tconnectsync
  retries absorb the gap.
- **The router's WAN NICs are PCI-passthrough** — invisible to the host kernel and to
  Docker. The stack cannot touch the routing plane.
- **`diabetes-net` is pinned to `172.29.0.0/24`** in `config/docker-compose.yml` rather
  than letting Docker auto-allocate. The LAN OpenWRT serves is a flat `192.168.10.0/24`
  (no other VLANs), and `172.17`/`172.18` are already taken by the other Docker stacks;
  `172.29.0.0/24` is verified clear on the host. Pinning keeps a future `docker compose`
  from wandering into a routed range.
- **Nightscout is bound to `127.0.0.1:1337`** — not the LAN, not `0.0.0.0`. The only way
  in is `tailscale serve` on the tailnet.

## Remote access

`tailscale serve` (not `funnel`) — tailnet-only, nothing public:

```
https://smitty-beelink.tail40c9b0.ts.net/   →  proxy http://127.0.0.1:1337
```

Reachable from any device signed into the tailnet (phones, laptop are already members),
from anywhere — home, cellular, the road. A device without Tailscale gets nothing.
Home Assistant runs on this same box, so HA→Nightscout needs no tailnet hop.

One-time in the Tailscale admin console for `smitty-beelink` (done 2026-08-28):

- Machines → **Disable key expiry** (else the node drops off the tailnet in ~6 months)
- DNS → **Enable HTTPS Certificates** (required for `serve --https=443`; otherwise use
  `serve --http=80` and an `http://` `BASE_URL`)

## Provisioning steps run

Base OS, timezone (`America/Los_Angeles` — the box lives in California), NTP, Docker,
`unattended-upgrades`, and Tailscale were already in place from other projects. What was
added for this stack:

```bash
# 1. sops + age  (age is in apt; sops is a release binary)
sudo apt install -y age
SOPS_VER=3.9.0
curl -fsSLo /tmp/sops https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.amd64
sudo install -m 0755 /tmp/sops /usr/local/bin/sops

# 2. repo + scaffold
sudo mkdir -p /opt/diabetes && sudo chown "$USER":"$USER" /opt/diabetes
git clone <repo> /opt/diabetes
cd /opt/diabetes && ./setup.sh
cp config/.env.template config/.env          # SECRETS_DIR=/run/diabetes,
                                             # MONGO_DATA_DIR=/opt/diabetes/data/mongo,
                                             # TCONNECTSYNC_DATA_DIR=/opt/diabetes/data/tconnectsync
mkdir -p data/mongo data/tconnectsync backups
sudo chown -R 999:999 data/mongo

# 3. age key  (root, since the service runs as root)
sudo mkdir -p /root/.config/sops/age
sudo sh -c 'umask 077; age-keygen -o /root/.config/sops/age/keys.txt'
sudo age-keygen -y /root/.config/sops/age/keys.txt      # public key -> .sops.yaml
#   >>> private key -> 1Password <<<

# 4. encrypted secrets  (see secrets/README.md)
#     create secrets/{nightscout,tconnectsync,backup}.env.sops.yaml from the *.env.example
#     files, fill in real values, git commit the ciphertext

# 5. service + serve
sudo cp systemd/diabetes-stack.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now diabetes-stack
sudo tailscale serve --bg --https=443 127.0.0.1:1337

# 6. timezone helper on PATH
sudo ln -sfn /opt/diabetes/scripts/set-timezone.sh /usr/local/bin/diabetes-tz

# 7. backup cron
sudo crontab -e   # see README "Backups"
```

## Verification (this host)

```bash
cd /opt/diabetes/config
SECRET=$(sudo grep '^API_SECRET=' /run/diabetes/nightscout.env | cut -d= -f2)
HASH=$(printf %s "$SECRET" | sha1sum | cut -d' ' -f1)

sudo systemctl status diabetes-stack                       # active (exited)
ls -l /run/diabetes                                        # *.env @ 0600 root:root
sudo docker compose ps                                     # mongo/nightscout healthy, tconnectsync up
sudo docker network inspect diabetes-net -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # 172.29.0.0/24

curl -s -H "api-secret: $HASH" http://127.0.0.1:1337/api/v1/status.json | jq .status
curl -s -H "api-secret: $HASH" 'http://127.0.0.1:1337/api/v1/entries.json?count=3' | jq '.[].device'
curl -s -H "api-secret: $HASH" 'http://127.0.0.1:1337/api/v1/treatments.json?count=5' | jq '.[].eventType'

# neighbours undisturbed
sudo docker ps --format '{{.Names}} {{.Status}}'          # frigate / homeassistant / wyze-bridge / mosquitto
sudo virsh domstate OpenWrt-Router                        # running

# from a tailnet device: open https://smitty-beelink.tail40c9b0.ts.net/ and log in with API_SECRET
```

## Host-specific gotchas

| | |
|---|---|
| **Reboot test** | `sudo reboot` bounces the **whole box** — the OpenWRT router and the camera stack included. Do it deliberately, not casually. After boot everything should return with no manual steps: `systemctl status diabetes-stack`, `docker compose ps`, `tailscale status`, and the `serve` config all persist. |
| **docker group** | The login user isn't in `docker` — manual `docker` commands need `sudo` until `sudo usermod -aG docker "$USER"` + re-login. The systemd service runs as root regardless. |
| **Cold boot connectivity** | See topology — internet comes up only after the OpenWRT VM does. |
| **`nightscout-connect` password in logs** | v0.0.12 logs `sharePassword` on every start; scrub the container json-log if it matters (`sed -i` on `docker inspect --format '{{.LogPath}}'`). |
| **Backup cron time** | Runs at 03:xx **Pacific** (host clock), regardless of where the pump/traveller currently is. |

## Timezone, on the road

The maintainer travels (Airstream). The pump follows the traveller; the Beelink stays in
California. Only `TIMEZONE_NAME` (tconnectsync) needs updating on zone changes:

```bash
ssh smitty-beelink 'diabetes-tz America/Chicago'      # then commit the re-encrypted secret
```

Nightscout `TZ` stays `America/Los_Angeles` (home); the live chart follows the viewing
device anyway. Dexcom/`nightscout-connect` is UTC and needs nothing.
