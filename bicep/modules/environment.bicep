// Environment-level Log Analytics, Container Apps environment (workload profiles) with
// A100 + T4 serverless GPU profiles, and the Azure Files storage link shared by all apps.

param location string
param environmentName string
param logAnalyticsName string
param storageAccountName string
param shareName string
@description('Name of the environment storage link that apps reference in their volumes.')
param envStorageName string = 'shared-volume'
param a100ProfileName string = 'A100-Profile'
param t4ProfileName string = 'T4-Profile'
@allowed([ 'Enabled', 'Disabled' ])
@description('Set to Disabled when you front the environment with a private endpoint.')
param publicNetworkAccess string = 'Enabled'
param tags object = {}

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource env 'Microsoft.App/managedEnvironments@2025-02-02-preview' = {
  name: environmentName
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
    zoneRedundant: false
    publicNetworkAccess: publicNetworkAccess
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
      {
        name: a100ProfileName
        workloadProfileType: 'Consumption-GPU-NC24-A100' // 24 vCPU / 220 GiB / 1x A100 80 GB per replica
      }
      {
        name: t4ProfileName
        workloadProfileType: 'Consumption-GPU-NC8as-T4' // 8 vCPU / 56 GiB / 1x T4 16 GB per replica
      }
    ]
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2025-02-02-preview' = {
  parent: env
  name: envStorageName
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: shareName
      accessMode: 'ReadWrite'
    }
  }
}

output environmentId string = env.id
output environmentName string = env.name
output defaultDomain string = env.properties.defaultDomain
output envStorageName string = envStorage.name
output a100ProfileName string = a100ProfileName
output t4ProfileName string = t4ProfileName
