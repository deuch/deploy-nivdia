// Storage account + SMB file share that holds NIM caches and model weights.
// Premium file storage gives the throughput needed to load multi-GB models.

param location string
param storageAccountName string
param shareName string
@allowed([ 'Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'PremiumV2_ZRS' ])
param skuName string = 'Premium_LRS'
@description('Share quota (GiB).')
param shareQuotaGiB int = 1024
@description('Folders created on the share (used as subPath by the apps). Parents must come before children.')
param folders array = [
  'graphic-elements-v1'
  'graphic-elements-v1/torch'
  'graphic-elements-v1/cache'
  'ocr-v1'
  'page-elements-v3'
  'page-elements-v3/cache'
  'page-elements-v3/weight'
  'table-structure-v1'
  'table-structure-v1/cache'
  'table-structure-v1/weight'
  'nano-12b-v2-vl'
  'nano-12b-v2-vl/cache'
]
param tags object = {}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'FileStorage'
  sku: { name: skuName }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    // Container Apps mounts Azure Files with the account key.
    allowSharedKeyAccess: true
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    enabledProtocols: 'SMB'
    shareQuota: shareQuotaGiB
  }
}

// ARM has no resource type for folders inside a file share, so they are created by a deployment script
// (az CLI in a short-lived container) that runs after the share and finishes before the environment and the apps.
resource createFolders 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'create-share-folders'
  location: location
  tags: tags
  kind: 'AzureCLI'
  properties: {
    azCliVersion: '2.67.0'
    retentionInterval: 'PT1H'
    cleanupPreference: 'OnSuccess'
    timeout: 'PT15M'
    environmentVariables: [
      { name: 'STORAGE_ACCOUNT', value: storage.name }
      { name: 'SHARE', value: share.name }
      { name: 'FOLDERS', value: join(folders, ' ') }
      { name: 'STORAGE_KEY', secureValue: storage.listKeys().keys[0].value }
    ]
    scriptContent: '''
      set -e
      for f in $FOLDERS; do
        az storage directory create --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" --share-name "$SHARE" --name "$f" --only-show-errors -o none
        echo "created $SHARE/$f"
      done
    '''
  }
}

output storageAccountName string = storage.name
output shareName string = share.name
output foldersCreated bool = !empty(createFolders.id)
