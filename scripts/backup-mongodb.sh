#!/usr/bin/env bash
#
# MongoDB Backup Script for Nightscout
#
# Creates a compressed backup of the MongoDB database and optionally
# uploads it to AWS S3.
#
# Usage:
#   ./backup-mongodb.sh                    # Local backup only
#   ./backup-mongodb.sh --upload           # Backup and upload to S3
#   ./backup-mongodb.sh --upload --cleanup # Also delete old S3 backups
#
# Environment variables (or set in config/backup.env):
#   MONGO_HOST        - MongoDB host (default: localhost)
#   MONGO_PORT        - MongoDB port (default: 27017)
#   MONGO_DB          - Database name (default: nightscout)
#   S3_BUCKET         - S3 bucket name for backups
#   S3_PREFIX         - S3 prefix/folder (default: nightscout-backups)
#   BACKUP_RETENTION  - Number of backups to keep in S3 (default: 30)
#

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="${PROJECT_DIR}/backups"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Load environment from file if exists
if [ -f "${PROJECT_DIR}/config/backup.env" ]; then
    source "${PROJECT_DIR}/config/backup.env"
fi

# Defaults
MONGO_HOST="${MONGO_HOST:-localhost}"
MONGO_PORT="${MONGO_PORT:-27017}"
MONGO_DB="${MONGO_DB:-nightscout}"
S3_PREFIX="${S3_PREFIX:-nightscout-backups}"
BACKUP_RETENTION="${BACKUP_RETENTION:-30}"

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

UPLOAD_TO_S3=false
CLEANUP_OLD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --upload)
            UPLOAD_TO_S3=true
            shift
            ;;
        --cleanup)
            CLEANUP_OLD=true
            shift
            ;;
        --docker)
            # Use Docker container's MongoDB
            MONGO_HOST="localhost"
            DOCKER_MODE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --upload    Upload backup to S3 after creation"
            echo "  --cleanup   Delete old backups from S3 (keeps last $BACKUP_RETENTION)"
            echo "  --docker    Connect to MongoDB in Docker container"
            echo "  -h, --help  Show this help message"
            echo ""
            echo "Environment variables:"
            echo "  MONGO_HOST       MongoDB host (default: localhost)"
            echo "  MONGO_PORT       MongoDB port (default: 27017)"
            echo "  MONGO_DB         Database name (default: nightscout)"
            echo "  S3_BUCKET        S3 bucket name (required for --upload)"
            echo "  S3_PREFIX        S3 prefix/folder (default: nightscout-backups)"
            echo "  BACKUP_RETENTION Number of S3 backups to keep (default: 30)"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Main Backup Process
# =============================================================================

echo ""
echo "=========================================="
echo "  MongoDB Backup - ${TIMESTAMP}"
echo "=========================================="
echo ""

# Create backup directory
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="${BACKUP_DIR}/nightscout_${TIMESTAMP}.archive.gz"

# -----------------------------------------------------------------------------
# Step 1: Create MongoDB Dump
# -----------------------------------------------------------------------------

log_info "Creating MongoDB backup..."
log_info "Host: ${MONGO_HOST}:${MONGO_PORT}"
log_info "Database: ${MONGO_DB}"
echo ""

# Check if mongodump is available
if ! command -v mongodump &> /dev/null; then
    # Try using Docker if mongodump not installed locally
    if [ "${DOCKER_MODE:-false}" = true ] || command -v docker &> /dev/null; then
        log_info "Using mongodump from Docker container..."
        
        # Get the container name
        MONGO_CONTAINER=$(docker ps --filter "name=mongo" --format "{{.Names}}" | head -1)
        
        if [ -z "$MONGO_CONTAINER" ]; then
            log_error "No MongoDB container found. Is it running?"
            exit 1
        fi
        
        log_info "Using container: $MONGO_CONTAINER"
        
        # Run mongodump inside the container
        docker exec "$MONGO_CONTAINER" mongodump \
            --db "$MONGO_DB" \
            --archive \
            --gzip \
            > "$BACKUP_FILE"
    else
        log_error "mongodump not found and Docker not available."
        log_error "Install MongoDB tools or use --docker flag with running container."
        exit 1
    fi
else
    # Use local mongodump
    mongodump \
        --host "$MONGO_HOST" \
        --port "$MONGO_PORT" \
        --db "$MONGO_DB" \
        --archive="$BACKUP_FILE" \
        --gzip
fi

BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
log_success "Backup created: $BACKUP_FILE ($BACKUP_SIZE)"
echo ""

# -----------------------------------------------------------------------------
# Step 2: Upload to S3 (optional)
# -----------------------------------------------------------------------------

if [ "$UPLOAD_TO_S3" = true ]; then
    log_info "Uploading backup to S3..."

    if [ -z "$S3_BUCKET" ]; then
        log_error "S3_BUCKET environment variable not set!"
        log_error "Set it in config/backup.env or export S3_BUCKET=your-bucket-name"
        exit 1
    fi

    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not installed. Install it to use S3 uploads."
        exit 1
    fi

    S3_PATH="s3://${S3_BUCKET}/${S3_PREFIX}/nightscout_${TIMESTAMP}.archive.gz"
    
    aws s3 cp "$BACKUP_FILE" "$S3_PATH"
    
    log_success "Uploaded to: $S3_PATH"
    echo ""

    # -------------------------------------------------------------------------
    # Step 3: Cleanup old backups (optional)
    # -------------------------------------------------------------------------

    if [ "$CLEANUP_OLD" = true ]; then
        log_info "Cleaning up old S3 backups (keeping last $BACKUP_RETENTION)..."

        # List backups sorted by date, get ones to delete
        BACKUPS_TO_DELETE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
            | grep "nightscout_.*\.archive\.gz" \
            | sort -r \
            | tail -n +$((BACKUP_RETENTION + 1)) \
            | awk '{print $4}')

        if [ -n "$BACKUPS_TO_DELETE" ]; then
            for backup in $BACKUPS_TO_DELETE; do
                log_info "Deleting: $backup"
                aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${backup}"
            done
            log_success "Old backups cleaned up"
        else
            log_info "No old backups to delete"
        fi
        echo ""
    fi
fi

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

echo "=========================================="
echo "  Backup Complete!"
echo "=========================================="
echo ""
echo "Local backup: $BACKUP_FILE"
if [ "$UPLOAD_TO_S3" = true ]; then
    echo "S3 backup:    $S3_PATH"
fi
echo ""
echo "To restore from this backup:"
echo "  ./scripts/restore-mongodb.sh $BACKUP_FILE"
echo ""
