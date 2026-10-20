using 'main.bicep'

// Deployment-specific values come from the environment so nothing is hardcoded or committed:
//   $env:NGC_API_KEY          = '<your NGC API key>'
//   $env:LOCATION             = '<azure region>'
//   $env:STORAGE_ACCOUNT_NAME = '<globally unique name, 3-24 lowercase letters/digits>'
// The resource group and subscription are chosen on the command line (-g / --subscription).
param ngcApiKey = readEnvironmentVariable('NGC_API_KEY')
param location = readEnvironmentVariable('LOCATION')
param storageAccountName = readEnvironmentVariable('STORAGE_ACCOUNT_NAME')

param environmentName = 'nim-gpu-env'
param logAnalyticsName = 'nim-gpu-logs'
param shareName = 'containers'
param customImage = 'containerdemosdec.azurecr.io/nvidia/nemotron-object-detection:custom'

// Private mode: set publicNetworkAccess = 'Disabled' and enablePrivateEndpoint = true
param publicNetworkAccess = 'Enabled'
param enablePrivateEndpoint = false
