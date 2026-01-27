# eon-dev-claude

Voice-enabled AI assistant with long-term memory and swappable voice providers.

## Deploy (One Command)

GitHub Secrets are already configured. To deploy or restore this version:

```bash
cd eon-dev-claude
gh workflow run deploy.yml -f environment=dev -f location=eastus2
gh run watch
```

**Environments:**
- `dev` → deploys to `rg-eon-dev-claude`
- `prod` → deploys to `rg-eon-prod-claude`

**Verify after deploy:**
```bash
URL=$(az staticwebapp list -g rg-eon-dev-claude --query "[0].defaultHostname" -o tsv)
echo "https://$URL"
curl https://$URL/api/health
```

---

## Architecture

```
Frontend (SWA) → eon-api-claude → eon-voice-claude → Azure OpenAI Realtime
                       ↓
                eon-memory-claude → Redis (persistent storage)
                       ↓
                 Azure OpenAI (embeddings + chat)
```

---

## First-Time Setup (Only If Secrets Not Configured)

Skip this section if GitHub Secrets (`AZURE_CREDENTIALS`, `VOICE_ENDPOINT`, `VOICE_API_KEY`) are already set.

### Prerequisites

- Azure CLI: `az login`
- GitHub CLI: `gh auth login`
- Azure OpenAI quota: 50K TPM gpt-4o-mini, 10K TPM text-embedding-3-small

### Step 1: Create Service Principal

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az ad sp create-for-rbac --name "eon-deploy-sp" --role contributor \
  --scopes /subscriptions/$SUBSCRIPTION_ID --sdk-auth > sp-credentials.json

SP_OBJECT_ID=$(az ad sp list --display-name "eon-deploy-sp" --query "[0].id" -o tsv)

az role assignment create --assignee $SP_OBJECT_ID \
  --role "User Access Administrator" \
  --scope /subscriptions/$SUBSCRIPTION_ID
```

### Step 2: Set GitHub Secrets

```bash
gh secret set AZURE_CREDENTIALS < sp-credentials.json
gh secret set VOICE_ENDPOINT -b "https://jarvis-voice-openai.openai.azure.com"
gh secret set VOICE_API_KEY -b "<your-api-key>"
```

### Step 3: Deploy

```bash
gh workflow run deploy.yml -f environment=dev -f location=eastus2 -f image_tag=v1.0.0
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

## Capture & Restore

### Capture Current State

After making changes to Azure that you want to keep:

```bash
# 1. Verify bicep matches Azure (no destructive changes)
az deployment sub what-if --location eastus2 --template-file infra/claude.bicep \
  --parameters resourceGroupName=rg-eon-dev-claude \
  --parameters voiceApiKey="placeholder"

# 2. If differences exist, update bicep files to match Azure

# 3. Commit and tag
git add -A
git commit -m "capture: description of changes"
git tag v1.0.x
git push origin main --tags
```

### Restore Previous State

```bash
# View available versions
git tag

# Checkout and deploy
git checkout v1.0.1
gh workflow run deploy.yml -f environment=dev -f location=eastus2
gh run watch
```

### What Gets Captured

| Item | Location | Captured in Git? |
|------|----------|------------------|
| Infrastructure | Bicep files | Yes |
| Container image tags | Bicep params | Yes |
| Container images | ACR | No (already in registry) |
| Secrets | GitHub Secrets | No (persist separately) |
| Redis data | Azure File Share | No (persists in Azure) |
