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
//     -p resourceGroupName=rg-eon-dev-claude \
//     -p location=eastus2 \
//     -p voiceApiKey=<YOUR_VOICE_API_KEY>

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
param acrName string = 'eonacrpa75j7hhoqfms'

@description('Container App Environment name')
param containerAppEnvName string = 'eon-env-claude'

@description('Log Analytics Workspace name')
param logAnalyticsName string = 'eon-logs-claude'

@description('API image tag to deploy')
param apiImageTag string = 'v6'

@description('Voice image tag to deploy')
param voiceImageTag string = 'v1.0.0'

@description('Azure OpenAI endpoint for voice (realtime API)')
param voiceEndpoint string = 'https://eastus2.api.cognitive.microsoft.com'

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
    apiImageTag: apiImageTag
    voiceImageTag: voiceImageTag
    voiceEndpoint: voiceEndpoint
    voiceModel: voiceModel
    voiceName: voiceName
    voiceApiKey: voiceApiKey
    memoryApiKey: memoryApiKey
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
