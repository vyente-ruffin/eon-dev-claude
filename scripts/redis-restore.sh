#!/bin/bash
# Redis Restore Script for Eon Claude
#
# This script restores Redis data from a backup file to the Azure File share.
# After restoring, it restarts the Redis container to load the data.
#
# Usage:
#   ./scripts/redis-restore.sh <resource-group> <backup-file>
#
# Examples:
#   ./scripts/redis-restore.sh rg-eon-dev-claude ./backups/redis-backup-20260125-143000.rdb
#
# WARNING: This will overwrite existing Redis data!

set -e

RESOURCE_GROUP="${1:?Resource group name required}"
BACKUP_FILE="${2:?Backup file path required}"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "=== Redis Restore for $RESOURCE_GROUP ==="
echo "Backup file: $BACKUP_FILE"
echo ""
echo "WARNING: This will overwrite existing Redis data!"
read -p "Continue? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

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

# Upload the backup file to Azure File share
echo "Uploading backup to Azure File share..."
az storage file upload \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$STORAGE_KEY" \
    --share-name "redis-data" \
    --source "$BACKUP_FILE" \
    --path "dump.rdb" \
    --no-progress

# Restart Redis container to load the restored data
echo "Restarting Redis container to load restored data..."
az containerapp revision restart -n redis-claude -g "$RESOURCE_GROUP" \
    --revision "$(az containerapp show -n redis-claude -g "$RESOURCE_GROUP" --query 'properties.latestRevisionName' -o tsv)"

echo ""
echo "=== Restore Complete ==="
echo "Redis has been restarted with the restored data."
echo ""
echo "Wait ~30 seconds for Redis to fully start, then verify with:"
echo "  az containerapp logs show -n redis-claude -g $RESOURCE_GROUP --tail 20"
