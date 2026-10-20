// nemotron-page-elements-v3 : page layout detection (~1 GiB GPU memory) -> T4 profile.
// Uses the custom image in containerdemosdec.azurecr.io (stock NIM does not list T4 as supported).
// Registry: treated as PUBLIC (anonymous pull) -> no registry credentials, no identity.
// NGC_API_KEY is only used at runtime by the image to download the model weights into /model.

param name string = 'nemotron-page-elements-v3'
param location string
param environmentId string
param workloadProfileName string
param storageName string
param image string
param tags object = {}

@secure()
param ngcApiKey string

resource app 'Microsoft.App/containerApps@2025-01-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    environmentId: environmentId
    workloadProfileName: workloadProfileName
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        external: true
        targetPort: 8000
        transport: 'Auto'
        allowInsecure: false
      }
      secrets: [
        { name: 'ngc-api-key', value: ngcApiKey }
      ]
    }
    template: {
      containers: [
        {
          name: name
          image: image
          resources: {
            cpu: json('8')
            memory: '56Gi'
          }
          env: [
            { name: 'NIM_ENGINE_MODEL_DOWNLOAD_PROVIDER', value: 'ngc' }
            { name: 'NGC_API_KEY', secretRef: 'ngc-api-key' }
            { name: 'NIM_ENGINE_MODEL_NAME', value: 'nvidia/nemotron-page-elements-v3' }
            { name: 'NIM_ENGINE_MODEL_PATH', value: '/model/page-elements' }
            { name: 'LOG_FORMAT', value: 'pretty' }
            { name: 'RUST_LOG', value: 'info' }
          ]
          volumeMounts: [
            { volumeName: 'dshm', mountPath: '/dev/shm' }
            { volumeName: 'storage', mountPath: '/opt/cache', subPath: 'page-elements-v3/cache' }
            { volumeName: 'storage', mountPath: '/model', subPath: 'page-elements-v3/weight' }
          ]
        }
      ]
      scale: {
        // Autoscaling disabled: exactly one always-on replica.
        minReplicas: 1
        maxReplicas: 1
      }
      volumes: [
        { name: 'dshm', storageType: 'EmptyDir' }
        {
          name: 'storage'
          storageType: 'AzureFile'
          storageName: storageName
          mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks'
        }
      ]
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
