# Smitty's CGM Data Management

Self-hosted [Nightscout](https://github.com/nightscout/cgm-remote-monitor) +
[tconnectsync](https://github.com/jwoglom/tconnectsync) + MongoDB for a Dexcom G7 /
Tandem Mobi closed loop.

- **Real-time CGM:** Dexcom G7 → Dexcom Share → Nightscout's `connect` plugin.
- **Pump data:** Tandem Mobi → Tandem Source → tconnectsync → Nightscout
  (basal, bolus, pump events, profiles, plus a lagged backup copy of pump CGM).
- **Host:** a Beelink mini PC (Intel N150, Ubuntu 24.04) that also runs an OpenWRT
  router VM and other Docker stacks (Frigate, Home Assistant, Mosquitto). This stack is
  additive and isolated — its own compose project (`diabetes`) on a pinned bridge
  network `172.29.0.0/24`.
- **Remote access:** Tailscale only — no public ports, no domain, no Let's Encrypt.
  The Beelink is already on the tailnet as `smitty-beelink.tail40c9b0.ts.net`.
- **Secrets:** encrypted at rest with SOPS + age; decrypted to RAM (tmpfs) at service
  start. Nothing sensitive on disk except the age key.

> Migrated off an AWS EC2 box in 2026. The old stack died when Tandem retired t:connect
> for **Tandem Source** (Sept 2024) — anything below tconnectsync 2.0 stopped working.
> Historical data was not carried over; this starts from an empty database.

## Repository layout

```
diabetes/
├── setup.sh                        # bootstrap check + scaffolding (installs nothing)
├── config/
│   ├── docker-compose.yml          # the whole stack: mongo + nightscout + tconnectsync
│   ├── .env.template               # non-secret compose vars (paths) -> copy to config/.env
│   ├── nightscout.env.template     # reference: every Nightscout var documented
│   ├── tconnectsync.env.template   # reference: every tconnectsync var documented
│   └── backup.env.template         # reference: backup / S3 vars
├── secrets/
│   ├── README.md                   # how the SOPS+age flow works - READ THIS
│   ├── *.env.example               # plaintext placeholders to seed the encrypted files
│   └── *.env.sops.yaml             # ENCRYPTED real config (committed; created on the host)
├── scripts/
│   ├── secrets.sh                  # sops wrapper: edit / decrypt-all / rekey
│   ├── backup-mongodb.sh           # mongodump (--docker), optional S3 upload
│   └── restore-mongodb.sh          # mongorestore from local file or S3
└── systemd/
    └── diabetes-stack.service      # decrypt secrets -> compose up -> shred on stop
```

## How it fits together

```
Dexcom G7 app ──Share──► Nightscout `connect` plugin ─┐
                                                      ├─► MongoDB ─► Nightscout web UI
Tandem Mobi ─► Tandem Source ─► tconnectsync ─────────┘         (bound to 127.0.0.1:1337)
                                                                      │
                                              Tailscale Serve (HTTPS on the tailnet)
                                                                      │
                                          phone / laptop / Home Assistant (Airstream)
```

`systemd/diabetes-stack.service` runs at boot: it `sops --decrypt`s
`secrets/*.env.sops.yaml` into `/run/diabetes/` (tmpfs), runs `docker compose up -d`,
and `shred`s the plaintext on stop. `restart: unless-stopped` keeps the containers up
between reboots.

---

## This box also runs…

The Beelink is not dedicated to this project. Verified state (2026-08-28):

- **OpenWRT router VM** (`OpenWrt-Router`, libvirt/KVM, autostart). Its WAN NIC + Wi-Fi
  are **PCI passthrough** (`vfio-pci`) — invisible to the host and to Docker. Its LAN is
  a single virtio port on host bridge `br0` (`192.168.10.0/24`, flat, no other VLANs).
  **The host's own internet path is through this VM**, so on a cold boot outbound
  traffic fails for ~30–60 s until libvirt starts it (the stack's restart policy +
  app retries absorb this; the unit has `After=libvirtd.service`).
- **Other Docker stacks**: Frigate, wyze-bridge, Mosquitto, Home Assistant — on
  `172.17.0.0/16` and `172.18.0.0/16`.

This stack stays out of their way: separate compose project (`diabetes`), pinned
network `diabetes-net` = `172.29.0.0/24`, Nightscout bound to `127.0.0.1:1337`. All
`docker` / `docker compose` commands below need `sudo` until your user is added to the
`docker` group (`sudo usermod -aG docker "$USER"` + re-login).

## Beelink setup

Already satisfied on this box (verified 2026-08-28), **skip**: Ubuntu 24.04.4 LTS,
timezone `America/Los_Angeles` + NTP, Docker 29.x + Compose v5, `docker.service`
enabled, `unattended-upgrades`, git/curl/jq/openssl, and Tailscale (node
`smitty-beelink`, tailnet `tail40c9b0.ts.net`, MagicDNS on). The N150 has AVX2, so
`mongo:4.4` (and newer) run fine.

### 1. Tailscale admin console (browser, one-time) — done 2026-08-28

- Machines → `smitty-beelink` → **Disable key expiry** ✅
- DNS → **Enable HTTPS Certificates** ✅ (needed for `tailscale serve --https=443`)

### 2. Install SOPS + age

```bash
sudo apt update && sudo apt install -y age
SOPS_VER=3.9.0
curl -fsSLo /tmp/sops https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.amd64
sudo install -m 0755 /tmp/sops /usr/local/bin/sops
```

### 3. Clone + scaffold

```bash
sudo mkdir -p /opt/diabetes && sudo chown "$USER":"$USER" /opt/diabetes
git clone -b rebuild-beelink-tailscale git@github.com:smittyweygant/diabetesmanagement.git /opt/diabetes   # until merged to main
cd /opt/diabetes
./setup.sh
$EDITOR config/.env       # SECRETS_DIR=/run/diabetes
                          # MONGO_DATA_DIR=/opt/diabetes/data/mongo
                          # TCONNECTSYNC_DATA_DIR=/opt/diabetes/data/tconnectsync
mkdir -p data/mongo data/tconnectsync backups
sudo chown -R 999:999 data/mongo    # mongo container runs as uid 999
```

### 4. Secrets

Follow **[`secrets/README.md`](secrets/README.md)** to:
1. `age-keygen` the host key (and copy it into your password manager).
2. Put the age **public** key into `.sops.yaml`.
3. Create `secrets/nightscout.env.sops.yaml`, `tconnectsync.env.sops.yaml`, and
   (optional) `backup.env.sops.yaml` from the `*.env.example` files.
4. Fill in real values with `sudo -E scripts/secrets.sh edit <name>`.
5. Commit the encrypted files and push.

Reference for what goes in each: `config/nightscout.env.template`,
`config/tconnectsync.env.template`.

Key values:
- `API_SECRET` — `openssl rand -hex 20`. Same plaintext string goes in
  `tconnectsync` as `NS_SECRET`.
- `CONNECT_SHARE_ACCOUNT_NAME` / `CONNECT_SHARE_PASSWORD` — the Dexcom account with an
  **active follower** and a **non-phone-number** username.
- `BASE_URL=https://smitty-beelink.tail40c9b0.ts.net` (HTTP variant:
  `http://smitty-beelink.tail40c9b0.ts.net:1337`).
- `PUMP_SERIAL_NUMBER` — the Mobi serial from the Tandem app / tandemsource.com.
- `TZ` / `TIMEZONE_NAME` — both `America/Los_Angeles` (matches the host).

### 5. Start the service

```bash
sudo cp systemd/diabetes-stack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now diabetes-stack
sudo tailscale serve --bg --https=443 127.0.0.1:1337
sudo tailscale serve status         # -> https://smitty-beelink.tail40c9b0.ts.net
```

If you skipped the HTTPS-certs toggle, use `--http=80` instead and set `BASE_URL` to the
`http://…ts.net` form (WireGuard already encrypts the transport).

---

## Verification

```bash
cd /opt/diabetes/config     # (prefix docker commands with sudo until you're in the docker group)

# 1. Mongo healthy + network pinned
sudo docker compose ps
sudo docker network inspect diabetes-net -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # 172.29.0.0/24
sudo docker exec nightscout-mongo mongo --quiet --eval 'db.adminCommand("ping")'         # { ok: 1 }

# 2. Nightscout up
sudo docker compose logs -f nightscout   # "listening on port 1337", Mongo connected
curl -s http://127.0.0.1:1337/api/v1/status.json | jq '.status, .settings.units'

# 3. Reachable over Tailscale
#    open https://smitty-beelink.tail40c9b0.ts.net on a tailnet device, log in with API_SECRET

# 4. Dexcom Share feed (within ~10 min)
curl -s 'http://127.0.0.1:1337/api/v1/entries.json?count=5' | jq '.[].device'   # nightscout-connect / share

# 5. tconnectsync - first login may need interactive 2FA:
sudo docker compose run --rm -it tconnectsync --check-login
sudo docker compose logs -f tconnectsync
curl -s 'http://127.0.0.1:1337/api/v1/treatments.json?count=10' | jq '.[].eventType'   # Temp Basal, Bolus, ...
curl -s http://127.0.0.1:1337/api/v1/profile.json | jq '.[0].store'

# 6. Neighbours undisturbed
sudo docker ps --format '{{.Names}} {{.Status}}'   # frigate / homeassistant / wyze-bridge / mosquitto still Up
sudo virsh domstate OpenWrt-Router                  # running

# 7. Reboot test
sudo reboot
#   after boot, with no manual steps:
systemctl status diabetes-stack          # active (exited)
ls -l /run/diabetes                       # nightscout.env / tconnectsync.env at 0600
sudo docker compose ps                    # all Up / healthy
tailscale status                          # Online
curl -s 'http://127.0.0.1:1337/api/v1/entries.json?count=2' | jq '.[].dateString'   # fresh
```

---

## Backups

`scripts/backup-mongodb.sh --docker` runs `mongodump --archive --gzip` inside
`nightscout-mongo`, writing to `backups/nightscout_<timestamp>.archive.gz`.

`sudo crontab -e`:

```cron
15 3 * * *   /opt/diabetes/scripts/backup-mongodb.sh --docker >> /opt/diabetes/backups/backup.log 2>&1
0 4 * * *    find /opt/diabetes/backups -name 'nightscout_*.archive.gz' -mtime +14 -delete
30 3 * * 0   /opt/diabetes/scripts/backup-mongodb.sh --docker --upload --cleanup >> /opt/diabetes/backups/backup.log 2>&1
```

- **S3 offsite (optional):** put `S3_BUCKET`, `S3_PREFIX`, `AWS_*`, `BACKUP_RETENTION`
  in `secrets/backup.env.sops.yaml`; use a dedicated IAM user scoped to that bucket.
  Offsite alternative: `rsync` `backups/` to another tailnet host or NAS.
- **Also back up** `~/.config/sops/age/keys.txt` (encrypted / in your password manager)
  — without it the `*.sops.yaml` files are unrecoverable.
- **Restore:** `./scripts/restore-mongodb.sh backups/<file>` (or `--from-s3 <name>`).
  Do a drill into a scratch DB name once.

Restore drill / DR is the only reason these exist — the historical data itself isn't
precious.

---

## Rotating a secret

```bash
sudo -E scripts/secrets.sh edit nightscout      # change value, save (re-encrypts)
git commit -am "Rotate Dexcom password" && git push
sudo systemctl restart diabetes-stack           # re-decrypts, recreates containers
```

---

## Later: Home Assistant / Airstream LEDs

Home Assistant **already runs on this Beelink** (container `homeassistant`), so no
tailnet hop is needed between HA and Nightscout:

- Attach `homeassistant` to `diabetes-net` (or a shared `proxy` network) and point the
  **native `Nightscout` integration** at `http://nightscout:1337`. Otherwise use
  `http://192.168.10.106:1337`.
- API key = a Nightscout access token (Admin Tools → Subjects, role `readable`) or the
  `API_SECRET`. Gives `sensor.blood_glucose` with `delta` + trend `direction`.
- Automation: trigger on `sensor.blood_glucose`, `choose` on value bands, set the
  Airstream light group colour (`<55` red+flash, `55–80` amber, `80–180` green,
  `180–250` amber, `>250` magenta). No custom integration needed.
- Do this after ~a week of stable operation.

---

## Gotchas

| | |
|---|---|
| **Docker subnet** | `diabetes-net` is pinned to `172.29.0.0/24` (free on the host, clear of OpenWRT's `192.168.10.0/24` and the existing `172.17` / `172.18` Docker nets). Don't let it auto-allocate. |
| **Cold boot** | The host's internet path is the OpenWRT VM. Containers may fail outbound for ~30–60 s after a reboot until libvirt starts it; `restart: unless-stopped` + app retries recover. Unit has `After=libvirtd.service`. |
| **Dexcom username** | Share feed fails silently if the account logs in with a phone number, or has no active follower. |
| **tconnectsync first login** | Tandem Source may require OAuth + 2FA once — run `sudo docker compose run --rm -it tconnectsync --check-login`; the token caches in the mounted volume. Re-run if it later 401s. |
| **Tailscale key expiry / HTTPS** | For `smitty-beelink`: key expiry disabled and tailnet HTTPS certs enabled 2026-08-28. If HTTPS were off, use `tailscale serve --http=80` and an `http://` `BASE_URL`. |
| **age key loss** | = permanent secret loss. Back it up (1Password) the moment you create it. |
| **docker group** | `smittyweygant` isn't in the `docker` group yet — use `sudo` for manual `docker` commands until `usermod -aG docker` + re-login. The systemd service runs as root and is unaffected. |
| **Double CGM feed** | Dexcom Share (`device: nightscout-connect`) and tconnectsync `CGM` (`device: tconnectsync`, ~30–60 min lag) both write `sgv`. Harmless; drop `CGM` from the `--features` list in `docker-compose.yml` if the lag artifacts annoy you. Never also enable the deprecated `bridge` plugin. |
| **`latest` image tags** | `nightscout/cgm-remote-monitor:latest` and the tconnectsync image can shift on `docker compose pull`. Take a Mongo backup first; consider pinning. |
| **Mongo 4.4** | EOL for patches but matches Nightscout's tested driver and is fine for a private, loopback-only DB. The N150 has AVX2, so a newer Mongo would also run if you ever migrate. |
| **`config/.env`** | Holds host paths only, no secrets, and is gitignored. |

## Resources

- [Nightscout docs](https://nightscout.github.io/) ·
  [setup variables](https://nightscout.github.io/nightscout/setup_variables/)
- [tconnectsync](https://github.com/jwoglom/tconnectsync)
- [SOPS](https://github.com/getsops/sops) · [age](https://github.com/FiloSottile/age)
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve)
- [Home Assistant Nightscout integration](https://www.home-assistant.io/integrations/nightscout/)
