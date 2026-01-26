#!/usr/bin/env bash
#
# Setup script for Nightscout + Tconnectsync + MongoDB
# 
# This script:
#   1. Checks prerequisites (Docker, Python 3, pip, AWS CLI)
#   2. Clones the upstream repositories
#   3. Copies configuration templates
#   4. Optionally installs tconnectsync via pip
#   5. Optionally starts services
#
# Usage: ./setup.sh [--skip-clone] [--skip-install] [--start]
#

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIGHTSCOUT_REPO="https://github.com/nightscout/cgm-remote-monitor.git"
TCONNECTSYNC_REPO="https://github.com/jwoglom/tconnectsync.git"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if command -v "$1" &> /dev/null; then
        log_success "$1 is installed"
        return 0
    else
        log_warn "$1 is not installed"
        return 1
    fi
}

# =============================================================================
# Parse Arguments
# =============================================================================

SKIP_CLONE=false
SKIP_INSTALL=false
START_SERVICES=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-clone)
            SKIP_CLONE=true
            shift
            ;;
        --skip-install)
            SKIP_INSTALL=true
            shift
            ;;
        --start)
            START_SERVICES=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --skip-clone    Skip cloning upstream repositories"
            echo "  --skip-install  Skip installing tconnectsync via pip"
            echo "  --start         Start services after setup"
            echo "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Setup
# =============================================================================

echo ""
echo "=========================================="
echo "  Nightscout + Tconnectsync Setup"
echo "=========================================="
echo ""

cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Step 1: Check Prerequisites
# -----------------------------------------------------------------------------

log_info "Checking prerequisites..."
echo ""

MISSING_REQUIRED=false

# Docker (required for Nightscout)
if ! check_command docker; then
    log_error "Docker is required. Install from https://docs.docker.com/get-docker/"
    MISSING_REQUIRED=true
fi

# Docker Compose
if ! check_command "docker compose" && ! check_command docker-compose; then
    if docker compose version &> /dev/null 2>&1; then
        log_success "docker compose is available"
    else
        log_error "Docker Compose is required. Usually included with Docker Desktop."
        MISSING_REQUIRED=true
    fi
else
    log_success "docker compose is available"
fi

# Python 3 (required for tconnectsync)
if ! check_command python3; then
    log_error "Python 3 is required. Install via your package manager."
    MISSING_REQUIRED=true
fi

# pip
if ! check_command pip3 && ! check_command pip; then
    log_warn "pip is not found. You may need to install tconnectsync manually."
fi

# Git (required for cloning)
if ! check_command git; then
    log_error "Git is required for cloning repositories."
    MISSING_REQUIRED=true
fi

# AWS CLI (optional, for backups)
if ! check_command aws; then
    log_warn "AWS CLI not found. Install it if you want to use S3 backups."
fi

echo ""

if [ "$MISSING_REQUIRED" = true ]; then
    log_error "Missing required dependencies. Please install them and re-run setup."
    exit 1
fi

# -----------------------------------------------------------------------------
# Step 2: Clone Repositories
# -----------------------------------------------------------------------------

if [ "$SKIP_CLONE" = false ]; then
    log_info "Cloning upstream repositories..."
    echo ""

    # Clone Nightscout
    if [ -d "cgm-remote-monitor" ]; then
        log_warn "cgm-remote-monitor already exists. Skipping clone."
        log_info "To update: cd cgm-remote-monitor && git pull"
    else
        log_info "Cloning Nightscout (cgm-remote-monitor)..."
        git clone --depth 1 "$NIGHTSCOUT_REPO"
        log_success "Nightscout cloned successfully"
    fi

    # Clone tconnectsync
    if [ -d "tconnectsync" ]; then
        log_warn "tconnectsync already exists. Skipping clone."
        log_info "To update: cd tconnectsync && git pull"
    else
        log_info "Cloning tconnectsync..."
        git clone --depth 1 "$TCONNECTSYNC_REPO"
        log_success "tconnectsync cloned successfully"
    fi

    echo ""
