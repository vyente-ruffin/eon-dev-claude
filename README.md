# eon-dev-claude

Voice-enabled AI assistant with swappable voice providers.

## Architecture

```
Frontend → eon-api-claude (external) → eon-voice-claude (internal) → Azure OpenAI Realtime
```

## Prerequisites

- Azure CLI installed and logged in
- Azure OpenAI resource with `gpt-realtime` deployment
- Node.js (for SWA CLI)

## Deploy (3 Commands)

### Step 1: Deploy Infrastructure

```bash
az deployment sub create -l eastus2 -n my-eon-deploy -f infra/claude.bicep \
  -p resourceGroupName=rg-eon-claude \
  -p location=eastus2 \
  -p gitRepoUrl=https://github.com/vyente-ruffin/eon-dev-claude.git \
  -p voiceApiKey=<YOUR_AZURE_OPENAI_KEY>
```

### Step 2: Disable Auto-Enabled Auth

The linked backend auto-enables SWA authentication on the Container App, which blocks WebSocket connections. Disable it:

```bash
az containerapp auth update -n eon-api-claude -g rg-eon-claude --enabled false
```

### Step 3: Deploy Frontend

```bash
npm install -g @azure/static-web-apps-cli

swa deploy frontend --deployment-token $(az staticwebapp secrets list -n swa-eon-claude-dev -g rg-eon-claude --query properties.apiKey -o tsv) --env production
```

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

Static Web Apps are only available in: `eastus2`, `centralus`, `westus2`, `westeurope`, `eastasia`

## Get Your Azure OpenAI Key

```bash
az cognitiveservices account keys list \
  --name <your-openai-resource> \
  --resource-group <your-rg> \
  --query key1 -o tsv
```

## After Deployment

The Static Web App URL is output after Step 1. Or get it with:

```bash
az staticwebapp show -n swa-eon-claude-dev -g rg-eon-claude --query "defaultHostname" -o tsv
```
