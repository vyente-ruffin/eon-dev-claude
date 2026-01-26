// Eon Claude Resources Module - Full Stack
//
// This module deploys the complete Eon Claude stack:
// - Azure OpenAI (embeddings + chat)
// - Redis with persistent storage
// - Memory service (agent-memory-server)
// - Voice service
// - API backend
// - Static Web App frontend

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

// Voice service config (uses external Azure OpenAI for realtime)
param voiceEndpoint string
param voiceModel string = 'gpt-realtime'
param voiceName string = 'alloy'

@secure()
param voiceApiKey string

// Memory service config
@secure()
param memoryApiKey string

param gitRepoUrl string
param gitBranch string
param tags object

// ============================================================================
// Storage Account (for Redis persistence)
// ============================================================================

var storageAccountName = 'eonstorage${uniqueString(resourceGroup().id)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
  }
}

resource fileServices 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource redisFileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileServices
  name: 'redis-data'
  properties: {
    shareQuota: 5
  }
}

// ============================================================================
// Azure OpenAI (for memory service embeddings and chat)
// ============================================================================

resource openAi 'Microsoft.CognitiveServices/accounts@2024-04-01-preview' = {
  name: 'eon-openai-${environment}'
  location: location
  tags: tags
  kind: 'OpenAI'
  sku: {
    name: 'S0'
  }
  properties: {
    customSubDomainName: 'eon-openai-${environment}-${uniqueString(resourceGroup().id)}'
    publicNetworkAccess: 'Enabled'
  }
}

resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-04-01-preview' = {
  parent: openAi
  name: 'text-embedding-3-small'
  sku: {
    name: 'Standard'
    capacity: 120
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'text-embedding-3-small'
      version: '1'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
}

resource chatDeployment 'Microsoft.CognitiveServices/accounts/deployments@2024-04-01-preview' = {
  parent: openAi
  name: 'gpt-4o-mini'
  sku: {
    name: 'Standard'
    capacity: 120
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-4o-mini'
      version: '2024-07-18'
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
  }
  dependsOn: [
    embeddingDeployment
  ]
}

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

// Storage mount for Redis persistence
resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: containerAppEnv
  name: 'redis-storage'
  properties: {
    azureFile: {
      accountName: storageAccount.name
      accountKey: storageAccount.listKeys().keys[0].value
      shareName: redisFileShare.name
      accessMode: 'ReadWrite'
    }
  }
}

// ============================================================================
// User Assigned Managed Identity (for ACR pull)
// ============================================================================

resource acrPullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-eon-acr-${environment}'
  location: location
  tags: tags
}

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

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
      { name: 'ACR_NAME', value: acr.name }
      { name: 'IMAGE_TAG', value: imageTag }
      { name: 'GIT_REPO_URL', value: gitRepoUrl }
      { name: 'GIT_BRANCH', value: gitBranch }
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
      { name: 'ACR_NAME', value: acr.name }
      { name: 'IMAGE_TAG', value: imageTag }
      { name: 'GIT_REPO_URL', value: gitRepoUrl }
      { name: 'GIT_BRANCH', value: gitBranch }
    ]
  }
  dependsOn: [
    deployIdentityRoleAssignment
  ]
}

