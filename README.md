# Smitty's CGM Data Management

I use Nightscout, Tconnectsync, and MongoDB to capture and track my diabetes health. I currently use a Dexcom G7 and Tandem Mobi in a closed loop to manage my insulin delivery.

## Software and Services

### [Nightscout](https://github.com/nightscout/cgm-remote-monitor)

Nightscout is an OSS project for individuals building their own closed loop diabetes management systems - it has sync capability to many common device and health system providers. It maintains a database of Continuous Glucose Monitoring data.

### [Tconnectsync](https://github.com/jwoglom/tconnectsync)

The Nightscout project does not have a native sync to Tandem Source. Tconnectsync provides the ability to pull Tandem t.Slim and Mobi pump configuration and event data.

### MongoDB

MongoDB is the data store for Nightscout.

## Repository Structure

```
diabetes/
├── README.md                         # This file
├── .gitignore                        # Ignores cloned repos and secrets
├── setup.sh                          # Main installation script
├── config/
│   ├── nightscout.env.template       # Nightscout configuration template
│   ├── tconnectsync.env.template     # Tconnectsync configuration template
│   ├── backup.env.template           # Backup script configuration template
│   └── docker-compose.yml            # Docker Compose for Nightscout + MongoDB
├── scripts/
│   ├── backup-mongodb.sh             # MongoDB backup to S3
│   └── restore-mongodb.sh            # Restore from S3 backup
├── systemd/                          # Systemd service files (optional)
│   ├── nightscout.service
│   └── tconnectsync.service
├── cgm-remote-monitor/               # Cloned by setup.sh (gitignored)
└── tconnectsync/                     # Cloned by setup.sh (gitignored)
```

## Quick Start

### Prerequisites

- Docker and Docker Compose
- Python 3 with pip
- Git
- AWS CLI (optional, for S3 backups)

### Installation

1. **Clone this repository:**
   ```bash
   git clone https://github.com/YOUR_USERNAME/diabetes.git
   cd diabetes
   ```

2. **Run the setup script:**
   ```bash
   ./setup.sh
   ```

3. **Configure your environment files:**
   ```bash
   # Edit Nightscout settings
   nano config/nightscout.env
   
   # Edit Tconnectsync credentials
   nano config/tconnectsync.env
   ```

4. **Start Nightscout:**
   ```bash
   cd config
   docker compose up -d
   ```

5. **Verify Nightscout is running:**
   ```bash
   # Check container status
   docker compose ps
   
   # View logs
   docker compose logs -f nightscout
   ```
   
   Access Nightscout at http://localhost:1337

## Configuration

### Nightscout (`config/nightscout.env`)

Key settings to configure:

| Variable | Description | Example |
|----------|-------------|---------|
| `API_SECRET` | Authentication secret (min 12 chars) | `my_secure_secret_123` |
| `DISPLAY_UNITS` | BG display units | `mg/dl` or `mmol/L` |
| `TZ` | Timezone | `America/New_York` |
| `ENABLE` | Enabled plugins | `careportal rawbg iob cob` |
| `AUTH_DEFAULT_ROLES` | Default access level | `denied` (requires auth) |

See `config/nightscout.env.template` for all available options.

### Tconnectsync (`config/tconnectsync.env`)

| Variable | Description |
|----------|-------------|
| `TCONNECT_EMAIL` | Your Tandem Source email |
| `TCONNECT_PASSWORD` | Your Tandem Source password |
| `NS_URL` | Your Nightscout URL |
| `NS_SECRET` | Nightscout API secret (must match `API_SECRET`) |
| `TIMEZONE_NAME` | Your pump's timezone |

### Running Tconnectsync

**Option 1: Manual run**
```bash
# Load environment and run once
set -a && source config/tconnectsync.env && set +a
tconnectsync
```

**Option 2: Auto-update mode (continuous sync)**
```bash
set -a && source config/tconnectsync.env && set +a
tconnectsync --auto-update
```

