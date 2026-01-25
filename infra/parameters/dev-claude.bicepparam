using '../claude.bicep'

// Dev environment parameters for eon-claude
//
// DEPLOYMENT (one command):
//   az deployment sub create -l eastus2 -f infra/claude.bicep \
//     -p infra/parameters/dev-claude.bicepparam \
//     -p voiceApiKey=<KEY>

param resourceGroupName = 'rg-eon-dev-claude'
param location = 'eastus2'
param project = 'eon-claude'
param environment = 'dev'
param containerAppEnvName = 'eon-env-claude'
param logAnalyticsName = 'eon-logs-claude'
param imageTag = 'v1.0.0'
param azureOpenAiEndpoint = 'https://jarvis-voice-openai.openai.azure.com'
param azureOpenAiDeployment = 'gpt-realtime'
param voiceName = 'alloy'
param gitRepoUrl = 'https://github.com/vyente-ruffin/eon-dev-claude.git'
param gitBranch = 'main'
// param voiceApiKey = '' // REQUIRED - Pass via CLI: -p voiceApiKey=<key>
