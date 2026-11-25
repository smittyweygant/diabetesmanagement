# Secrets

Real credentials for this stack are **encrypted at rest** with
[SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
and only ever exist in plaintext in RAM (a tmpfs) while the stack is running.

```
secrets/nightscout.env.sops.yaml     encrypted  -> committed to git
secrets/tconnectsync.env.sops.yaml   encrypted  -> committed to git
secrets/backup.env.sops.yaml         encrypted  -> committed to git (S3 keys; optional)
secrets/*.env.example                plaintext placeholders -> committed, for reference

~/.config/sops/age/keys.txt          age PRIVATE key  -> host only, 0600, NEVER committed
                                                        + a copy in your password manager
/run/diabetes/*.env                  decrypted at service start -> tmpfs, 0600, gone on stop/reboot
```

The `*.sops.yaml` files store values as ciphertext; keys and structure stay readable,
which is fine. Losing the age private key means the encrypted files are unrecoverable,
so back it up the moment you create it.

## First-time setup (on the host)

```bash
# 1. install tools
sudo apt install -y age
SOPS_VER=3.9.0
curl -fsSLo /tmp/sops https://github.com/getsops/sops/releases/download/v${SOPS_VER}/sops-v${SOPS_VER}.linux.amd64
sudo install -m 0755 /tmp/sops /usr/local/bin/sops

# 2. create the host key (as root, since the systemd unit runs as root)
sudo mkdir -p /root/.config/sops/age
sudo sh -c 'umask 077; age-keygen -o /root/.config/sops/age/keys.txt'
sudo age-keygen -y /root/.config/sops/age/keys.txt        # prints age1... public key

# 3. put that public key into ../.sops.yaml (replace age1PLACEHOLDER...), commit it

# 4. >>> copy /root/.config/sops/age/keys.txt into your password manager <<<

# 5. create the encrypted secret files from the examples
cd /opt/diabetes
export SOPS_AGE_KEY_FILE=/root/.config/sops/age/keys.txt
for f in nightscout tconnectsync backup; do
  cp secrets/$f.env.example /tmp/$f.env
  sudo -E sops --encrypt --input-type dotenv --output-type dotenv /tmp/$f.env > secrets/$f.env.sops.yaml
  shred -u /tmp/$f.env
done

# 6. fill in real values (opens $EDITOR on decrypted content, re-encrypts on save)
sudo -E scripts/secrets.sh edit nightscout
sudo -E scripts/secrets.sh edit tconnectsync
sudo -E scripts/secrets.sh edit backup

# 7. commit the ciphertext
git add .sops.yaml secrets/*.sops.yaml && git commit -m "Encrypt host secrets" && git push
```

## Everyday use

| Task | Command |
|------|---------|
| Edit a secret | `sudo -E scripts/secrets.sh edit nightscout` |
| Decrypt all to a dir (what systemd does) | `sudo -E scripts/secrets.sh decrypt-all /run/diabetes` |
| Re-encrypt to new recipients after editing `.sops.yaml` | `sudo -E scripts/secrets.sh rekey` |
| View one value | `sudo -E sops -d secrets/nightscout.env.sops.yaml | grep API_SECRET` |

`SOPS_AGE_KEY_FILE` must point at the private key; `sudo -E` preserves it, or export it
in root's shell profile.

## Rotating a credential

1. `sudo -E scripts/secrets.sh edit <name>`, change the value, save.
2. `git commit -am "Rotate <name>"` and `git push`.
3. `sudo systemctl restart diabetes-stack` (re-decrypts and recreates the containers).

## Recovery on a fresh host

1. Restore `~/.config/sops/age/keys.txt` from your password manager (`chmod 600`).
2. `git clone` this repo.
3. `sudo systemctl enable --now diabetes-stack` - it decrypts with the restored key.
