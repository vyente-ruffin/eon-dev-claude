#!/bin/bash
# promote-to-staging.sh
#
# Captures current dev container app configs and deploys to staging.
# This is the bridge from "portal experimentation" to "infrastructure as code".
#
# Usage: ./scripts/promote-to-staging.sh

set -e

# Configuration
DEV_RG="rg-eon-dev"
STAGING_RG="rg-eon-staging"
LOCATION="eastus2"

# Container apps to capture and promote
CONTAINER_APPS=(
    "eon-api-dev"
    "eon-voice-dev"
    "eon-memory-dev"
    "eon-voice-gemini-dev"
    "redis-dev"
)

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Promote Dev to Staging ===${NC}"
echo ""

# Step 1: Ensure staging resource group exists
echo -e "${YELLOW}Step 1: Ensuring staging resource group exists...${NC}"
az group create --name "$STAGING_RG" --location "$LOCATION" --tags project=eon environment=staging managed-by=bicep 2>/dev/null || true
echo "✓ Resource group $STAGING_RG ready"
echo ""

# Step 2: Export dev container app configs
echo -e "${YELLOW}Step 2: Exporting dev container app configs...${NC}"
mkdir -p /tmp/eon-export

for APP in "${CONTAINER_APPS[@]}"; do
    echo "  Exporting $APP..."
    az containerapp show -n "$APP" -g "$DEV_RG" -o json > "/tmp/eon-export/${APP}.json" 2>/dev/null
done
echo "✓ Exported ${#CONTAINER_APPS[@]} container apps"
echo ""

# Step 3: Check if staging environment exists, create if not
echo -e "${YELLOW}Step 3: Ensuring staging Container App Environment exists...${NC}"
STAGING_ENV_EXISTS=$(az containerapp env show -n eon-env-staging -g "$STAGING_RG" --query name -o tsv 2>/dev/null || echo "")

if [ -z "$STAGING_ENV_EXISTS" ]; then
    echo "  Creating Container App Environment for staging..."
    
    # Get Log Analytics workspace ID from dev (or create new one)
    LOG_WORKSPACE_ID=$(az monitor log-analytics workspace show -n eon-logs-dev -g "$DEV_RG" --query customerId -o tsv 2>/dev/null)
    LOG_WORKSPACE_KEY=$(az monitor log-analytics workspace get-shared-keys -n eon-logs-dev -g "$DEV_RG" --query primarySharedKey -o tsv 2>/dev/null)
    
    # Create staging log analytics workspace
    az monitor log-analytics workspace create \
        --resource-group "$STAGING_RG" \
        --workspace-name eon-logs-staging \
        --location "$LOCATION" \
        --tags project=eon environment=staging 2>/dev/null || true
    
    STAGING_LOG_ID=$(az monitor log-analytics workspace show -n eon-logs-staging -g "$STAGING_RG" --query customerId -o tsv)
    STAGING_LOG_KEY=$(az monitor log-analytics workspace get-shared-keys -n eon-logs-staging -g "$STAGING_RG" --query primarySharedKey -o tsv)
    
    # Create Container App Environment
    az containerapp env create \
        --name eon-env-staging \
        --resource-group "$STAGING_RG" \
        --location "$LOCATION" \
        --logs-workspace-id "$STAGING_LOG_ID" \
        --logs-workspace-key "$STAGING_LOG_KEY" \
        --tags project=eon environment=staging
    
    echo "✓ Created eon-env-staging"
else
    echo "✓ eon-env-staging already exists"
fi
echo ""

# Step 4: Create/update managed identity for staging
echo -e "${YELLOW}Step 4: Ensuring managed identity exists...${NC}"
az identity create \
    --name id-eon-acr-staging \
    --resource-group "$STAGING_RG" \
    --location "$LOCATION" \
    --tags project=eon environment=staging 2>/dev/null || true

STAGING_IDENTITY_ID=$(az identity show -n id-eon-acr-staging -g "$STAGING_RG" --query id -o tsv)
STAGING_IDENTITY_PRINCIPAL=$(az identity show -n id-eon-acr-staging -g "$STAGING_RG" --query principalId -o tsv)
echo "✓ Managed identity ready: id-eon-acr-staging"
echo ""

