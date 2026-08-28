#!/usr/bin/env bash
#
# Thin wrapper around SOPS for this repo's encrypted secret files.
#
#   secrets.sh edit <name>              open $EDITOR on the decrypted content, re-encrypt on save
#   secrets.sh decrypt-all <dir>        decrypt every secrets/*.env.sops.yaml into <dir> as <name>.env
#   secrets.sh rekey                    re-encrypt all files to the recipients now in .sops.yaml
#   secrets.sh cat <name>               print decrypted content to stdout
#
# <name> is one of: nightscout, tconnectsync, backup
#
# Requires: sops, and SOPS_AGE_KEY_FILE pointing at the age private key
#   (default: /root/.config/sops/age/keys.txt). Use `sudo -E` to preserve it.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR_SRC="${REPO_DIR}/secrets"
: "${SOPS_AGE_KEY_FILE:=/root/.config/sops/age/keys.txt}"
export SOPS_AGE_KEY_FILE

die() { echo "error: $*" >&2; exit 1; }
command -v sops >/dev/null || die "sops not installed (see secrets/README.md)"

sops_file() {
  local name="$1"
  local f="${SECRETS_DIR_SRC}/${name}.env.sops.yaml"
  [ -f "$f" ] || die "no such secret file: $f"
  printf '%s\n' "$f"
}

cmd="${1:-}"; shift || true

case "$cmd" in
  edit)
    name="${1:?usage: secrets.sh edit <name>}"
    exec sops "$(sops_file "$name")"
    ;;

  cat)
    name="${1:?usage: secrets.sh cat <name>}"
    exec sops --decrypt --output-type dotenv "$(sops_file "$name")"
    ;;

  decrypt-all)
    dest="${1:?usage: secrets.sh decrypt-all <dir>}"
    install -d -m 0710 "$dest"
    umask 077
    for f in "${SECRETS_DIR_SRC}"/*.env.sops.yaml; do
      [ -e "$f" ] || die "no secrets/*.env.sops.yaml files found"
      base="$(basename "$f" .sops.yaml)"        # -> nightscout.env
      sops --decrypt --output-type dotenv "$f" > "${dest}/${base}"
      chmod 600 "${dest}/${base}"
      echo "decrypted ${dest}/${base}"
    done
    ;;

  rekey)
    for f in "${SECRETS_DIR_SRC}"/*.env.sops.yaml; do
      [ -e "$f" ] || die "no secrets/*.env.sops.yaml files found"
      sops updatekeys --yes "$f"
      echo "rekeyed $f"
    done
    echo "review 'git diff', then commit"
    ;;

  *)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
