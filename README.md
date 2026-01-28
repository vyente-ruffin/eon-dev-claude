# Eon Dev - Claude Environment

**Source repo:** https://github.com/vyente-ruffin/eon-dev-claude
**Azure resource group:** `rg-eon-dev-claude`

---

## What is Eon?

Eon is a **voice-first AI companion** inspired by the movie "Her" - a genuine presence who learns you over time, not just another assistant.

- **Learns you invisibly** through long-term memory that silently remembers facts, preferences, relationships, and patterns
- **Helps manage your life** naturally through voice conversations and calendar integration
- **A friend who happens to help**, not an assistant pretending to be friendly

The goal: you feel *known* when talking to Eon. Each conversation builds on the last.

### Current Capabilities

| Feature | Description |
|---------|-------------|
| **Voice Conversations** | Real-time speech-to-speech with ~200-500ms latency, natural turn-taking and interruption |
| **Long-Term Memory** | Silently remembers facts, preferences, relationships, and patterns across sessions |
| **Google Calendar** | View, create, update, delete events with natural language summaries ("Packed morning, free after 2") |
| **Swappable Voice** | Adapter pattern architecture ready for multiple voice providers |

### What Makes Eon Different

| Traditional Assistants | Eon |
|-----------------------|-----|
| Transactional (do task, forget) | Relational (remembers, learns patterns) |
| "How can I help you?" | "Hey, how'd that thing go?" |
| Announces memory ("I'll remember that") | Silent memory (just knows) |
| Data dumps ("You have 3 meetings at...") | Natural summaries ("Busy morning, free after 2") |

### Roadmap

| Feature | Description | Status |
|---------|-------------|--------|
| **Chat Interface** | Text-based conversation alongside voice | Planned |
| **Web Browser** | AI browses autonomously and reports back | Planned |
| **Settings Dashboard** | Configure integrations, preferences, and privacy | Planned |
| **More Integrations** | Email, tasks, notes, smart home via MCP | Future |
| **Gemini Live Voice** | Alternative voice provider (Google) | Future |
| **Hume AI Voice** | Emotionally intelligent voice provider | Future |

---

## Why Modular Containers?

The app is split into independent containers so any single component can be swapped, scaled, or redeployed without touching the rest. No monolithic rebuilds.

```
                        SWAP BOUNDARIES
                        ──────────────

  eon-web-claude          Can swap frontend framework, hosting,
  (Static Web App)        or auth provider without touching backend
         |
         | HTTPS
         v
  eon-api-claude          Can update routing, add new service
  (API Gateway)           integrations without rebuilding voice/memory
      |          |
      | WS       | HTTP
      v          v
  eon-voice      eon-memory         Each service owns ONE job.
  -claude        -claude            Swap voice provider (OpenAI -> 11Labs -> Gemini)
  (Voice)        (Memory)           or memory backend (Redis -> Mem0 -> custom)
                    |                without changing a single line in the other services.
                    v
                redis-claude
                (Storage)
```

### What This Enables

| Action | What Changes | What Stays |
|--------|-------------|------------|
| Swap voice provider (OpenAI -> 11Labs) | Rebuild `eon-voice-claude` only | API, memory, frontend untouched |
| Swap memory backend (Redis -> Mem0) | Rebuild `eon-memory-claude` only | API, voice, frontend untouched |
| Update frontend UI | Redeploy SWA only | All backend containers untouched |
| Add new tool (email, tasks) | Update `eon-api-claude` only | Voice, memory, frontend untouched |
| Scale voice for more users | Scale `eon-voice-claude` replicas | Everything else stays at current scale |

### Voice Adapter Pattern

The voice service uses an adapter pattern so swapping providers is a code change in one file, not an architecture change:

```
eon-voice-claude/
  src/adapters/
    base.py               <-- Abstract interface (send_audio, send_text, receive)
    openai_realtime.py     <-- Azure OpenAI Realtime (current)
    # elevenlabs.py        <-- Future: just implement base.py
    # gemini_live.py       <-- Future: just implement base.py
```

Set `VOICE_ADAPTER=openai_realtime` env var to pick which adapter runs. Adding a new provider means writing one file that implements the base class.

### Memory Architecture (Swappable)

Memory backend is behind a standard API interface. Swap by changing `MEMORY_SERVER_URL`:

```
POST /v1/long-term-memory/        (store memory)
POST /v1/long-term-memory/search  (search memories)
POST /v1/memory/prompt            (get user context)
```

Current: Redis Agent Memory Server with vector search.
Any backend implementing this API works as a drop-in replacement.

---

## Deploy / Restore

GitHub Secrets (`AZURE_CREDENTIALS`, `VOICE_ENDPOINT`, `VOICE_API_KEY`) are already configured.

```bash
git clone https://github.com/vyente-ruffin/eon-dev-claude.git
cd eon-dev-claude
gh workflow run deploy.yml -f environment=dev -f location=eastus2
gh run watch
```

**Environments:**
- `dev` -> deploys to `rg-eon-dev-claude`
- `prod` -> deploys to `rg-eon-prod-claude`

**Verify after deploy:**
```bash
URL=$(az staticwebapp list -g rg-eon-dev-claude --query "[0].defaultHostname" -o tsv)
echo "https://$URL"
curl https://$URL/api/health
```

---

## Azure Resources (rg-eon-dev-claude)

