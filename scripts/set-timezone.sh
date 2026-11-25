#!/usr/bin/env bash
#
# Update the timezone tconnectsync uses to stamp pump events, and restart the stack.
# Use this when you settle into a new zone for a day or more (e.g. a road trip).
#
#   set-timezone.sh America/Denver
#
# The Dexcom Share CGM feed is timezone-immune and needs no adjustment. This only
# affects how tconnectsync's insulin/basal/profile timestamps are interpreted.
#
# Installed as `diabetes-tz` on the host; run from anywhere on the tailnet:
#   ssh docker-host 'sudo diabetes-tz America/Chicago'
#
# Requires root (reads the age key, restarts the service).

set -euo pipefail

ZONE="${1:-}"
if [ -z "$ZONE" ]; then
  echo "usage: ${0##*/} <Area/Location>   e.g. ${0##*/} America/Denver" >&2
  echo "common: America/New_York  America/Chicago  America/Denver  America/Los_Angeles" >&2
  exit 2
fi
if [ ! -f "/usr/share/zoneinfo/$ZONE" ]; then
  echo "error: '$ZONE' is not a known IANA timezone (checked /usr/share/zoneinfo)" >&2
  exit 1
fi

# Resolve symlinks first — this script is symlinked as /usr/local/bin/diabetes-tz,
# and BASH_SOURCE[0] would otherwise point at the symlink's directory.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO="$(cd "$(dirname "$SELF")/.." && pwd)"
: "${SOPS_AGE_KEY_FILE:=/root/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

command -v sops >/dev/null || { echo "sops not installed" >&2; exit 1; }

# Run from the repo root so sops finds .sops.yaml (creation_rules) for re-encryption.
cd "$REPO"
SECRET_FILE="secrets/tconnectsync.env.sops.yaml"
[ -f "$SECRET_FILE" ] || { echo "no such file: $REPO/$SECRET_FILE" >&2; exit 1; }

current="$(sops -d --output-type dotenv "$SECRET_FILE" | sed -n 's/^TIMEZONE_NAME=//p')"
if [ "$current" = "$ZONE" ]; then
  echo "TIMEZONE_NAME is already $ZONE - nothing to do."
  exit 0
fi

echo "TIMEZONE_NAME: ${current:-<unset>} -> $ZONE"

# Decrypt -> edit -> re-encrypt to a temp file, and only swap it in once it's
# confirmed encrypted. Never leaves plaintext at the real path.
plain="$(mktemp)"; enc="$(mktemp)"
trap 'shred -u "$plain" "$enc" 2>/dev/null || rm -f "$plain" "$enc"' EXIT
sops -d --output-type dotenv "$SECRET_FILE" > "$plain"
sed -i "s#^TIMEZONE_NAME=.*#TIMEZONE_NAME=$ZONE#" "$plain"
# --filename-override makes sops match .sops.yaml creation_rules against the
# secrets/... path even though the actual input is a tmp file. In sops 3.9,
# --age alone (without a rule match) errors with "no matching creation rules".
sops --encrypt --filename-override "$SECRET_FILE" \
  --input-type dotenv --output-type yaml "$plain" > "$enc"
grep -q '^sops:' "$enc" || { echo "error: re-encryption did not produce a sops file; aborting" >&2; exit 1; }
cat "$enc" > "$SECRET_FILE"

echo "re-encrypted $SECRET_FILE"
echo "restarting diabetes-stack ..."
systemctl restart diabetes-stack
echo "done. Commit the updated ciphertext when convenient:"
echo "  git -C $REPO add secrets/tconnectsync.env.sops.yaml && git -C $REPO commit -m 'tz -> $ZONE'"
