#!/usr/bin/env bash
#
# MongoDB Restore Script for Nightscout
#
# Restores a MongoDB database from a backup archive, either from a local file
# or downloaded from S3.
#
# Usage:
#   ./restore-mongodb.sh backup.archive.gz           # Restore from local file
#   ./restore-mongodb.sh --from-s3 backup_name       # Download from S3 and restore
#   ./restore-mongodb.sh --list-s3                   # List available S3 backups
#
# Environment variables (or set in config/backup.env):
#   MONGO_HOST        - MongoDB host (default: localhost)
#   MONGO_PORT        - MongoDB port (default: 27017)
#   MONGO_DB          - Database name (default: nightscout)
#   S3_BUCKET         - S3 bucket name for backups
#   S3_PREFIX         - S3 prefix/folder (default: nightscout-backups)
#

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/backups"

# Load environment: decrypted secrets tmpfs first, legacy plaintext file second.
SECRETS_DIR="${SECRETS_DIR:-/run/diabetes}"
if [ -f "${SECRETS_DIR}/backup.env" ]; then
    set -a; . "${SECRETS_DIR}/backup.env"; set +a
elif [ -f "${PROJECT_DIR}/config/backup.env" ]; then
    set -a; . "${PROJECT_DIR}/config/backup.env"; set +a
fi

# Defaults
MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DB="${MONGO_DB:-nightscout}"
S3_PREFIX="${S3_PREFIX:-nightscout-backups}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

# =============================================================================
# Parse Arguments
# =============================================================================

FROM_S3=false
LIST_S3=false
DOCKER_MODE=false
BACKUP_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --from-s3)
            FROM_S3=true
            shift
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                S3_BACKUP_NAME="$1"
                shift
            fi
            ;;
        --list-s3)
            LIST_S3=true
            shift
            ;;
        --docker)
            DOCKER_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [BACKUP_FILE]"
            echo ""
            echo "Arguments:"
            echo "  BACKUP_FILE      Path to local backup archive to restore"
            echo ""
            echo "Options:"
            echo "  --from-s3 NAME   Download backup from S3 and restore"
            echo "  --list-s3        List available backups in S3"
            echo "  --docker         Use MongoDB container for restore"
            echo "  -h, --help       Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 backups/nightscout_20240115_120000.archive.gz"
            echo "  $0 --list-s3"
            echo "  $0 --from-s3 nightscout_20240115_120000.archive.gz"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

# =============================================================================
# List S3 Backups
# =============================================================================

if [ "$LIST_S3" = true ]; then
    if [ -z "$S3_BUCKET" ]; then
        log_error "S3_BUCKET environment variable not set!"
        exit 1
    fi

    echo ""
    echo "Available backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
    echo ""
    
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
        | grep "nightscout_.*\.archive\.gz" \
        | sort -r \
        | awk '{printf "  %s %s  %s\n", $1, $2, $4}'
    
    echo ""
    echo "To restore, run:"
    echo "  $0 --from-s3 <backup_name>"
    exit 0
fi

# =============================================================================
# Download from S3 (if requested)
# =============================================================================

if [ "$FROM_S3" = true ]; then
    if [ -z "$S3_BUCKET" ]; then
        log_error "S3_BUCKET environment variable not set!"
        exit 1
    fi

    if [ -z "$S3_BACKUP_NAME" ]; then
        log_error "No backup name specified!"
        log_info "Use --list-s3 to see available backups"
        exit 1
    fi

    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="${BACKUP_DIR}/${S3_BACKUP_NAME}"
    S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/${S3_BACKUP_NAME}"

    log_info "Downloading backup from S3..."
    log_info "Source: $S3_PATH"
    
    aws s3 cp "$S3_PATH" "$BACKUP_FILE"
    
    log_success "Downloaded to: $BACKUP_FILE"
    echo ""
fi

# =============================================================================
# Validate Backup File
# =============================================================================

if [ -z "$BACKUP_FILE" ]; then
    log_error "No backup file specified!"
    echo ""
    echo "Usage: $0 [OPTIONS] BACKUP_FILE"
    echo "       $0 --from-s3 BACKUP_NAME"
    echo ""
    echo "Run '$0 --help' for more options"
    exit 1
fi

if [ ! -f "$BACKUP_FILE" ]; then
    log_error "Backup file not found: $BACKUP_FILE"
    exit 1
fi

# =============================================================================
# Confirm Restore
# =============================================================================

echo ""
echo "=========================================="
echo "  MongoDB Restore"
echo "=========================================="
echo ""
log_info "Backup file: $BACKUP_FILE"
log_info "Target host: ${MONGO_HOST}:${MONGO_PORT}"
log_info "Target database: ${MONGO_DB}"
echo ""
log_warn "WARNING: This will overwrite the existing database!"
echo ""
read -p "Are you sure you want to proceed? [y/N]: " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    log_info "Restore cancelled."
    exit 0
fi

echo ""

# =============================================================================
# Restore Database
# =============================================================================

log_info "Restoring database..."

# Check if mongorestore is available
if ! command -v mongorestore &> /dev/null; then
    # Try using Docker if mongorestore not installed locally
    if [ "$DOCKER_MODE" = true ] || command -v docker &> /dev/null; then
        log_info "Using mongorestore via Docker..."
        
        # Get the container name (this stack names it nightscout-mongo)
        MONGO_CONTAINER=$(docker ps --filter "name=nightscout-mongo" --format "{{.Names}}" | head -1)
        [ -n "$MONGO_CONTAINER" ] || MONGO_CONTAINER=$(docker ps --filter "name=mongo" --format "{{.Names}}" | head -1)

        if [ -z "$MONGO_CONTAINER" ]; then
            log_error "No MongoDB container found. Is it running?"
            exit 1
        fi
        
        log_info "Using container: $MONGO_CONTAINER"
        
        # Copy backup to container and restore
        docker cp "$BACKUP_FILE" "${MONGO_CONTAINER}:/tmp/restore.archive.gz"
        
        docker exec "$MONGO_CONTAINER" mongorestore \
            --archive=/tmp/restore.archive.gz \
            --gzip \
            --drop \
            --nsInclude="${MONGO_DB}.*"
        
        # Clean up
        docker exec "$MONGO_CONTAINER" rm /tmp/restore.archive.gz
    else
        log_error "mongorestore not found and Docker not available."
        log_error "Install MongoDB tools or use --docker flag with running container."
        exit 1
    fi
else
    # Use local mongorestore
    mongorestore \
        --host "$MONGO_HOST" \
        --port "$MONGO_PORT" \
        --archive="$BACKUP_FILE" \
        --gzip \
        --drop \
        --nsInclude="${MONGO_DB}.*"
fi

echo ""
log_success "Database restored successfully!"
echo ""
echo "=========================================="
echo "  Restore Complete!"
echo "=========================================="
echo ""
echo "The ${MONGO_DB} database has been restored from:"
echo "  $BACKUP_FILE"
echo ""
echo "You may need to restart Nightscout to see the changes."
echo ""
