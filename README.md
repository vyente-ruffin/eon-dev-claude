# eon-dev-claude

Voice-enabled AI assistant with swappable voice providers.

## Architecture

```
Frontend (SWA) → eon-api-claude (Container App) → eon-voice-claude (internal) → Azure OpenAI Realtime
```

The Static Web App's linked backend proxies `/api/*` requests to the Container App.

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Azure OpenAI resource with `gpt-4o-mini-realtime-preview` deployment
- Node.js 18+ (for SWA CLI)
- Git

## Deploy (4 Steps)

### Step 0: Clone the Repository

```bash
git clone https://github.com/vyente-ruffin/eon-dev-claude.git
cd eon-dev-claude
```

### Step 1: Deploy Infrastructure

```bash
az deployment sub create -l eastus2 -n eon-deploy -f infra/claude.bicep \
  -p resourceGroupName=rg-eon-claude \
  -p location=eastus2 \
  -p gitRepoUrl=https://github.com/vyente-ruffin/eon-dev-claude.git \
  -p voiceApiKey=<YOUR_AZURE_OPENAI_KEY>
```

This creates all Azure resources and builds Docker images via ACR Tasks.

### Step 2: Disable Auto-Enabled Auth

The linked backend auto-enables authentication on the Container App, which blocks WebSocket connections. Disable it:

```bash
az containerapp auth update -n eon-api-claude -g rg-eon-claude --enabled false
```

### Step 3: Deploy Frontend

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
| Azure Container Registry | Stores Docker images |
| Log Analytics Workspace | Logging |
| Container App Environment | Hosts containers |
| eon-api-claude | External API (WebSocket endpoint) |
| eon-voice-claude | Internal voice service |
| Static Web App | Frontend hosting with linked backend |
| User Assigned Identity | ACR pull permissions |

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

## Cleanup

```bash
az group delete -n rg-eon-claude --yes
```
