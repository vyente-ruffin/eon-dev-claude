#!/bin/bash
# Redis Backup Script for Eon Claude
#
# This script backs up Redis data from the Azure File share.
# Redis automatically persists data to /data/dump.rdb which is mounted
# on an Azure File share.
#
# Usage:
#   ./scripts/redis-backup.sh <resource-group> [backup-dir]
#
# Examples:
#   ./scripts/redis-backup.sh rg-eon-dev-claude
#   ./scripts/redis-backup.sh rg-eon-dev-claude ./backups

set -e

RESOURCE_GROUP="${1:?Resource group name required}"
BACKUP_DIR="${2:-./backups}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "=== Redis Backup for $RESOURCE_GROUP ==="

# Get storage account info
echo "Getting storage account details..."
STORAGE_ACCOUNT=$(az storage account list -g "$RESOURCE_GROUP" --query "[?contains(name, 'eonstorage')].name" -o tsv)

if [ -z "$STORAGE_ACCOUNT" ]; then
    echo "Error: Storage account not found in $RESOURCE_GROUP"
    exit 1
fi

echo "Storage account: $STORAGE_ACCOUNT"

# Get storage key
STORAGE_KEY=$(az storage account keys list -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT" --query "[0].value" -o tsv)

# Create backup directory
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/redis-backup-$TIMESTAMP.rdb"

# Trigger BGSAVE on Redis (optional - Redis auto-saves periodically)
echo "Triggering Redis background save..."
az containerapp exec -n redis-claude -g "$RESOURCE_GROUP" --command "redis-cli BGSAVE" 2>/dev/null || echo "Warning: Could not trigger BGSAVE (Redis may be saving automatically)"

# Wait for save to complete
sleep 5

# Download the dump.rdb from Azure File share
echo "Downloading Redis data from Azure File share..."
az storage file download \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --share-name "redis-data" \
    --path "dump.rdb" \
    --dest "$BACKUP_FILE" \
    --no-progress 2>/dev/null || {
        echo "Note: dump.rdb may not exist yet (no data saved)"
        echo "Backup location prepared at: $BACKUP_FILE"
        exit 0
    }

echo ""
echo "=== Backup Complete ==="
echo "Backup saved to: $BACKUP_FILE"
echo "Backup size: $(du -h "$BACKUP_FILE" | cut -f1)"
echo ""
echo "To restore this backup, run:"
echo "  ./scripts/redis-restore.sh $RESOURCE_GROUP $BACKUP_FILE"
