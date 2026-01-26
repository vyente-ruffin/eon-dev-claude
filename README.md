# eon-dev-claude

Voice-enabled AI assistant with long-term memory and swappable voice providers.

## Architecture

```
Frontend (SWA) → eon-api-claude → eon-voice-claude → Azure OpenAI Realtime
                       ↓
                eon-memory-claude → Redis (persistent storage)
                       ↓
                 Azure OpenAI (embeddings + chat)
```

The Static Web App's linked backend proxies `/api/*` requests to the Container App.

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- GitHub CLI installed and logged in (`gh auth login`)
- Azure OpenAI resource with `gpt-4o-mini-realtime-preview` deployment (for voice)
- **Azure OpenAI quota available** (minimum: 50K TPM for gpt-4o-mini, 10K TPM for text-embedding-3-small)
- Node.js 18+ (for SWA CLI)
- Git

## Deploy via GitHub Actions

This is the recommended deployment method. Follow these steps exactly.

### Step 1: Fork and Clone

```bash
git clone https://github.com/vyente-ruffin/eon-dev-claude.git
cd eon-dev-claude
```

### Step 2: Create Azure Service Principal

The service principal needs TWO roles: Contributor (to create resources) and User Access Administrator (to assign roles to managed identities).

```bash
# Set your subscription ID
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Create service principal with Contributor role and save credentials
az ad sp create-for-rbac --name "eon-deploy-sp" --role contributor \
  --scopes /subscriptions/$SUBSCRIPTION_ID --sdk-auth > sp-credentials.json

# Get the service principal object ID
SP_OBJECT_ID=$(az ad sp list --display-name "eon-deploy-sp" --query "[0].id" -o tsv)

# Add User Access Administrator role (required for role assignments in Bicep)
az role assignment create --assignee $SP_OBJECT_ID \
  --role "User Access Administrator" \
  --scope /subscriptions/$SUBSCRIPTION_ID
```

### Step 3: Set GitHub Secrets

```bash
# Set the Azure credentials (from the JSON file created above)
gh secret set AZURE_CREDENTIALS < sp-credentials.json

# Set your Azure OpenAI endpoint (the one with gpt-4o-mini-realtime-preview)
gh secret set VOICE_ENDPOINT -b "https://your-openai.openai.azure.com"

# Set your Azure OpenAI API key
gh secret set VOICE_API_KEY -b "your-api-key-here"
```

### Step 4: Run the Deployment

```bash
# Deploy to dev environment in eastus2
gh workflow run deploy.yml -f environment=dev -f location=eastus2 -f image_tag=v1.0.0

# Watch the deployment progress
gh run watch
```

### Step 5: Verify Deployment

```bash
# Get the deployed URL
RESOURCE_GROUP="rg-eon-dev-claude"  # or rg-eon-prod-claude for prod
URL=$(az staticwebapp list -g $RESOURCE_GROUP --query "[0].defaultHostname" -o tsv)
echo "App URL: https://$URL"

# Test health endpoint
curl https://$URL/api/health
# Expected: {"status":"ok"}
```

Then open `https://$URL` in your browser. Status should show "Online" and "Ready".

## Alternative: Manual CLI Deploy

Use this if you prefer not to use GitHub Actions.

### Step 1: Clone the Repository

```bash
git clone https://github.com/vyente-ruffin/eon-dev-claude.git
cd eon-dev-claude
```

### Step 2: Deploy Infrastructure

```bash
az deployment sub create -l eastus2 -n eon-deploy -f infra/claude.bicep \
  -p resourceGroupName=rg-eon-claude \
  -p location=eastus2 \
  -p voiceEndpoint=https://your-openai.openai.azure.com \
  -p voiceApiKey=<YOUR_AZURE_OPENAI_KEY> \
  -p gitRepoUrl=https://github.com/vyente-ruffin/eon-dev-claude.git
```

This creates all Azure resources and builds Docker images via ACR Tasks.

### Step 3: Disable Auto-Enabled Auth

The linked backend auto-enables authentication on the Container App, which blocks WebSocket connections. Disable it:

```bash
az containerapp auth update -n eon-api-claude -g rg-eon-claude --enabled false
```

### Step 4: Deploy Frontend

```bash
npm install -g @azure/static-web-apps-cli

SWA_NAME=$(az staticwebapp list -g rg-eon-claude --query "[0].name" -o tsv)
DEPLOY_TOKEN=$(az staticwebapp secrets list -n $SWA_NAME -g rg-eon-claude --query properties.apiKey -o tsv)

swa deploy frontend --deployment-token "$DEPLOY_TOKEN" --env production
```