# Step 5: Grant ACR pull access to staging identity
echo -e "${YELLOW}Step 5: Granting ACR access to staging identity...${NC}"
ACR_ID=$(az acr show -n eonacrpa75j7hhoqfms --query id -o tsv 2>/dev/null)
az role assignment create \
    --assignee "$STAGING_IDENTITY_PRINCIPAL" \
    --role AcrPull \
    --scope "$ACR_ID" 2>/dev/null || true
echo "✓ ACR access granted"
echo ""

# Step 6: Deploy container apps to staging
echo -e "${YELLOW}Step 6: Deploying container apps to staging...${NC}"

STAGING_ENV_ID=$(az containerapp env show -n eon-env-staging -g "$STAGING_RG" --query id -o tsv)

for APP in "${CONTAINER_APPS[@]}"; do
    STAGING_APP="${APP//-dev/-staging}"
    echo "  Deploying $STAGING_APP..."
    
    # Extract config from dev export
    DEV_CONFIG="/tmp/eon-export/${APP}.json"
    
    # Get image, env vars, ingress settings
    IMAGE=$(jq -r '.properties.template.containers[0].image' "$DEV_CONFIG")
    TARGET_PORT=$(jq -r '.properties.configuration.ingress.targetPort // 8000' "$DEV_CONFIG")
    EXTERNAL=$(jq -r '.properties.configuration.ingress.external // false' "$DEV_CONFIG")
    TRANSPORT=$(jq -r '.properties.configuration.ingress.transport // "auto"' "$DEV_CONFIG")
    
    # Check if staging app exists
    EXISTING=$(az containerapp show -n "$STAGING_APP" -g "$STAGING_RG" --query name -o tsv 2>/dev/null || echo "")
    
    if [ -z "$EXISTING" ]; then
        # Create new container app
        az containerapp create \
            --name "$STAGING_APP" \
            --resource-group "$STAGING_RG" \
            --environment eon-env-staging \
            --image "$IMAGE" \
            --target-port "$TARGET_PORT" \
            --ingress "$( [ "$EXTERNAL" = "true" ] && echo "external" || echo "internal" )" \
            --transport "$TRANSPORT" \
            --registry-server eonacrpa75j7hhoqfms.azurecr.io \
            --registry-identity "$STAGING_IDENTITY_ID" \
            --user-assigned "$STAGING_IDENTITY_ID" \
            --min-replicas 1 \
            --max-replicas 3 \
            --tags project=eon environment=staging 2>/dev/null
    else
        # Update existing container app
        az containerapp update \
            --name "$STAGING_APP" \
            --resource-group "$STAGING_RG" \
            --image "$IMAGE" 2>/dev/null
    fi
    
    echo "  ✓ $STAGING_APP deployed"
done
echo ""

# Step 7: Copy environment variables and secrets
echo -e "${YELLOW}Step 7: Syncing environment variables...${NC}"
for APP in "${CONTAINER_APPS[@]}"; do
    STAGING_APP="${APP//-dev/-staging}"
    DEV_CONFIG="/tmp/eon-export/${APP}.json"
    
    # Extract env vars (non-secret)
    ENV_VARS=$(jq -r '.properties.template.containers[0].env // [] | map(select(.secretRef == null)) | map("--set-env-vars \(.name)=\"\(.value // "")\"") | join(" ")' "$DEV_CONFIG")
    
    if [ -n "$ENV_VARS" ] && [ "$ENV_VARS" != "" ]; then
        eval "az containerapp update -n $STAGING_APP -g $STAGING_RG $ENV_VARS" 2>/dev/null || true
    fi
done
echo "✓ Environment variables synced"
echo ""

echo -e "${GREEN}=== Promotion Complete ===${NC}"
echo ""
echo "Dev (rg-eon-dev) → Staging (rg-eon-staging)"
echo ""
echo "Staging container apps:"
az containerapp list -g "$STAGING_RG" --query "[].{name:name, url:properties.configuration.ingress.fqdn}" -o table 2>/dev/null

echo ""
echo -e "${YELLOW}Note: Secrets need to be set manually for staging.${NC}"
echo "Run: az containerapp secret set -n <app> -g rg-eon-staging --secrets <name>=<value>"
