#!/bin/bash
# Capture current Azure state into bicep and commit
#
# Usage: ./scripts/capture-state.sh [tag-name] [commit-message]
# Example: ./scripts/capture-state.sh v1.0.2 "capture: added new feature"

set -e

RESOURCE_GROUP="rg-eon-dev-claude"
TAG_NAME="${1:-}"
COMMIT_MSG="${2:-capture: Azure state $(date +%Y-%m-%d)}"

echo "=== Capturing Azure state from $RESOURCE_GROUP ==="

# Get current image tags
API_IMAGE=$(az containerapp show -n eon-api-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].image" -o tsv 2>/dev/null)
VOICE_IMAGE=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].image" -o tsv 2>/dev/null)

API_TAG=$(echo $API_IMAGE | sed 's/.*://')
VOICE_TAG=$(echo $VOICE_IMAGE | sed 's/.*://')

echo "API image tag: $API_TAG"
echo "Voice image tag: $VOICE_TAG"

# Update bicep with current tags
sed -i.bak "s/param apiImageTag string = '.*'/param apiImageTag string = '$API_TAG'/" infra/claude.bicep
sed -i.bak "s/param voiceImageTag string = '.*'/param voiceImageTag string = '$VOICE_TAG'/" infra/claude.bicep
rm -f infra/claude.bicep.bak

# Verify with what-if
echo ""
echo "=== Running what-if to verify ==="
az deployment sub what-if \
  --location eastus2 \
  --template-file infra/claude.bicep \
  --parameters resourceGroupName=$RESOURCE_GROUP \
  --parameters voiceApiKey="placeholder" \
  --output table 2>&1 | tail -5

# Commit
echo ""
echo "=== Committing changes ==="
git add -A
git commit -m "$COMMIT_MSG" || echo "No changes to commit"

# Tag if provided
if [ -n "$TAG_NAME" ]; then
  echo "=== Tagging as $TAG_NAME ==="
  git tag -f "$TAG_NAME" -m "$COMMIT_MSG"
  git push origin main --tags --force
else
  git push origin main
fi

echo ""
echo "=== Done ==="
echo "State captured. To restore: git checkout $TAG_NAME && gh workflow run deploy.yml -f environment=dev -f location=eastus2"