else
    log_info "Skipping repository cloning (--skip-clone)"
fi

# -----------------------------------------------------------------------------
# Step 3: Setup Configuration Files
# -----------------------------------------------------------------------------

log_info "Setting up configuration files..."
echo ""

# Copy Nightscout env template if not exists
if [ ! -f "config/nightscout.env" ]; then
    if [ -f "config/nightscout.env.template" ]; then
        cp "config/nightscout.env.template" "config/nightscout.env"
        log_success "Created config/nightscout.env from template"
        log_warn "IMPORTANT: Edit config/nightscout.env with your settings!"
    else
        log_error "Template file config/nightscout.env.template not found!"
    fi
else
    log_info "config/nightscout.env already exists. Skipping."
fi

# Copy tconnectsync env template if not exists
if [ ! -f "config/tconnectsync.env" ]; then
    if [ -f "config/tconnectsync.env.template" ]; then
        cp "config/tconnectsync.env.template" "config/tconnectsync.env"
        log_success "Created config/tconnectsync.env from template"
        log_warn "IMPORTANT: Edit config/tconnectsync.env with your credentials!"
    else
        log_error "Template file config/tconnectsync.env.template not found!"
    fi
else
    log_info "config/tconnectsync.env already exists. Skipping."
fi

echo ""

# -----------------------------------------------------------------------------
# Step 4: Install tconnectsync
# -----------------------------------------------------------------------------

if [ "$SKIP_INSTALL" = false ]; then
    log_info "Installing tconnectsync via pip..."
    echo ""

    if command -v pip3 &> /dev/null; then
        PIP_CMD="pip3"
    elif command -v pip &> /dev/null; then
        PIP_CMD="pip"
    else
        log_warn "pip not found. Skipping tconnectsync installation."
        PIP_CMD=""
    fi

    if [ -n "$PIP_CMD" ]; then
        read -p "Install tconnectsync system-wide or user-only? [s/u/skip]: " install_choice
        case $install_choice in
            s|S)
                sudo $PIP_CMD install tconnectsync
                log_success "tconnectsync installed system-wide"
                ;;
            u|U)
                $PIP_CMD install --user tconnectsync
                log_success "tconnectsync installed for current user"
                log_info "Binary location: ~/.local/bin/tconnectsync"
                ;;
            *)
                log_info "Skipping tconnectsync pip installation"
                ;;
        esac
    fi

    echo ""
else
    log_info "Skipping tconnectsync installation (--skip-install)"
fi

# -----------------------------------------------------------------------------
# Step 5: Create Data Directories
# -----------------------------------------------------------------------------

log_info "Creating data directories..."

mkdir -p mongo-data
mkdir -p letsencrypt
mkdir -p backups

log_success "Data directories created"
echo ""

# -----------------------------------------------------------------------------
# Step 6: Start Services (optional)
# -----------------------------------------------------------------------------

if [ "$START_SERVICES" = true ]; then
    log_info "Starting services..."
    echo ""

    # Check if config is ready
    if grep -q "CHANGE_ME" "config/nightscout.env" 2>/dev/null; then
        log_error "Please edit config/nightscout.env before starting services!"
        log_error "At minimum, set API_SECRET to a secure value."
        exit 1
    fi

    cd config
    docker compose up -d
    cd ..

    log_success "Services started!"
    log_info "Nightscout should be available at http://localhost:1337"
else
    log_info "To start Nightscout:"
    echo "  cd config && docker compose up -d"
    echo ""
    log_info "To run tconnectsync manually:"
    echo "  source config/tconnectsync.env && tconnectsync --auto-update"
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Edit config/nightscout.env with your settings"
echo "  2. Edit config/tconnectsync.env with your Tandem credentials"
echo "  3. Start Nightscout: cd config && docker compose up -d"
echo "  4. Start tconnectsync: See README.md for options"
echo ""
echo "For MongoDB backup/restore, see scripts/backup-mongodb.sh"
echo ""
