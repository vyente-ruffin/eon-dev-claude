#!/bin/bash
# Azure Setup Script for Eon Claude
#
# This script automates:
# 1. Service principal creation with correct roles
# 2. Azure OpenAI quota verification
# 3. Soft-deleted resource cleanup
# 4. GitHub secrets configuration
#
# Usage:
#   ./scripts/setup-azure.sh <subscription-id> [github-repo]
#
# Examples:
#   ./scripts/setup-azure.sh 12345678-1234-1234-1234-123456789abc
#   ./scripts/setup-azure.sh 12345678-1234-1234-1234-123456789abc owner/repo

set -e

SUBSCRIPTION_ID="${1:?Subscription ID required}"
GITHUB_REPO="${2:-}"
LOCATION="${LOCATION:-eastus2}"
SP_NAME="${SP_NAME:-eon-deploy-sp}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=========================================="
echo "  Eon Claude - Azure Setup"
echo "=========================================="
echo ""

# Check Azure CLI login
echo "Checking Azure CLI login..."
if ! az account show &>/dev/null; then
    echo -e "${RED}Error: Not logged in to Azure CLI${NC}"
    echo "Run: az login"
    exit 1
fi

# Set subscription
echo "Setting subscription to $SUBSCRIPTION_ID..."
az account set --subscription "$SUBSCRIPTION_ID"

# ============================================================================
# 1. Check and purge soft-deleted OpenAI resources
# ============================================================================
echo ""
echo "Checking for soft-deleted OpenAI resources..."
DELETED=$(az cognitiveservices account list-deleted --query "[?location=='$LOCATION'].name" -o tsv 2>/dev/null || true)

if [ -n "$DELETED" ]; then
    echo -e "${YELLOW}Found soft-deleted OpenAI resources that may be holding quota:${NC}"
    echo "$DELETED"
    echo ""
    read -p "Purge these resources to free quota? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        for name in $DELETED; do
            echo "Purging $name..."
            # Get the resource group from the deleted resource
            az cognitiveservices account purge -l "$LOCATION" -n "$name" 2>/dev/null || echo "  (may already be purged)"
        done
        echo -e "${GREEN}Purge complete${NC}"
    fi
fi

# ============================================================================
# 2. Check Azure OpenAI quota
# ============================================================================
echo ""
echo "Checking Azure OpenAI quota in $LOCATION..."

# Check gpt-4o-mini quota
GPT_QUOTA=$(az cognitiveservices usage list -l "$LOCATION" \
    --query "[?contains(name.value, 'OpenAI.Standard.gpt-4o-mini')].{limit:limit, used:currentValue}" \
    -o tsv 2>/dev/null | head -1)

if [ -n "$GPT_QUOTA" ]; then
    GPT_LIMIT=$(echo "$GPT_QUOTA" | cut -f1)
    GPT_USED=$(echo "$GPT_QUOTA" | cut -f2)
    GPT_AVAILABLE=$((${GPT_LIMIT%.*} - ${GPT_USED%.*}))
    echo "  gpt-4o-mini: ${GPT_USED%.*}/${GPT_LIMIT%.*} TPM used ($GPT_AVAILABLE available)"

    if [ "$GPT_AVAILABLE" -lt 10 ]; then
        echo -e "${YELLOW}  Warning: Low quota. Deployment needs ~10 TPM minimum.${NC}"
    fi
else
    echo "  gpt-4o-mini: Unable to check (may need to enable in region)"
fi

# Check embedding quota
EMB_QUOTA=$(az cognitiveservices usage list -l "$LOCATION" \
    --query "[?contains(name.value, 'OpenAI.Standard.text-embedding-3-small')].{limit:limit, used:currentValue}" \
    -o tsv 2>/dev/null | head -1)

if [ -n "$EMB_QUOTA" ]; then
    EMB_LIMIT=$(echo "$EMB_QUOTA" | cut -f1)
    EMB_USED=$(echo "$EMB_QUOTA" | cut -f2)
    EMB_AVAILABLE=$((${EMB_LIMIT%.*} - ${EMB_USED%.*}))
    echo "  text-embedding-3-small: ${EMB_USED%.*}/${EMB_LIMIT%.*} TPM used ($EMB_AVAILABLE available)"

    if [ "$EMB_AVAILABLE" -lt 10 ]; then
        echo -e "${YELLOW}  Warning: Low quota. Deployment needs ~10 TPM minimum.${NC}"
    fi
else
    echo "  text-embedding-3-small: Unable to check"
fi

# ============================================================================
# 3. Create or update service principal
# ============================================================================
echo ""
echo "Setting up service principal '$SP_NAME'..."

