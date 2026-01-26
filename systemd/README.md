# Systemd Service Files

These service files allow Nightscout and Tconnectsync to run as system services that start automatically on boot.

## Before Installing

1. **Update the paths** in each service file:
   - Replace `YOUR_USERNAME` with your actual username
   - Update `WorkingDirectory` paths if your repo is in a different location

2. **Verify tconnectsync is installed** and note its path:
   ```bash
   which tconnectsync
   # Usually: /usr/local/bin/tconnectsync or ~/.local/bin/tconnectsync
   ```

## Installation

```bash
# Copy service files
sudo cp nightscout.service /etc/systemd/system/
sudo cp tconnectsync.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable services to start on boot
sudo systemctl enable nightscout
sudo systemctl enable tconnectsync

# Start services
sudo systemctl start nightscout
sudo systemctl start tconnectsync
```

## Management Commands

```bash
# Check status
sudo systemctl status nightscout
sudo systemctl status tconnectsync

# View logs
journalctl -u nightscout -f
journalctl -u tconnectsync -f

# Stop services
sudo systemctl stop nightscout
sudo systemctl stop tconnectsync

# Restart services
sudo systemctl restart nightscout
sudo systemctl restart tconnectsync

# Disable from starting on boot
sudo systemctl disable nightscout
sudo systemctl disable tconnectsync
```

## Troubleshooting

### Service fails to start

Check the logs:
```bash
journalctl -u tconnectsync -n 50 --no-pager
```

### Permission denied errors

Make sure the user specified in the service file:
- Has read access to the config files
- Has execute permission on the tconnectsync binary
- Can access Docker (for Nightscout service)

### Environment variables not loading

Verify the `EnvironmentFile` path is correct and the file exists:
```bash
ls -la /home/YOUR_USERNAME/diabetes/config/tconnectsync.env
```
