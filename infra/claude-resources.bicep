// Eon Claude Resources Module
//
// This module is called by claude.bicep and deploys all resources
// to the specified resource group.

targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

param location string
param environment string
param acrName string
param containerAppEnvName string
param logAnalyticsName string
param imageTag string
param azureOpenAiEndpoint string
param azureOpenAiDeployment string
param voiceName string

@secure()
param voiceApiKey string

param gitRepoUrl string
param gitBranch string
param tags object

// ============================================================================
// Azure Container Registry
// ============================================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// ============================================================================
// Log Analytics Workspace
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================================
// Container App Environment
// ============================================================================

resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppEnvName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

// ============================================================================
// User Assigned Managed Identity (for ACR pull - created before Container Apps)
// ============================================================================

resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-eon-acr-${environment}'
  location: location
  tags: tags
}

// AcrPull role definition ID
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

// Assign AcrPull role BEFORE Container Apps deploy
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, acrPullIdentity.id, acrPullRoleId)
  scope: acr
  properties: {
    principalId: acrPullIdentity.properties.principalId
    roleDefinitionId: acrPullRoleId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// User Assigned Managed Identity (for deployment scripts)
// ============================================================================

resource deploymentIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-eon-deploy-${environment}'
  location: location
  tags: tags
}

// Contributor role for deployment script to run ACR build
var contributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')

resource deployIdentityRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'id-eon-deploy-${environment}', contributorRoleId)
  properties: {
    principalId: deploymentIdentity.properties.principalId
    roleDefinitionId: contributorRoleId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// Deployment Scripts - Build Docker Images via ACR Tasks
// ============================================================================

resource buildVoiceImage 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'build-eon-voice-claude'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.52.0'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    scriptContent: '''
      az acr build \
        --registry $ACR_NAME \
        --image eon-voice-claude:$IMAGE_TAG \
        --file Dockerfile \
        $GIT_REPO_URL#$GIT_BRANCH:services/eon-voice-claude
    '''
    environmentVariables: [
      {
        name: 'ACR_NAME'
        value: acr.name
      }
      {
        name: 'IMAGE_TAG'
        value: imageTag
      }
      {
        name: 'GIT_REPO_URL'
        value: gitRepoUrl
      }
      {
        name: 'GIT_BRANCH'
        value: gitBranch
      }
    ]
  }
  dependsOn: [
    deployIdentityRoleAssignment
  ]
}

resource buildApiImage 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'build-eon-api-claude'
  location: location
  tags: tags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deploymentIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.52.0'
    timeout: 'PT30M'
    retentionInterval: 'P1D'
    cleanupPreference: 'OnSuccess'
    scriptContent: '''
      az acr build \
        --registry $ACR_NAME \
        --image eon-api-claude:$IMAGE_TAG \
        --file Dockerfile \
        $GIT_REPO_URL#$GIT_BRANCH:backend
    '''
    environmentVariables: [
      {
        name: 'ACR_NAME'
        value: acr.name
      }
      {
        name: 'IMAGE_TAG'
        value: imageTag
      }
      {
        name: 'GIT_REPO_URL'
        value: gitRepoUrl
      }
      {
        name: 'GIT_BRANCH'
        value: gitBranch
      }
    ]
  }
  dependsOn: [
    deployIdentityRoleAssignment
  ]
}

// ============================================================================
// eon-voice-claude (Internal - Voice Service)
// ============================================================================

resource eonVoiceClaude 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-voice-claude'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: acrPullIdentity.id
        }
      ]
      secrets: [
        {
          name: 'voice-api-key'
          value: empty(voiceApiKey) ? 'PLACEHOLDER_SET_AFTER_DEPLOY' : voiceApiKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-voice-claude'
          image: '${acr.properties.loginServer}/eon-voice-claude:${imageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'VOICE_ENDPOINT'
              value: azureOpenAiEndpoint
            }
            {
              name: 'VOICE_MODEL'
              value: azureOpenAiDeployment
            }
            {
              name: 'VOICE_NAME'
              value: voiceName
            }
            {
              name: 'VOICE_API_KEY'
              secretRef: 'voice-api-key'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 3
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    buildVoiceImage
  ]
}

// ============================================================================
// eon-api-claude (External - Backend API)
// ============================================================================

resource eonApiClaude 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-api-claude'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${acrPullIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
        allowInsecure: false
      }
      registries: [
        {
          server: acr.properties.loginServer
          identity: acrPullIdentity.id
        }
      ]
      secrets: [
        {
          name: 'voice-api-key'
          value: empty(voiceApiKey) ? 'PLACEHOLDER_SET_AFTER_DEPLOY' : voiceApiKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-api-claude'
          image: '${acr.properties.loginServer}/eon-api-claude:${imageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'VOICE_SERVICE_URL'
              value: 'wss://${eonVoiceClaude.properties.configuration.ingress.fqdn}/ws/voice'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 0
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    buildApiImage
  ]
}

// ============================================================================
// Static Web App (Frontend)
// ============================================================================

resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: 'swa-eon-claude-${environment}'
  location: location
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
}

// ============================================================================
// Outputs
// ============================================================================

output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output staticWebAppName string = staticWebApp.name
output deployFrontendCommand string = 'cd frontend && npm i -g @azure/static-web-apps-cli && swa deploy . --deployment-token $(az staticwebapp secrets list -n ${staticWebApp.name} -g ${resourceGroup().name} --query properties.apiKey -o tsv)'
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output containerAppEnvId string = containerAppEnv.id
output containerAppEnvDefaultDomain string = containerAppEnv.properties.defaultDomain
output eonApiClaudeFqdn string = eonApiClaude.properties.configuration.ingress.fqdn
output eonVoiceClaudeFqdn string = eonVoiceClaude.properties.configuration.ingress.fqdn
