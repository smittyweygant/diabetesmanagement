#!/usr/bin/env bash
#
# Bootstrap helper for the diabetes stack (Nightscout + tconnectsync + MongoDB).
#
# This does NOT install anything system-wide and does NOT start the stack.
# It checks tooling, creates data/config scaffolding, and prints next steps.
# Full provisioning steps live in README.md and secrets/README.md.
#
# Usage: ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[FAIL]${NC} $1"; }

echo
echo "=========================================="
echo "  Diabetes stack - bootstrap check"
echo "=========================================="
echo

# -----------------------------------------------------------------------------
# 1. Tooling
# -----------------------------------------------------------------------------
missing=0
check() { if command -v "$1" >/dev/null 2>&1; then ok "$1"; else warn "$1 not found - $2"; missing=1; fi; }

check docker  "install: curl -fsSL https://get.docker.com | sh"
if docker compose version >/dev/null 2>&1; then ok "docker compose (v2)"; else warn "docker compose v2 plugin missing"; missing=1; fi
check git     "install via apt"
check sops    "install: see secrets/README.md"
check age     "install: sudo apt install age"
check tailscale "install: curl -fsSL https://tailscale.com/install.sh | sh"
command -v shred >/dev/null 2>&1 || warn "shred not found (coreutils) - systemd unit uses it"

echo

# -----------------------------------------------------------------------------
# 2. Scaffolding
# -----------------------------------------------------------------------------
info "Creating data / backup directories..."
mkdir -p data/mongo data/tconnectsync backups
ok "data/mongo data/tconnectsync backups"

if [ ! -f config/.env ]; then
    cp config/.env.template config/.env
    ok "created config/.env (edit the paths for this host - no secrets in it)"
else
    info "config/.env already exists - leaving it"
fi

echo

# -----------------------------------------------------------------------------
# 3. Secrets status
# -----------------------------------------------------------------------------
if ls secrets/*.env.sops.yaml >/dev/null 2>&1; then
    ok "encrypted secret files present: $(ls secrets/*.env.sops.yaml | xargs -n1 basename | tr '\n' ' ')"
else
    warn "no secrets/*.env.sops.yaml yet - follow secrets/README.md to create them"
fi

grep -q 'age1PLACEHOLDER' .sops.yaml 2>/dev/null && \
    warn ".sops.yaml still has the placeholder age key - replace it with this host's public key"

echo
echo "Next steps:"
echo "  1. Provision the host and Tailscale        -> README.md section 'Beelink setup'"
echo "  2. Create + fill encrypted secrets         -> secrets/README.md"
echo "  3. sudo cp systemd/diabetes-stack.service /etc/systemd/system/"
echo "     sudo systemctl daemon-reload && sudo systemctl enable --now diabetes-stack"
echo "  4. sudo tailscale serve --bg --https=443 127.0.0.1:1337"
echo "  5. Verify                                  -> README.md section 'Verification'"
echo

[ "$missing" -eq 0 ] || { warn "some tooling is missing (see above)"; exit 1; }
ok "bootstrap check passed"
