// Eon Claude Infrastructure - Full Stack
//
// Deploys EVERYTHING in one command:
// - Resource Group
// - Azure OpenAI (embeddings + chat for memory)
// - Azure Container Registry
// - Storage Account (for Redis persistence)
// - Log Analytics Workspace
// - Container App Environment
// - redis-claude (internal, persistent)
// - eon-memory-claude (external, agent-memory-server)
// - eon-voice-claude (internal)
// - eon-api-claude (external)
// - Static Web App (frontend - requires manual deploy after)
//
// Usage (ONE COMMAND):
//   az deployment sub create -l eastus2 -f claude.bicep -p parameters/dev-claude.bicepparam
//
// Or with inline params:
//   az deployment sub create -l eastus2 -n eon-deploy -f infra/claude.bicep \
//     -p resourceGroupName=rg-eon-claude \
//     -p location=eastus2 \
//     -p voiceApiKey=<YOUR_VOICE_API_KEY> \
//     -p voiceEndpoint=https://your-openai.openai.azure.com \
//     -p gitRepoUrl=https://github.com/your-org/eon-dev-claude.git

targetScope = 'subscription'

// ============================================================================
// Parameters
// ============================================================================

@description('Resource group name')
param resourceGroupName string = 'rg-eon-dev-claude'

@description('Location for all resources')
param location string = 'eastus2'

@description('Project name used for tagging and naming')
param project string = 'eon-claude'

@description('Environment name (dev, prod)')
param environment string = 'dev'

@description('Azure Container Registry name (must be globally unique)')
param acrName string = 'eonacr${uniqueString(subscription().subscriptionId, resourceGroupName)}'

@description('Container App Environment name')
param containerAppEnvName string = 'eon-env-claude'

@description('Log Analytics Workspace name')
param logAnalyticsName string = 'eon-logs-claude'

@description('Image tag to deploy')
param imageTag string = 'v1.0.0'

@description('Azure OpenAI endpoint for voice (realtime API)')
param voiceEndpoint string = 'https://jarvis-voice-openai.openai.azure.com'

@description('Azure OpenAI deployment name for voice')
param voiceModel string = 'gpt-realtime'

@description('Voice name for TTS')
param voiceName string = 'alloy'

@secure()
@description('Azure OpenAI API key for voice service')
param voiceApiKey string = ''

@secure()
@description('Azure OpenAI API key for memory service (optional - uses auto-provisioned if not set)')
param memoryApiKey string = ''

@description('Git repository URL for source code (required)')
param gitRepoUrl string

@description('Git branch to build from')
param gitBranch string = 'main'

// ============================================================================
// Variables
// ============================================================================

var tags = {
  project: project
  Creator: 'claude'
  CreatedOn: '2026-01-25'
  environment: environment
}

// ============================================================================
// Resource Group
// ============================================================================

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// ============================================================================
// Deploy all resources to the resource group via module
// ============================================================================

module resources 'claude-resources.bicep' = {
  name: 'eon-claude-resources'
  scope: rg
  params: {
    location: location
    environment: environment
    acrName: acrName
    containerAppEnvName: containerAppEnvName
    logAnalyticsName: logAnalyticsName
    imageTag: imageTag
    voiceEndpoint: voiceEndpoint
    voiceModel: voiceModel
    voiceName: voiceName
    voiceApiKey: voiceApiKey
    memoryApiKey: memoryApiKey
    gitRepoUrl: gitRepoUrl
    gitBranch: gitBranch
    tags: tags
  }
}

// ============================================================================
// Outputs
// ============================================================================

output resourceGroupName string = rg.name
output acrLoginServer string = resources.outputs.acrLoginServer
output acrName string = resources.outputs.acrName
output containerAppEnvId string = resources.outputs.containerAppEnvId
output containerAppEnvDefaultDomain string = resources.outputs.containerAppEnvDefaultDomain
output eonApiClaudeFqdn string = resources.outputs.eonApiClaudeFqdn
output eonVoiceClaudeFqdn string = resources.outputs.eonVoiceClaudeFqdn
output eonMemoryClaudeFqdn string = resources.outputs.eonMemoryClaudeFqdn
output staticWebAppUrl string = resources.outputs.staticWebAppUrl
output staticWebAppName string = resources.outputs.staticWebAppName
output deployFrontendCommand string = resources.outputs.deployFrontendCommand
output openAiEndpoint string = resources.outputs.openAiEndpoint
output storageAccountName string = resources.outputs.storageAccountName
