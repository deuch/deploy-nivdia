targetScope = 'resourceGroup'

@description('Azure region (e.g. one where serverless A100/T4 GPUs are available). The resource group and subscription are the deployment target (az deployment group create -g ... --subscription ...).')
param location string

param environmentName string = 'nim-gpu-env'
param logAnalyticsName string = 'nim-gpu-logs'
@minLength(3)
@maxLength(24)
@description('Globally unique storage account name (3-24 lowercase letters/digits). Must not be an existing account.')
param storageAccountName string
param shareName string = 'containers'
param storageSkuName string = 'Premium_LRS'
@description('Full image reference of the custom object-detection image. The registry is treated as public: anonymous pull, no credentials.')
param customImage string = 'containerdemosdec.azurecr.io/nvidia/nemotron-object-detection:custom'

@secure()
@description('NGC API key (https://org.ngc.nvidia.com/setup/api-keys). Used for nvcr.io pulls and NIM model downloads.')
param ngcApiKey string

@allowed([ 'Enabled', 'Disabled' ])
param publicNetworkAccess string = 'Enabled'
@description('Create a VNet + private endpoint + private DNS zone for the environment. Requires publicNetworkAccess = Disabled.')
param enablePrivateEndpoint bool = false
param privateEndpointVnetName string = 'vnet-nim-private'
@description('Image of the nginx sidecar of nemotron-nano-12b-v2-vl (reverse proxy in front of the NIM).')
param nginxImage string = 'docker.io/nginx:stable-alpine'

param tags object = {
  workload: 'nvidia-nim'
}

var a100Profile = 'A100-Profile'
var t4Profile = 'T4-Profile'

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    storageAccountName: storageAccountName
    shareName: shareName
    skuName: storageSkuName
    tags: tags
  }
}

module environment 'modules/environment.bicep' = {
  name: 'environment'
  params: {
    location: location
    environmentName: environmentName
    logAnalyticsName: logAnalyticsName
    storageAccountName: storage.outputs.storageAccountName
    shareName: storage.outputs.shareName
    a100ProfileName: a100Profile
    t4ProfileName: t4Profile
    publicNetworkAccess: publicNetworkAccess
    tags: tags
  }
}

// ---- A100 workload: NIM from nvcr.io + nginx sidecar (config read from ../conf/default.conf) ----
module nano 'apps/nemotron-nano-12b-v2-vl.bicep' = {
  name: 'app-nano-12b-v2-vl'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    workloadProfileName: a100Profile
    storageName: environment.outputs.envStorageName
    nginxImage: nginxImage
    ngcApiKey: ngcApiKey
    tags: tags
  }
}

// ---- T4 workloads ----
module graphic 'apps/nemotron-graphic-elements-v1.bicep' = {
  name: 'app-graphic-elements-v1'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    workloadProfileName: t4Profile
    storageName: environment.outputs.envStorageName
    ngcApiKey: ngcApiKey
    tags: tags
  }
}

module ocr 'apps/nemotron-ocr-v1.bicep' = {
  name: 'app-ocr-v1'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    workloadProfileName: t4Profile
    storageName: environment.outputs.envStorageName
    ngcApiKey: ngcApiKey
    tags: tags
  }
}

module pageElements 'apps/nemotron-page-elements-v3.bicep' = {
  name: 'app-page-elements-v3'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    workloadProfileName: t4Profile
    storageName: environment.outputs.envStorageName
    image: customImage
    ngcApiKey: ngcApiKey
    tags: tags
  }
}

module tableStructure 'apps/nemotron-table-structure-v1.bicep' = {
  name: 'app-table-structure-v1'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    workloadProfileName: t4Profile
    storageName: environment.outputs.envStorageName
    image: customImage
    ngcApiKey: ngcApiKey
    tags: tags
  }
}

module privateEndpoint 'modules/private-endpoint.bicep' = if (enablePrivateEndpoint) {
  name: 'private-endpoint'
  params: {
    location: location
    environmentId: environment.outputs.environmentId
    environmentName: environment.outputs.environmentName
    environmentDefaultDomain: environment.outputs.defaultDomain
    vnetName: privateEndpointVnetName
    tags: tags
  }
}

output environmentDefaultDomain string = environment.outputs.defaultDomain
output endpoints object = {
  nano12bV2Vl: nano.outputs.fqdn
  graphicElementsV1: graphic.outputs.fqdn
  ocrV1: ocr.outputs.fqdn
  pageElementsV3: pageElements.outputs.fqdn
  tableStructureV1: tableStructure.outputs.fqdn
}
