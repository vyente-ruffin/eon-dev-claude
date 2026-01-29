// EON Infrastructure
// 
// This is the source of truth for EON environments.
// All infrastructure changes should be made here and deployed via CI/CD.
//
// Usage:
//   az deployment group create -g rg-eon-dev -f infra/main.bicep -p environment=dev

// ============================================================================
// Parameters
// ============================================================================

@description('Environment name (dev, staging, prod)')
param environment string = 'dev'

@description('Location for all resources')
param location string = resourceGroup().location

@description('ACR server for pulling images')
param acrServer string = 'eonacrpa75j7hhoqfms.azurecr.io'

@description('API container image tag')
param apiImageTag string = 'latest'

@description('Voice container image tag')
param voiceImageTag string = 'latest'

@description('Key Vault name for secrets')
param keyVaultName string = 'kv-infra-405'

@description('Key Vault resource group')
param keyVaultResourceGroup string = 'rg-infra'

// ============================================================================
// Variables
// ============================================================================

var suffix = environment
var envName = 'eon-env-${suffix}'
var identityName = 'id-eon-acr-${suffix}'
var keyVaultUri = 'https://${keyVaultName}.vault.azure.net'

var tags = {
  project: 'eon'
  environment: environment
  'managed-by': 'bicep'
}

// ============================================================================
// Existing Resources (referenced, not created)
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource containerAppEnv 'Microsoft.App/managedEnvironments@2024-03-01' existing = {
  name: envName
}

// ============================================================================
// Container Apps
// ============================================================================

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-api-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
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
          server: acrServer
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-api-${suffix}'
          image: '${acrServer}/eon-api-${suffix}:${apiImageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'VOICE_SERVICE_URL'
              value: 'ws://eon-voice-${suffix}/ws/voice'
            }
            {
              name: 'MEMORY_SERVER_URL'
              value: 'http://eon-memory-${suffix}'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

resource voiceApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-voice-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: acrServer
          identity: managedIdentity.id
        }
      ]
      secrets: [
        {
          name: 'voice-api-key'
          keyVaultUrl: '${keyVaultUri}/secrets/eon-voice-api-key-${suffix}'
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-voice-${suffix}'
          image: '${acrServer}/eon-voice-${suffix}:${voiceImageTag}'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'VOICE_ENDPOINT'
              value: 'https://eastus2.api.cognitive.microsoft.com'
            }
            {
              name: 'VOICE_MODEL'
              value: 'gpt-realtime'
            }
            {
              name: 'VOICE_NAME'
              value: 'alloy'
            }
            {
              name: 'VOICE_API_KEY'
              secretRef: 'voice-api-key'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

resource memoryApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'eon-memory-${suffix}'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'auto'
      }
      registries: [
        {
          server: 'eoninfraregistry.azurecr.io'
          identity: managedIdentity.id
        }
      ]
      secrets: [
        {
          name: 'memory-api-key'
          keyVaultUrl: '${keyVaultUri}/secrets/eon-memory-api-key-${suffix}'
          identity: managedIdentity.id
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'eon-memory-${suffix}'
          image: 'eoninfraregistry.azurecr.io/eon/${suffix}/memory:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
          env: [
            {
              name: 'REDIS_URL'
              value: 'redis://redis-${suffix}:6379'
            }
            {
              name: 'LONG_TERM_MEMORY'
              value: 'true'
            }
            {
              name: 'DISABLE_AUTH'
              value: 'true'
            }
            {
              name: 'LOG_LEVEL'
              value: 'INFO'
            }
            {
              name: 'AZURE_API_KEY'
              secretRef: 'memory-api-key'
            }
            {
              name: 'AZURE_API_BASE'
              value: 'https://eon-openai-dev-fsqnys5btbfcc.openai.azure.com/'
            }
            {
              name: 'AZURE_API_VERSION'
              value: '2024-02-01'
            }
            {
              name: 'OPENAI_API_KEY'
              secretRef: 'memory-api-key'
            }
            {
              name: 'ENABLE_DISCRETE_MEMORY_EXTRACTION'
              value: 'true'
            }
            {
              name: 'ENABLE_TOPIC_EXTRACTION'
              value: 'true'
            }
            {
              name: 'ENABLE_NER'
              value: 'true'
            }
            {
              name: 'WINDOW_SIZE'
              value: '50'
            }
            {
              name: 'GENERATION_MODEL'
              value: 'azure/gpt-4o-mini'
            }
            {
              name: 'EMBEDDING_MODEL'
              value: 'azure/text-embedding-3-small'
            }
            {
              name: 'EXTRACTION_DEBOUNCE_SECONDS'
              value: '1'
            }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 3
      }
    }
  }
}

resource redisApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: 'redis-${suffix}'
  location: location
  tags: tags
  properties: {
    managedEnvironmentId: containerAppEnv.id
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: false
        targetPort: 6379
        transport: 'tcp'
      }
    }
    template: {
      containers: [
        {
          name: 'redis'
          image: 'redis/redis-stack:latest'
          resources: {
            cpu: json('0.5')
            memory: '1Gi'
          }
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
// Outputs
// ============================================================================

output apiUrl string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
output memoryUrl string = 'https://${memoryApp.properties.configuration.ingress.fqdn}'
