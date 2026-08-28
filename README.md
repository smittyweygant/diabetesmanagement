# Smitty's CGM Data Management

Self-hosted [Nightscout](https://github.com/nightscout/cgm-remote-monitor) +
[tconnectsync](https://github.com/jwoglom/tconnectsync) + MongoDB for a Dexcom G7 /
Tandem Mobi closed loop.

- **Real-time CGM:** Dexcom G7 → Dexcom Share → Nightscout's `connect` plugin.
- **Pump data:** Tandem Mobi → Tandem Source → tconnectsync → Nightscout
  (basal, bolus, pump events, profiles, plus a lagged backup copy of pump CGM).
- **Host:** a Beelink mini PC on the home LAN.
- **Remote access:** Tailscale only — no public ports, no domain, no Let's Encrypt.
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

## Beelink setup

Assumes fresh **Ubuntu Server 24.04 LTS**, wired ethernet. Run as a normal sudo user.

### 1. Base OS

```bash
sudo apt update && sudo apt full-upgrade -y && sudo reboot
sudo timedatectl set-timezone America/Denver        # your home-base tz
sudo timedatectl set-ntp true
sudo apt install -y unattended-upgrades apt-listchanges age
sudo dpkg-reconfigure -plow unattended-upgrades
```

### 2. Docker

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"        # then log out / back in
sudo systemctl enable --now docker
docker compose version                 # must be v2.x
```

### 3. SOPS

```bash
SOPS_VER=3.9.0
curl -fsSLo /tmp/sops https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.amd64
sudo install -m 0755 /tmp/sops /usr/local/bin/sops
```

### 4. Tailscale

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --ssh --hostname beelink-ns
tailscale ip -4
```

In the Tailscale **admin console** for node `beelink-ns`:
- **Disable key expiry** — otherwise the box silently drops off the tailnet in ~180 days.
- Enable **MagicDNS** + **HTTPS certificates**.

MagicDNS name will be `beelink-ns.<your-tailnet>.ts.net`.

### 5. Clone + scaffold

```bash
sudo mkdir -p /opt/diabetes && sudo chown "$USER":"$USER" /opt/diabetes
git clone git@github.com:smittyweygant/diabetesmanagement.git /opt/diabetes
cd /opt/diabetes
./setup.sh
$EDITOR config/.env                     # set MONGO_DATA_DIR / TCONNECTSYNC_DATA_DIR to /opt/diabetes/data/...
sudo chown -R 999:999 /opt/diabetes/data/mongo   # mongo container runs as uid 999
```

### 6. Secrets

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
- `BASE_URL=https://beelink-ns.<tailnet>.ts.net`.
- `PUMP_SERIAL_NUMBER` — the Mobi serial from the Tandem app / tandemsource.com.
- `TZ` / `TIMEZONE_NAME` — identical, matching the host timezone.

### 7. Start the service

```bash
sudo cp systemd/diabetes-stack.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now diabetes-stack
sudo tailscale serve --bg --https=443 127.0.0.1:1337
sudo tailscale serve status         # -> https://beelink-ns.<tailnet>.ts.net
```

---

## Verification

```bash
cd /opt/diabetes/config

# 1. Mongo healthy
docker compose ps
docker exec nightscout-mongo mongo --quiet --eval 'db.adminCommand("ping")'   # { ok: 1 }

# 2. Nightscout up
docker compose logs -f nightscout        # "listening on port 1337", Mongo connected
curl -s http://127.0.0.1:1337/api/v1/status.json | jq '.status, .settings.units'

# 3. Reachable over Tailscale
#    open https://beelink-ns.<tailnet>.ts.net on a tailnet device, log in with API_SECRET

# 4. Dexcom Share feed (within ~10 min)
curl -s 'http://127.0.0.1:1337/api/v1/entries.json?count=5' | jq '.[].device'   # nightscout-connect / share

# 5. tconnectsync - first login may need interactive 2FA:
docker compose run --rm -it tconnectsync --check-login
docker compose logs -f tconnectsync
curl -s 'http://127.0.0.1:1337/api/v1/treatments.json?count=10' | jq '.[].eventType'   # Temp Basal, Bolus, ...
curl -s http://127.0.0.1:1337/api/v1/profile.json | jq '.[0].store'

# 6. Reboot test
sudo reboot
#   after boot, with no manual steps:
systemctl status diabetes-stack          # active (exited)
ls -l /run/diabetes                       # nightscout.env / tconnectsync.env at 0600
docker compose ps                         # all Up / healthy
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

- Put the HA host on the same tailnet (Tailscale add-on for HA OS).
- Add the **native `Nightscout` integration**: URL
  `https://beelink-ns.<tailnet>.ts.net`, API key = a Nightscout access token (Admin
  Tools → Subjects, role `readable`) or the `API_SECRET`. Gives `sensor.blood_glucose`
  with `delta` + trend `direction`.
- Automation: trigger on `sensor.blood_glucose`, `choose` on value bands, set the
  Airstream light group colour (`<55` red+flash, `55–80` amber, `80–180` green,
  `180–250` amber, `>250` magenta). No custom integration needed.

---

## Gotchas

| | |
|---|---|
| **Mongo + AVX** | `mongo:4.4` needs no AVX and is the safe choice for any Beelink CPU. MongoDB 5.0+ requires AVX — don't upgrade the image without checking `/proc/cpuinfo`. If 4.4 hits `Illegal instruction`, fall back to `mongo:4.2`. |
| **Dexcom username** | Share feed fails silently if the account logs in with a phone number, or has no active follower. |
| **tconnectsync first login** | Tandem Source may require OAuth + 2FA once — run `docker compose run --rm -it tconnectsync --check-login`; the token caches in the mounted volume. Re-run if it later 401s. |
| **Tailscale key expiry** | Disable it for `beelink-ns` or the stack becomes unreachable in ~180 days. |
| **age key loss** | = permanent secret loss. Back it up the moment you create it. |
| **Double CGM feed** | Dexcom Share (`device: nightscout-connect`) and tconnectsync `CGM` (`device: tconnectsync`, ~30–60 min lag) both write `sgv`. Harmless; drop `CGM` from the `--features` list in `docker-compose.yml` if the lag artifacts annoy you. Never also enable the deprecated `bridge` plugin. |
| **`latest` image tags** | `nightscout/cgm-remote-monitor:latest` and the tconnectsync image can shift on `docker compose pull`. Take a Mongo backup first; consider pinning. |
| **`config/.env`** | Holds host paths only, no secrets, and is gitignored. |

## Resources

- [Nightscout docs](https://nightscout.github.io/) ·
  [setup variables](https://nightscout.github.io/nightscout/setup_variables/)
- [tconnectsync](https://github.com/jwoglom/tconnectsync)
- [SOPS](https://github.com/getsops/sops) · [age](https://github.com/FiloSottile/age)
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve)
- [Home Assistant Nightscout integration](https://www.home-assistant.io/integrations/nightscout/)
