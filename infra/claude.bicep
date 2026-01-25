// Eon Claude Infrastructure - Fully Self-Contained
//
// Deploys EVERYTHING in one command:
// - Resource Group
// - Azure Container Registry
// - Log Analytics Workspace
// - Container App Environment
// - eon-api-claude (external)
// - eon-voice-claude (internal)
// - Role assignments for ACR pull
// - Builds Docker images via ACR Tasks
//
// Usage (ONE COMMAND):
//   az deployment sub create -l eastus2 -f claude.bicep -p parameters/dev-claude.bicepparam
//
// Or with inline params:
//   az deployment sub create -l eastus2 -f claude.bicep \
//     -p resourceGroupName=rg-eon-dev-claude \
//     -p location=eastus2 \
//     -p voiceApiKey=<YOUR_KEY> \
//     -p gitRepoUrl=https://github.com/405network/eon-dev-claude.git

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

@description('Azure OpenAI endpoint')
param azureOpenAiEndpoint string = 'https://jarvis-voice-openai.openai.azure.com'

@description('Azure OpenAI deployment name')
param azureOpenAiDeployment string = 'gpt-realtime'

@description('Voice name for TTS')
param voiceName string = 'alloy'

@secure()
@description('Azure OpenAI API key')
param voiceApiKey string = ''

@description('Git repository URL for source code (for ACR build)')
param gitRepoUrl string = ''

@description('Git branch to build from')
param gitBranch string = 'main'

@description('Skip image build (use existing images)')
param skipImageBuild bool = true

// ============================================================================
// Variables
// ============================================================================

var tags = {
  project: project
  Creator: 'claude'
  CreatedOn: '2026-01-24'
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
    azureOpenAiEndpoint: azureOpenAiEndpoint
    azureOpenAiDeployment: azureOpenAiDeployment
    voiceName: voiceName
    voiceApiKey: voiceApiKey
    gitRepoUrl: gitRepoUrl
    gitBranch: gitBranch
    skipImageBuild: skipImageBuild
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
