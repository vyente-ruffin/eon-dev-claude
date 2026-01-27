#!/bin/bash
# Capture current Azure state into bicep and commit
#
# Usage: ./scripts/capture-state.sh [tag-name] [commit-message]
# Example: ./scripts/capture-state.sh v1.0.2 "capture: added new feature"

set -e

RESOURCE_GROUP="rg-eon-dev-claude"
TAG_NAME="${1:-}"
COMMIT_MSG="${2:-capture: Azure state $(date +%Y-%m-%d)}"
BICEP_FILE="infra/claude.bicep"
BICEP_RESOURCES="infra/claude-resources.bicep"

echo "=== Capturing Azure state from $RESOURCE_GROUP ==="

# Get current image tags
echo "Fetching image tags..."
API_IMAGE=$(az containerapp show -n eon-api-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].image" -o tsv 2>/dev/null)
VOICE_IMAGE=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].image" -o tsv 2>/dev/null)
MEMORY_IMAGE=$(az containerapp show -n eon-memory-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].image" -o tsv 2>/dev/null)

API_TAG=$(echo $API_IMAGE | sed 's/.*://')
VOICE_TAG=$(echo $VOICE_IMAGE | sed 's/.*://')
echo "  API: $API_TAG"
echo "  Voice: $VOICE_TAG"
echo "  Memory: $MEMORY_IMAGE"

# Get scaling settings
echo "Fetching scaling settings..."
API_MIN=$(az containerapp show -n eon-api-claude -g $RESOURCE_GROUP --query "properties.template.scale.minReplicas" -o tsv 2>/dev/null)
API_MAX=$(az containerapp show -n eon-api-claude -g $RESOURCE_GROUP --query "properties.template.scale.maxReplicas" -o tsv 2>/dev/null)
VOICE_MIN=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.scale.minReplicas" -o tsv 2>/dev/null)
VOICE_MAX=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.scale.maxReplicas" -o tsv 2>/dev/null)
echo "  API: min=$API_MIN, max=$API_MAX"
echo "  Voice: min=$VOICE_MIN, max=$VOICE_MAX"

# Get env vars
echo "Fetching environment variables..."
VOICE_ENDPOINT=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].env[?name=='VOICE_ENDPOINT'].value" -o tsv 2>/dev/null)
VOICE_MODEL=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].env[?name=='VOICE_MODEL'].value" -o tsv 2>/dev/null)
VOICE_NAME=$(az containerapp show -n eon-voice-claude -g $RESOURCE_GROUP --query "properties.template.containers[0].env[?name=='VOICE_NAME'].value" -o tsv 2>/dev/null)
echo "  VOICE_ENDPOINT: $VOICE_ENDPOINT"
echo "  VOICE_MODEL: $VOICE_MODEL"
echo "  VOICE_NAME: $VOICE_NAME"

# Get OpenAI deployments
echo "Fetching OpenAI deployments..."
OPENAI_NAME=$(az cognitiveservices account list -g $RESOURCE_GROUP --query "[0].name" -o tsv 2>/dev/null)
EMBED_CAP=$(az cognitiveservices account deployment show -g $RESOURCE_GROUP -n $OPENAI_NAME --deployment-name text-embedding-3-small --query "sku.capacity" -o tsv 2>/dev/null || echo "120")
CHAT_CAP=$(az cognitiveservices account deployment show -g $RESOURCE_GROUP -n $OPENAI_NAME --deployment-name gpt-4o-mini --query "sku.capacity" -o tsv 2>/dev/null || echo "120")
REALTIME_CAP=$(az cognitiveservices account deployment show -g $RESOURCE_GROUP -n $OPENAI_NAME --deployment-name gpt-realtime --query "sku.capacity" -o tsv 2>/dev/null || echo "1")
echo "  Embedding capacity: $EMBED_CAP"
echo "  Chat capacity: $CHAT_CAP"
echo "  Realtime capacity: $REALTIME_CAP"

echo ""
echo "=== Updating bicep files ==="

# Update claude.bicep
sed -i.bak "s/param apiImageTag string = '.*'/param apiImageTag string = '$API_TAG'/" $BICEP_FILE
sed -i.bak "s/param voiceImageTag string = '.*'/param voiceImageTag string = '$VOICE_TAG'/" $BICEP_FILE
sed -i.bak "s|param voiceEndpoint string = '.*'|param voiceEndpoint string = '$VOICE_ENDPOINT'|" $BICEP_FILE
sed -i.bak "s/param voiceModel string = '.*'/param voiceModel string = '$VOICE_MODEL'/" $BICEP_FILE
sed -i.bak "s/param voiceName string = '.*'/param voiceName string = '$VOICE_NAME'/" $BICEP_FILE

# Update claude-resources.bicep scaling
sed -i.bak "s/minReplicas: [0-9]*/minReplicas: $API_MIN/g" $BICEP_RESOURCES
sed -i.bak "s/maxReplicas: [0-9]*/maxReplicas: $API_MAX/g" $BICEP_RESOURCES

# Update OpenAI capacities
sed -i.bak "/name: 'text-embedding-3-small'/{n;n;s/capacity: [0-9]*/capacity: $EMBED_CAP/;}" $BICEP_RESOURCES
sed -i.bak "/name: 'gpt-4o-mini'/{n;n;s/capacity: [0-9]*/capacity: $CHAT_CAP/;}" $BICEP_RESOURCES
sed -i.bak "/name: 'gpt-realtime'/{n;n;s/capacity: [0-9]*/capacity: $REALTIME_CAP/;}" $BICEP_RESOURCES

rm -f $BICEP_FILE.bak $BICEP_RESOURCES.bak

echo "Bicep files updated."

# Verify with what-if
echo ""
echo "=== Running what-if to verify ==="
az deployment sub what-if \
  --location eastus2 \
  --template-file infra/claude.bicep \
  --parameters resourceGroupName=$RESOURCE_GROUP \
  --parameters voiceApiKey="placeholder" \
  --output table 2>&1 | tail -10

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
echo "State captured. To restore: git checkout ${TAG_NAME:-main} && gh workflow run deploy.yml -f environment=dev -f location=eastus2"