# Check if SP already exists
EXISTING_SP=$(az ad sp list --display-name "$SP_NAME" --query "[0].appId" -o tsv 2>/dev/null || true)

if [ -n "$EXISTING_SP" ]; then
    echo "  Service principal already exists (appId: $EXISTING_SP)"
    APP_ID="$EXISTING_SP"

    # Reset credentials
    echo "  Resetting credentials..."
    SP_CREDS=$(az ad sp credential reset --id "$APP_ID" --query "{clientId:appId, clientSecret:password, tenantId:tenant}" -o json)
else
    echo "  Creating new service principal..."
    SP_CREDS=$(az ad sp create-for-rbac --name "$SP_NAME" \
        --role contributor \
        --scopes "/subscriptions/$SUBSCRIPTION_ID" \
        --query "{clientId:appId, clientSecret:password, tenantId:tenant}" -o json)
    APP_ID=$(echo "$SP_CREDS" | jq -r '.clientId')
fi

# Get object ID for role assignment
OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv)

# Assign User Access Administrator role (needed for role assignments in bicep)
echo "  Assigning User Access Administrator role..."
az role assignment create \
    --assignee-object-id "$OBJECT_ID" \
    --assignee-principal-type ServicePrincipal \
    --role "User Access Administrator" \
    --scope "/subscriptions/$SUBSCRIPTION_ID" \
    2>/dev/null || echo "  (role may already be assigned)"

# Build AZURE_CREDENTIALS JSON
AZURE_CREDS=$(jq -n \
    --arg clientId "$(echo "$SP_CREDS" | jq -r '.clientId')" \
    --arg clientSecret "$(echo "$SP_CREDS" | jq -r '.clientSecret')" \
    --arg subscriptionId "$SUBSCRIPTION_ID" \
    --arg tenantId "$(echo "$SP_CREDS" | jq -r '.tenantId')" \
    '{clientId: $clientId, clientSecret: $clientSecret, subscriptionId: $subscriptionId, tenantId: $tenantId}')

echo -e "${GREEN}  Service principal ready${NC}"

# ============================================================================
# 4. Configure GitHub secrets (if repo provided)
# ============================================================================
if [ -n "$GITHUB_REPO" ]; then
    echo ""
    echo "Configuring GitHub secrets for $GITHUB_REPO..."

    # Check if gh CLI is available
    if ! command -v gh &>/dev/null; then
        echo -e "${YELLOW}Warning: GitHub CLI (gh) not installed. Skipping GitHub configuration.${NC}"
        echo "Install with: brew install gh"
    else
        # Check if logged in
        if ! gh auth status &>/dev/null; then
            echo "Please login to GitHub CLI..."
            gh auth login
        fi

        # Set AZURE_CREDENTIALS
        echo "  Setting AZURE_CREDENTIALS..."
        echo "$AZURE_CREDS" | gh secret set AZURE_CREDENTIALS -R "$GITHUB_REPO"

        # Prompt for voice endpoint and key
        echo ""
        read -p "Enter VOICE_ENDPOINT (Azure OpenAI endpoint for realtime): " VOICE_ENDPOINT
        if [ -n "$VOICE_ENDPOINT" ]; then
            echo "$VOICE_ENDPOINT" | gh secret set VOICE_ENDPOINT -R "$GITHUB_REPO"
            echo -e "${GREEN}  VOICE_ENDPOINT set${NC}"
        fi

        read -sp "Enter VOICE_API_KEY (Azure OpenAI API key): " VOICE_API_KEY
        echo
        if [ -n "$VOICE_API_KEY" ]; then
            echo "$VOICE_API_KEY" | gh secret set VOICE_API_KEY -R "$GITHUB_REPO"
            echo -e "${GREEN}  VOICE_API_KEY set${NC}"
        fi

        echo ""
        echo -e "${GREEN}GitHub secrets configured!${NC}"
    fi
else
    echo ""
    echo "=========================================="
    echo "  Manual GitHub Configuration"
    echo "=========================================="
    echo ""
    echo "Add these secrets to your GitHub repo (Settings → Secrets → Actions):"
    echo ""
    echo "AZURE_CREDENTIALS:"
    echo "$AZURE_CREDS"
    echo ""
    echo "VOICE_ENDPOINT: <your Azure OpenAI endpoint>"
    echo "VOICE_API_KEY: <your Azure OpenAI API key>"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Ensure you have an Azure OpenAI resource with gpt-4o-mini-realtime-preview"
echo "  2. Run the GitHub Actions workflow: Actions → Deploy Eon Claude → Run workflow"
echo "  3. Or deploy manually: az deployment sub create -f infra/claude.bicep ..."
echo ""