**Option 3: Using systemd (recommended for production)**
```bash
sudo cp systemd/tconnectsync.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable tconnectsync
sudo systemctl start tconnectsync
```

## MongoDB Backup & Restore

### Setup AWS S3

1. Create an S3 bucket for backups
2. Configure AWS CLI: `aws configure`
3. Copy and edit the backup config:
   ```bash
   cp config/backup.env.template config/backup.env
   nano config/backup.env
   ```

### Create Backup

```bash
# Local backup only
./scripts/backup-mongodb.sh

# Backup and upload to S3
./scripts/backup-mongodb.sh --upload

# Backup, upload, and clean up old backups
./scripts/backup-mongodb.sh --upload --cleanup
```

### Restore from Backup

```bash
# List available S3 backups
./scripts/restore-mongodb.sh --list-s3

# Restore from S3
./scripts/restore-mongodb.sh --from-s3 nightscout_20240115_120000.archive.gz

# Restore from local file
./scripts/restore-mongodb.sh backups/nightscout_20240115_120000.archive.gz
```

### Scheduled Backups (Cron)

Add to crontab (`crontab -e`):
```bash
# Daily backup at 2 AM, upload to S3, keep last 30
0 2 * * * /path/to/diabetes/scripts/backup-mongodb.sh --upload --cleanup >> /var/log/nightscout-backup.log 2>&1
```

## Migration from AWS

To migrate your Nightscout data from an AWS-hosted server:

1. **On the AWS server:** Create a backup
   ```bash
   mongodump --db nightscout --archive=nightscout_migration.archive.gz --gzip
   ```

2. **Transfer to S3:**
   ```bash
   aws s3 cp nightscout_migration.archive.gz s3://your-bucket/nightscout-backups/
   ```

3. **On your new server:** Run setup and restore
   ```bash
   ./setup.sh
   # Configure environment files
   cd config && docker compose up -d
   # Wait for MongoDB to start
   sleep 10
   cd ..
   ./scripts/restore-mongodb.sh --from-s3 nightscout_migration.archive.gz
   ```

## Production Deployment

### SSL/HTTPS with Traefik

1. Edit `config/docker-compose.yml`:
   - Update the Traefik host label with your domain
   - Uncomment the Traefik service block
   - Set your email for Let's Encrypt

2. Ensure ports 80 and 443 are open on your firewall

3. Point your domain's DNS to your server's IP

4. Restart services:
   ```bash
   cd config
   docker compose down
   docker compose up -d
   ```

### Systemd Services

For running services on boot without Docker:

```bash
# Install services
sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload

# Enable and start Nightscout
sudo systemctl enable nightscout
sudo systemctl start nightscout

# Enable and start Tconnectsync
sudo systemctl enable tconnectsync
sudo systemctl start tconnectsync

# Check status
sudo systemctl status nightscout tconnectsync
```

## Troubleshooting

### Nightscout won't start

```bash
# Check logs
cd config && docker compose logs nightscout

# Common issues:
# - API_SECRET too short (needs 12+ chars)
# - MongoDB not ready (wait and retry)
# - Port 1337 already in use
```

### Tconnectsync authentication fails

```bash
# Test login
tconnectsync --check-login

# Common issues:
# - Wrong credentials in tconnectsync.env
# - Tandem Source password changed
# - Region mismatch (US vs EU)
```

### MongoDB connection issues

```bash
# Check if MongoDB is running
docker compose ps mongo

# Check MongoDB logs
docker compose logs mongo

# Test connection
docker exec nightscout-mongo mongo --eval "db.adminCommand('ping')"
```

## Resources

- [Nightscout Documentation](https://nightscout.github.io/)
- [Nightscout Ubuntu Setup Guide](https://nightscout.github.io/vendors/VPS/ubuntu/)
- [Tconnectsync Repository](https://github.com/jwoglom/tconnectsync)
- [MongoDB Documentation](https://docs.mongodb.com/)

## License

Personal configuration repository. The upstream projects (Nightscout, Tconnectsync) have their own licenses.