resource buildMemoryImage 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'build-eon-memory-claude'
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
        --image agent-memory-server:$IMAGE_TAG \
        --file Dockerfile \
        $GIT_REPO_URL#$GIT_BRANCH:services/eon-memory-claude
    '''
    environmentVariables: [
      { name: 'ACR_NAME', value: acr.name }
      { name: 'IMAGE_TAG', value: imageTag }
      { name: 'GIT_REPO_URL', value: gitRepoUrl }
      { name: 'GIT_BRANCH', value: gitBranch }
    ]
  }
  dependsOn: [
    deployIdentityRoleAssignment
  ]
}

// ============================================================================
// redis-claude (Internal - Redis with persistence)
// ============================================================================

resource redisClaude 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'redis-claude'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppEnv.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 6379
        transport: 'tcp'
        exposedPort: 6379
      }
    }
    template: {
      containers: [
        {
          name: 'redis-claude'
          image: 'redis/redis-stack:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          volumeMounts: [
            {
              volumeName: 'redis-data'
              mountPath: '/data'
            }
          ]
        }
      ]
      volumes: [
        {
          name: 'redis-data'
          storageName: envStorage.name
          storageType: 'AzureFile'
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// ============================================================================
// eon-memory-claude (External - Memory Service)
// ============================================================================

resource eonMemoryClaude 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-memory-claude'
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
          name: 'memory-api-key'
          value: empty(memoryApiKey) ? openAi.listKeys().key1 : memoryApiKey
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-memory-claude'
          image: '${acr.properties.loginServer}/agent-memory-server:${imageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            { name: 'REDIS_URL', value: 'redis://redis-claude:6379' }
            { name: 'LONG_TERM_MEMORY', value: 'true' }
            { name: 'DISABLE_AUTH', value: 'true' }
            { name: 'LOG_LEVEL', value: 'INFO' }
            { name: 'AZURE_API_KEY', secretRef: 'memory-api-key' }
            { name: 'AZURE_API_BASE', value: openAi.properties.endpoint }
            { name: 'AZURE_API_VERSION', value: '2024-02-01' }
            { name: 'OPENAI_API_KEY', secretRef: 'memory-api-key' }
            { name: 'ENABLE_DISCRETE_MEMORY_EXTRACTION', value: 'true' }
            { name: 'ENABLE_TOPIC_EXTRACTION', value: 'true' }
            { name: 'ENABLE_NER', value: 'true' }
            { name: 'WINDOW_SIZE', value: '50' }
            { name: 'GENERATION_MODEL', value: 'azure/gpt-4o-mini' }
            { name: 'EMBEDDING_MODEL', value: 'azure/text-embedding-3-small' }
            { name: 'EXTRACTION_DEBOUNCE_SECONDS', value: '1' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    buildMemoryImage
    redisClaude
    chatDeployment
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
            { name: 'VOICE_ENDPOINT', value: voiceEndpoint }
            { name: 'VOICE_MODEL', value: voiceModel }
            { name: 'VOICE_NAME', value: voiceName }
            { name: 'VOICE_API_KEY', secretRef: 'voice-api-key' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
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
            { name: 'VOICE_SERVICE_URL', value: 'ws://eon-voice-claude/ws/voice' }
            { name: 'MEMORY_SERVER_URL', value: 'http://eon-memory-claude' }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
  dependsOn: [
    acrPullRoleAssignment
    buildApiImage
    eonVoiceClaude
    eonMemoryClaude
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
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
    buildProperties: {
      skipGithubActionWorkflowGeneration: true
    }
  }
}

resource linkedBackend 'Microsoft.Web/staticSites/linkedBackends@2023-12-01' = {
  parent: staticWebApp
  name: 'backend'
  properties: {
    backendResourceId: eonApiClaude.id
    region: location
  }
}

// ============================================================================
// Outputs
// ============================================================================

output staticWebAppUrl string = 'https://${staticWebApp.properties.defaultHostname}'
output staticWebAppName string = staticWebApp.name
output deployFrontendCommand string = 'swa deploy frontend --deployment-token $(az staticwebapp secrets list -n ${staticWebApp.name} -g ${resourceGroup().name} --query properties.apiKey -o tsv) --env production'
output acrLoginServer string = acr.properties.loginServer
output acrName string = acr.name
output containerAppEnvId string = containerAppEnv.id
output containerAppEnvDefaultDomain string = containerAppEnv.properties.defaultDomain
output eonApiClaudeFqdn string = eonApiClaude.properties.configuration.ingress.fqdn
output eonVoiceClaudeFqdn string = eonVoiceClaude.properties.configuration.ingress.fqdn
output eonMemoryClaudeFqdn string = eonMemoryClaude.properties.configuration.ingress.fqdn
output openAiEndpoint string = openAi.properties.endpoint
output storageAccountName string = storageAccount.name