### Step 5: Verify

```bash
URL=$(az staticwebapp list -g rg-eon-claude --query "[0].defaultHostname" -o tsv)
echo "App URL: https://$URL"
curl https://$URL/api/health
```

## Verify Deployment

### Get Your App URL

```bash
az staticwebapp show -n swa-eon-claude-dev -g rg-eon-claude --query "defaultHostname" -o tsv
```

### Test API Endpoints

```bash
# Health check (should return {"status":"ok"})
curl https://<YOUR_SWA_URL>/api/health

# Config endpoint (should return wsUrl and apiUrl)
curl https://<YOUR_SWA_URL>/api/config
```

### Test in Browser

1. Open `https://<YOUR_SWA_URL>` in your browser
2. Allow microphone access (or dismiss the dialog)
3. Status should show "Online" and "Ready"
4. Type a message in the text box and click Send
5. You should hear an audio response

## What Gets Created

| Resource | Purpose |
|----------|---------|
| Azure OpenAI | Embeddings + chat for memory service |
| Azure Container Registry | Stores Docker images |
| Storage Account | Persistent storage for Redis |
| Log Analytics Workspace | Logging |
| Container App Environment | Hosts containers |
| redis-claude | Redis with RediSearch for vector storage |
| eon-memory-claude | Long-term memory service |
| eon-voice-claude | Voice service (internal) |
| eon-api-claude | External API (WebSocket endpoint) |
| Static Web App | Frontend hosting with linked backend |
| User Assigned Identity | ACR pull permissions |

## Redis Data Backup & Restore

The Redis data is persisted on an Azure File share and survives container restarts.

### Backup

```bash
./scripts/redis-backup.sh rg-eon-claude ./backups
```

### Restore

```bash
./scripts/redis-restore.sh rg-eon-claude ./backups/redis-backup-20260125-143000.rdb
```

## Available Regions

Static Web Apps are available in: `eastus2`, `centralus`, `westus2`, `westeurope`, `eastasia`

## Get Your Azure OpenAI Key

```bash
az cognitiveservices account keys list \
  --name <your-openai-resource> \
  --resource-group <your-rg> \
  --query key1 -o tsv
```

## Troubleshooting

### Deployment fails with "InsufficientQuota"

Azure OpenAI has subscription-wide quota limits. Check your current usage:

```bash
az cognitiveservices usage list -l eastus2 --query "[?contains(name.value, 'gpt-4o-mini')]" -o table
```

To free up quota, delete unused OpenAI deployments or request a quota increase in Azure Portal.

If you see soft-deleted accounts holding quota:
```bash
# List soft-deleted accounts
az cognitiveservices account list-deleted -o table

# Purge to release quota
az cognitiveservices account purge -l eastus2 -n <account-name> -g <resource-group>
```

### Deployment fails with "Authorization failed for roleAssignments"

The service principal needs User Access Administrator role. Add it:

```bash
SP_OBJECT_ID=$(az ad sp list --display-name "eon-deploy-sp" --query "[0].id" -o tsv)
az role assignment create --assignee $SP_OBJECT_ID \
  --role "User Access Administrator" \
  --scope /subscriptions/$(az account show --query id -o tsv)
```

### "Offline" status in browser

- The workflow automatically disables auth, but verify: `az containerapp show -n eon-api-claude -g rg-eon-dev-claude --query "properties.configuration.ingress.authEnabled"`
- If true, disable it: `az containerapp auth update -n eon-api-claude -g rg-eon-dev-claude --enabled false`
- Check container logs: `az containerapp logs show -n eon-api-claude -g rg-eon-dev-claude --follow`

### WebSocket connection fails

- Ensure auth is disabled on the Container App
- Check that the Container App is running with at least 1 replica

### 404 on /api/health

- The SWA linked backend proxies `/api/*` to the Container App
- If hitting the Container App directly, use `/health` (no `/api` prefix)

### Memory not saving

- Check eon-memory-claude logs: `az containerapp logs show -n eon-memory-claude -g rg-eon-dev-claude --follow`
- Verify Redis is running: `az containerapp logs show -n redis-claude -g rg-eon-dev-claude --tail 20`

## Cleanup

```bash
az group delete -n rg-eon-claude --yes
```

## Version History

This repository uses Git for version control. To rollback to a previous version:

```bash
# View commit history
git log --oneline

# Checkout a previous version
git checkout <commit-hash>

# Redeploy from that version
az deployment sub create -l eastus2 -f infra/claude.bicep ...
```
