using '../claude.bicep'

// Dev environment parameters for eon-claude
//
// DEPLOYMENT (one command):
//   az deployment sub create -l eastus2 -f infra/claude.bicep -p infra/parameters/dev-claude.bicepparam -p voiceApiKey=<KEY>
//
// WITH IMAGE BUILD (from git repo):
//   az deployment sub create -l eastus2 -f infra/claude.bicep -p infra/parameters/dev-claude.bicepparam \
//     -p voiceApiKey=<KEY> -p skipImageBuild=false -p gitRepoUrl=https://github.com/405network/eon-dev-claude.git
//
// EXISTING IMAGES (default - skipImageBuild=true):
//   Images must already exist in ACR before deployment

param resourceGroupName = 'rg-eon-dev-claude'
param location = 'eastus2'
param project = 'eon-claude'
param environment = 'dev'
// param acrName = 'eonacr...'  // Leave blank for auto-generated unique name
param containerAppEnvName = 'eon-env-claude'
param logAnalyticsName = 'eon-logs-claude'
param imageTag = 'v1.0.0'
param azureOpenAiEndpoint = 'https://jarvis-voice-openai.openai.azure.com'
param azureOpenAiDeployment = 'gpt-realtime'
param voiceName = 'alloy'
// param voiceApiKey = '' // REQUIRED - Pass via CLI: -p voiceApiKey=<key>
param skipImageBuild = true  // Set to false and provide gitRepoUrl to build images
// param gitRepoUrl = ''  // Git repo URL for ACR build (e.g., https://github.com/405network/eon-dev-claude.git)
param gitBranch = 'main'
