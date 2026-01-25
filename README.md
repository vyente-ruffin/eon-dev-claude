# eon-dev-claude

Voice-enabled AI assistant with swappable voice providers.

## Architecture

```
Frontend → eon-api-claude (external) → eon-voice-claude (internal) → Azure OpenAI Realtime
```

## Prerequisites

- Azure CLI installed and logged in
- Azure OpenAI resource with `gpt-realtime` deployment

## Deploy

One command:

```bash
az deployment sub create -l eastus2 -f infra/claude.bicep \
  -p resourceGroupName=rg-eon-claude \
  -p gitRepoUrl=https://github.com/vyente-ruffin/eon-dev-claude.git \
  -p voiceApiKey=<YOUR_AZURE_OPENAI_KEY>
```

## What Gets Created

| Resource | Purpose |
|----------|---------|
| Azure Container Registry | Stores Docker images |
| Log Analytics Workspace | Logging |
| Container App Environment | Hosts containers |
| eon-api-claude | External API (WebSocket endpoint) |
| eon-voice-claude | Internal voice service |
| Static Web App | Frontend hosting |
| User Assigned Identity | ACR pull permissions |

## Deploy Frontend

After Bicep deployment, deploy the frontend:

```bash
# Install SWA CLI
npm install -g @azure/static-web-apps-cli

# Get deployment token
TOKEN=$(az staticwebapp secrets list -n swa-eon-claude-dev -g rg-eon-claude --query properties.apiKey -o tsv)

# Deploy
cd frontend
swa deploy . --deployment-token $TOKEN
```

## Get Your Azure OpenAI Key

```bash
az cognitiveservices account keys list \
  --name <your-openai-resource> \
  --resource-group <your-rg> \
  --query key1 -o tsv
```

## After Deployment

Get the API URL:

```bash
az containerapp show -n eon-api-claude -g rg-eon-claude \
  --query "properties.configuration.ingress.fqdn" -o tsv
```

WebSocket endpoint: `wss://<fqdn>/ws/voice?user_id=<user>`
