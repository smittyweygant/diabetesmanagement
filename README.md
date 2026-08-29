# diabetes-stack

Self-hosted [Nightscout](https://github.com/nightscout/cgm-remote-monitor) +
[tconnectsync](https://github.com/jwoglom/tconnectsync) + MongoDB, packaged as one
Docker Compose stack with encrypted-at-rest secrets and a systemd wrapper.

Built for a **Dexcom G7** CGM and a **Tandem Mobi** pump, but the shape is generic —
any Dexcom (via Dexcom Share) and any Tandem pump tconnectsync supports.

- **Real-time CGM:** Dexcom → Dexcom Share → Nightscout's built-in `connect`
  (`nightscout-connect`) plugin. Timezone-immune.
- **Pump data:** Tandem pump → Tandem Source → tconnectsync → Nightscout — basal,
  bolus, pump events, profiles (CGM sync deliberately off; see
  [Timezone handling](#timezone-handling)).
- **Remote access:** [Tailscale](https://tailscale.com) only — no public ports, no
  domain, no Let's Encrypt.
- **Secrets:** [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age),
  encrypted in the repo, decrypted to a tmpfs at service start, shredded on stop.

> Running this on real hardware? A full worked example — a multi-tenant mini-PC that
> also hosts a router VM — is in **[`docs/deployment.md`](docs/deployment.md)**.

## How it fits together

```
Dexcom app ──Share──► Nightscout `connect` plugin ─┐
                                                   ├─► MongoDB ─► Nightscout web UI
Tandem pump ─► Tandem Source ─► tconnectsync ──────┘        (bound to 127.0.0.1:1337)
                                                                   │
                                        Tailscale Serve (HTTPS, tailnet-only)
                                                                   │
                                              phone / laptop / Home Assistant
```

`systemd/diabetes-stack.service` at boot: `sops --decrypt`s `secrets/*.env.sops.yaml`
into `${SECRETS_DIR}` (a tmpfs, default `/run/diabetes`), runs `docker compose up -d`,
and `shred`s the plaintext on stop. `restart: unless-stopped` keeps the containers up
between reboots; the unit just guarantees a clean decrypt→up→shred lifecycle.

## Repository layout

```
diabetes-stack/
├── setup.sh                      # bootstrap check + scaffolding (installs nothing)
├── config/
│   ├── docker-compose.yml        # mongo + nightscout + tconnectsync
│   ├── .env.template             # non-secret compose vars (paths) -> config/.env
│   ├── nightscout.env.template   # every Nightscout var, documented
│   ├── tconnectsync.env.template # every tconnectsync var, documented
│   └── backup.env.template       # backup / S3 vars
├── secrets/
│   ├── README.md                 # the SOPS + age workflow — read this first
│   ├── *.env.example             # plaintext placeholders to seed the encrypted files
│   └── *.env.sops.yaml           # ENCRYPTED real config (committed as ciphertext)
├── scripts/
│   ├── secrets.sh                # sops wrapper: edit / decrypt-all / rekey
│   ├── set-timezone.sh           # change the pump timezone + restart  (`diabetes-tz`)
│   ├── backup-mongodb.sh         # mongodump (--docker), optional S3 upload
│   └── restore-mongodb.sh        # mongorestore from local file or S3
├── systemd/
│   └── diabetes-stack.service    # decrypt -> compose up -> shred on stop
└── docs/
    └── deployment.md             # a real-world host build, end to end
```

## Requirements

- Docker Engine + Compose v2
- `sops` and `age`
- Tailscale (the host on a tailnet; MagicDNS + HTTPS certs enabled for
  `tailscale serve --https`)
- `git`, `curl`, `openssl`

## Configuration

Nothing sensitive is edited in place. Every value is documented in the
`config/*.env.template` files; the real values live **encrypted** in
`secrets/*.env.sops.yaml`.

| Where | What |
|---|---|
| `config/.env` | non-secret compose interpolation — `SECRETS_DIR`, `MONGO_DATA_DIR`, `TCONNECTSYNC_DATA_DIR`. Copied from `.env.template`, gitignored. |
| `secrets/nightscout.env.sops.yaml` | `API_SECRET`, Dexcom Share account + password, `BASE_URL`, `TZ`, plugin/alarm settings |
| `secrets/tconnectsync.env.sops.yaml` | Tandem Source login, `PUMP_SERIAL_NUMBER`, `TIMEZONE_NAME`, `NS_URL`, `NS_SECRET` |
| `secrets/backup.env.sops.yaml` | S3 bucket + IAM keys (only if you use offsite backups) |

Key points:

- `API_SECRET` — `openssl rand -hex 20`. The **same plaintext string** goes in
  `tconnectsync` as `NS_SECRET`.
- `CONNECT_SHARE_ACCOUNT_NAME` / `CONNECT_SHARE_PASSWORD` — the **publisher** Dexcom
  account (the one the phone paired to the sensor logs in with), **not** a follower
  account, and not a phone-number login. Share must be on with an accepted follower.
- `NS_URL=http://nightscout:1337` — container-to-container on the compose network, so
  it works even if `tailscale serve` is down.
- `BASE_URL` — your `https://<host>.<tailnet>.ts.net` (or `http://<host>.<tailnet>.ts.net:1337`
  if you serve plain HTTP).

See **[`secrets/README.md`](secrets/README.md)** for the age-key / encrypt / edit / rekey
flow.

## Running it

```bash
# 1. prerequisites installed (see Requirements), repo cloned to e.g. /opt/diabetes
./setup.sh
cp config/.env.template config/.env        # set the three paths for your host
mkdir -p data/mongo data/tconnectsync backups
sudo chown -R 999:999 data/mongo           # the mongo container runs as uid 999

# 2. secrets  (details: secrets/README.md)
#    - age-keygen the host key, back it up, put the PUBLIC key in .sops.yaml
#    - create + fill secrets/*.env.sops.yaml from the *.env.example files

# 3. service
sudo cp systemd/diabetes-stack.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now diabetes-stack

# 4. publish to the tailnet
sudo tailscale serve --bg --https=443 127.0.0.1:1337
#    -> https://<host>.<tailnet>.ts.net
```

Verify:

```bash
SECRET=$(sudo grep '^API_SECRET=' /run/diabetes/nightscout.env | cut -d= -f2)
HASH=$(printf %s "$SECRET" | sha1sum | cut -d' ' -f1)

sudo docker compose -f config/docker-compose.yml ps        # all Up / healthy
curl -s -H "api-secret: $HASH" http://127.0.0.1:1337/api/v1/status.json | jq .status
curl -s -H "api-secret: $HASH" 'http://127.0.0.1:1337/api/v1/entries.json?count=5' \
  | jq '.[].device'                                        # nightscout-connect (Dexcom)
curl -s -H "api-secret: $HASH" 'http://127.0.0.1:1337/api/v1/treatments.json?count=5' \
  | jq '.[].eventType'                                     # Temp Basal, Bolus, ...
```

tconnectsync's first login may need an interactive OAuth/2FA step once:
`sudo docker compose run --rm -it tconnectsync --check-login` (the token then caches in
`TCONNECTSYNC_DATA_DIR`).

## Timezone handling

Only **one** value follows you when you travel: `TIMEZONE_NAME` in the tconnectsync
secret. It tells tconnectsync which local zone to read the pump's timestamps as. Get it
wrong and every bolus/basal lands hours off.

Everything else is fine to leave alone:

| | |
|---|---|
| Dexcom / `nightscout-connect` | pure UTC — always correct, no setting |
| Nightscout `TZ` | report/rollover boundaries only; the live chart uses the viewer's clock. Set it to your home zone and forget it. |
| host clock | wherever the box physically lives; only affects the backup cron |

When you settle into a new zone for a day or more:

```bash
ssh <host> 'diabetes-tz America/Denver'      # edits the secret + restarts the stack
```

(`scripts/set-timezone.sh`, symlinked to `diabetes-tz`.) Commit the re-encrypted
`secrets/tconnectsync.env.sops.yaml` afterwards.

tconnectsync's own CGM sync is left **off** (`--features BASAL BOLUS PUMP_EVENTS
PROFILES`) — it lags 30–60 min and gets mis-timed on zone changes, and Dexcom Share
already covers real-time glucose.

## Backups

`scripts/backup-mongodb.sh --docker` runs `mongodump --archive --gzip` inside the mongo
container into `backups/`.

```cron
15 3 * * *   /opt/diabetes/scripts/backup-mongodb.sh --docker >> /opt/diabetes/backups/backup.log 2>&1
0 4 * * *    find /opt/diabetes/backups -name 'nightscout_*.archive.gz' -mtime +14 -delete
30 3 * * 0   /opt/diabetes/scripts/backup-mongodb.sh --docker --upload --cleanup >> /opt/diabetes/backups/backup.log 2>&1
```

- **S3 (optional):** put `S3_BUCKET` / `S3_PREFIX` / `AWS_*` / `BACKUP_RETENTION` in
  `secrets/backup.env.sops.yaml`; use a dedicated IAM user scoped to that bucket.
- **Back up `~/.config/sops/age/keys.txt`** (in a password manager) — without it the
  `*.sops.yaml` files are unrecoverable.
- **Restore:** `./scripts/restore-mongodb.sh backups/<file>` (or `--from-s3 <name>`).

## Rotating a secret

```bash
sudo -E scripts/secrets.sh edit nightscout     # change value, save (re-encrypts)
git commit -am "rotate <thing>" && git push
sudo systemctl restart diabetes-stack          # re-decrypt + recreate containers
```

## Home Assistant

Point the native **Nightscout** integration at the stack (`http://nightscout:1337` if
HA shares the Docker network, else the Tailscale URL). Use a scoped access token
(Nightscout → Admin Tools → Subjects, role `readable`), **not** the master `API_SECRET`.
You get `sensor.blood_glucose` with `delta` and trend `direction` — enough to drive
automations (e.g. map BG bands to a light colour).

## Gotchas

| | |
|---|---|
| **Dexcom account** | Must be the *publisher* (sensor-paired) account, not a *follower*; not a phone-number login; Share on with an accepted follower. A follower account authenticates fine but returns zero readings. |
| **Dexcom Share API lag** | After enabling Share it can take 20–60 min before the web service Nightscout polls starts serving data. The app showing readings doesn't mean the Share API does yet. |
| **tconnectsync first login** | May need OAuth + 2FA once (`--check-login`); token caches in `TCONNECTSYNC_DATA_DIR`. Re-run if it later 401s. |
| **`nightscout-connect` logs the Dexcom password** | v0.0.12 prints `sharePassword` in plaintext to the container log on every start. To scrub: `LP=$(sudo docker inspect --format '{{.LogPath}}' nightscout); sudo sed -i 's/<pw>/<redacted>/g' "$LP"`. |
| **age key loss** | = permanent secret loss. Back it up the moment you create it. |
| **`API_SECRET` length** | ≥ 12 chars or Nightscout won't start. |
| **`latest` image tags** | `nightscout/cgm-remote-monitor:latest` and the tconnectsync image can move on `docker compose pull` — take a backup first, consider pinning. |
| **Mongo 4.4** | EOL for patches but matches Nightscout's tested driver; fine for a private, loopback-only DB. Needs no AVX (5.0+ does). |
| **`config/.env`** | host paths only, no secrets, gitignored. |

## Resources

- [Nightscout docs](https://nightscout.github.io/) ·
  [setup variables](https://nightscout.github.io/nightscout/setup_variables/)
- [tconnectsync](https://github.com/jwoglom/tconnectsync)
- [SOPS](https://github.com/getsops/sops) · [age](https://github.com/FiloSottile/age)
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve)
- [Home Assistant Nightscout integration](https://www.home-assistant.io/integrations/nightscout/)