| Resource | Type | Ingress | FQDN |
|----------|------|---------|------|
| eon-web-claude | Static Web App | External | lively-cliff-043061b0f.6.azurestaticapps.net |
| eon-api-claude | Container App | External | eon-api-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io |
| eon-voice-claude | Container App | Internal | eon-voice-claude.internal.happyground-4989b4a6.eastus2.azurecontainerapps.io |
| eon-memory-claude | Container App | External | eon-memory-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io |
| redis-claude | Container App | Internal | redis-claude.internal.happyground-4989b4a6.eastus2.azurecontainerapps.io |
| eon-openai-claude | Azure OpenAI | - | eastus2.api.cognitive.microsoft.com |
| eonacrpa75j7hhoqfms | Container Registry | - | eonacrpa75j7hhoqfms.azurecr.io |
| eonstorageclaude | Storage Account | - | Redis persistence |
| eon-logs-claude | Log Analytics | - | - |

## Current Container Images

| Container App | Image |
|--------------|-------|
| eon-api-claude | eonacrpa75j7hhoqfms.azurecr.io/eon-api-claude:v6 |
| eon-voice-claude | eonacrpa75j7hhoqfms.azurecr.io/eon-voice-claude:v1.0.0 |
| eon-memory-claude | eonacrpa75j7hhoqfms.azurecr.io/agent-memory-server:latest |
| redis-claude | redis/redis-stack:latest |

---

## Environment Variables

### eon-api-claude (API Gateway)

| Variable | Value |
|----------|-------|
| `VOICE_SERVICE_URL` | `ws://eon-voice-claude/ws/voice` |
| `MEMORY_SERVER_URL` | `http://eon-memory-claude` |

### eon-voice-claude (Voice Service)

| Variable | Value |
|----------|-------|
| `VOICE_ENDPOINT` | `https://eastus2.api.cognitive.microsoft.com` |
| `VOICE_MODEL` | `gpt-realtime` |
| `VOICE_NAME` | `alloy` |
| `VOICE_API_KEY` | (secret) |

### eon-memory-claude (Memory Service)

| Variable | Value |
|----------|-------|
| `REDIS_URL` | `redis://redis-claude:6379` |
| `LONG_TERM_MEMORY` | `true` |
| `DISABLE_AUTH` | `true` |
| `LOG_LEVEL` | `INFO` |
| `AZURE_API_KEY` | (secret) |
| `AZURE_API_BASE` | `https://eastus2.api.cognitive.microsoft.com/` |
| `AZURE_API_VERSION` | `2024-02-01` |
| `OPENAI_API_KEY` | (secret) |
| `ENABLE_DISCRETE_MEMORY_EXTRACTION` | `true` |
| `ENABLE_TOPIC_EXTRACTION` | `true` |
| `ENABLE_NER` | `true` |
| `WINDOW_SIZE` | `50` |
| `GENERATION_MODEL` | `azure/gpt-4o-mini` |
| `EMBEDDING_MODEL` | `azure/text-embedding-3-small` |
| `EXTRACTION_DEBOUNCE_SECONDS` | `1` |

---

## Manual Deployment

```bash
# Login to ACR
az acr login -n eonacrpa75j7hhoqfms

# Deploy eon-api-claude
docker buildx build --platform linux/amd64 -t eonacrpa75j7hhoqfms.azurecr.io/eon-api-claude:<tag> --push .
az containerapp update -n eon-api-claude -g rg-eon-dev-claude --image eonacrpa75j7hhoqfms.azurecr.io/eon-api-claude:<tag>

# Deploy eon-voice-claude
docker buildx build --platform linux/amd64 -t eonacrpa75j7hhoqfms.azurecr.io/eon-voice-claude:<tag> --push -f services/eon-voice/Dockerfile services/eon-voice
az containerapp update -n eon-voice-claude -g rg-eon-dev-claude --image eonacrpa75j7hhoqfms.azurecr.io/eon-voice-claude:<tag>
```

---

## Capture & Restore

### Capture Current State

After making changes to Azure that you want to keep:

```bash
./scripts/capture-state.sh v1.0.2 "capture: description of changes"
```

This captures: container image tags, scaling settings, voice config, OpenAI capacities. Then commits to git and pushes.

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

| Item | Captured? |
|------|-----------|
| Container image tags | Yes |
| Scaling (min/max replicas) | Yes |
| Voice config (endpoint, model, name) | Yes |
| OpenAI capacities | Yes |
| Infrastructure (all resources) | Yes |
| Container images | No (already in ACR) |
| Secrets (API keys) | No (in GitHub Secrets) |
| Redis data | No (persists in Azure) |

---

## Health Checks

```bash
# Via Static Web App
curl https://lively-cliff-043061b0f.6.azurestaticapps.net/api/health

# Direct to API container
curl https://eon-api-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io/health

# Memory service
curl https://eon-memory-claude.happyground-4989b4a6.eastus2.azurecontainerapps.io/health
```

---

## Troubleshooting

### Container Logs

```bash
az containerapp logs show -n eon-api-claude -g rg-eon-dev-claude --follow
az containerapp logs show -n eon-voice-claude -g rg-eon-dev-claude --follow
az containerapp logs show -n eon-memory-claude -g rg-eon-dev-claude --follow
```

### "Offline" status in browser

- Check auth is disabled: `az containerapp show -n eon-api-claude -g rg-eon-dev-claude --query "properties.configuration.ingress.authEnabled"`
- If true: `az containerapp auth update -n eon-api-claude -g rg-eon-dev-claude --enabled false`

### WebSocket connection fails

- Ensure auth is disabled on eon-api-claude
- Check that eon-api-claude has at least 1 replica running

### 404 on /api/health

- SWA linked backend proxies `/api/*` to the Container App
- Direct to Container App: use `/health` (no `/api` prefix)

### Memory not saving

- Check eon-memory-claude logs
- Verify Redis is running: `az containerapp logs show -n redis-claude -g rg-eon-dev-claude --tail 20`

---

## Cleanup

```bash
az group delete -n rg-eon-dev-claude --yes
```
