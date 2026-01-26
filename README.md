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
- Azure OpenAI resource with `gpt-4o-mini-realtime-preview` deployment (for voice)
- Node.js 18+ (for SWA CLI)
- Git

## Deploy Options

### Option A: GitHub Actions (Recommended)

1. **Fork this repository** to your GitHub account

2. **Create Azure Service Principal**:
   ```bash
   az ad sp create-for-rbac --name "eon-deploy-sp" --role contributor \
     --scopes /subscriptions/<YOUR_SUBSCRIPTION_ID> --sdk-auth
   ```
   Copy the JSON output.

3. **Configure GitHub Secrets** (Settings → Secrets and variables → Actions):

   | Secret Name | Description | Required |
   |-------------|-------------|----------|
   | `AZURE_CREDENTIALS` | JSON output from step 2 | Yes |
   | `VOICE_ENDPOINT` | Azure OpenAI endpoint (e.g., `https://your-openai.openai.azure.com`) | Yes |
   | `VOICE_API_KEY` | Azure OpenAI API key for voice | Yes |
   | `MEMORY_API_KEY` | Azure OpenAI API key for memory (optional, auto-provisioned if not set) | No |

4. **Run the workflow**:
   - Go to Actions → "Deploy Eon Claude"
   - Click "Run workflow"
   - Select environment (dev/prod) and region
   - Click "Run workflow"

### Option B: Manual CLI Deploy

#### Step 0: Clone the Repository

```bash
git clone https://github.com/your-org/eon-dev-claude.git
cd eon-dev-claude
```

#### Step 1: Deploy Infrastructure

```bash
az deployment sub create -l eastus2 -n eon-deploy -f infra/claude.bicep \
  -p resourceGroupName=rg-eon-claude \
  -p location=eastus2 \
  -p voiceEndpoint=https://your-openai.openai.azure.com \
  -p voiceApiKey=<YOUR_AZURE_OPENAI_KEY> \
  -p gitRepoUrl=https://github.com/your-org/eon-dev-claude.git
```

This creates all Azure resources and builds Docker images via ACR Tasks.

#### Step 2: Disable Auto-Enabled Auth

The linked backend auto-enables authentication on the Container App, which blocks WebSocket connections. Disable it:

```bash
az containerapp auth update -n eon-api-claude -g rg-eon-claude --enabled false
```

#### Step 3: Deploy Frontend

```bash
npm install -g @azure/static-web-apps-cli

swa deploy frontend \
  --deployment-token $(az staticwebapp secrets list -n swa-eon-claude-dev -g rg-eon-claude --query properties.apiKey -o tsv) \
  --env production
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

### "Offline" status in browser
- Check that Step 2 was completed (auth disabled)
- Check container logs: `az containerapp logs show -n eon-api-claude -g rg-eon-claude --follow`

### WebSocket connection fails
- Ensure auth is disabled on the Container App
- Check that the Container App is running with at least 1 replica

### 404 on /api/health
- The SWA linked backend proxies `/api/*` to the Container App
- If hitting the Container App directly, use `/health` (no `/api` prefix)

### Memory not saving
- Check eon-memory-claude logs: `az containerapp logs show -n eon-memory-claude -g rg-eon-claude --follow`
- Verify Redis is running: `az containerapp logs show -n redis-claude -g rg-eon-claude --tail 20`

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
