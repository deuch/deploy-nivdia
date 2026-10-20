// OPTIONAL: private endpoint for the Container Apps environment (all apps become private).
// Use together with publicNetworkAccess = 'Disabled' on the environment.

param location string
param environmentId string
param environmentName string
@description('Default domain of the environment, e.g. <unique-id>.<region>.azurecontainerapps.io')
param environmentDefaultDomain string
param vnetName string
param vnetAddressPrefix string = '10.50.0.0/16'
param peSubnetName string = 'private-endpoints'
param peSubnetPrefix string = '10.50.1.0/24'
param tags object = {}

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ vnetAddressPrefix ] }
    subnets: [
      {
        name: peSubnetName
        properties: { addressPrefix: peSubnetPrefix }
      }
    ]
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${environmentName}'
  location: location
  tags: tags
  properties: {
    subnet: { id: '${vnet.id}/subnets/${peSubnetName}' }
    privateLinkServiceConnections: [
      {
        name: 'aca-env'
        properties: {
          privateLinkServiceId: environmentId
          groupIds: [ 'managedEnvironments' ]
        }
      }
    ]
  }
}

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.${location}.azurecontainerapps.io'
  location: 'global'
  tags: tags
}

resource zoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: zone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnet.id }
  }
}

var uniqueId = split(environmentDefaultDomain, '.')[0]
var peIp = pe.properties.customDnsConfigs[0].ipAddresses[0]

resource envRecord 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: uniqueId
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: peIp } ]
  }
}

resource appRecords 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: zone
  name: '*.${uniqueId}'
  properties: {
    ttl: 300
    aRecords: [ { ipv4Address: peIp } ]
  }
}

output privateEndpointId string = pe.id
output vnetId string = vnet.id
