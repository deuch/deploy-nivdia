// nemotron-graphic-elements-v1 : chart/graphic detection NIM from nvcr.io -> T4 profile (8 vCPU / 56 GiB per replica).
// The stock NIM matrix lists A100-class GPUs; if it fails to start on T4, set workloadProfileName to the A100 profile in main.bicep.
// Registry: nvcr.io (user "$oauthtoken", password = NGC API key).

param name string = 'nemotron-graphic-elements-v1'
param location string
param environmentId string
param workloadProfileName string
param storageName string
param image string = 'nvcr.io/nim/nvidia/nemotron-graphic-elements-v1:latest'
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
      registries: [
        {
          server: 'nvcr.io'
          username: '$oauthtoken'
          passwordSecretRef: 'ngc-api-key'
        }
      ]
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
            { name: 'NGC_API_KEY', secretRef: 'ngc-api-key' }
            // Must point inside the mounted torch cache path below to persist compiled kernels.
            { name: 'TORCHINDUCTOR_CACHE_DIR', value: '/tmp/inductor' }
          ]
          volumeMounts: [
            { volumeName: 'dshm', mountPath: '/dev/shm' }
            { volumeName: 'storage', mountPath: '/tmp/inductor', subPath: 'graphic-elements-v1/torch' }
            { volumeName: 'storage', mountPath: '/opt/nim/.cache', subPath: 'graphic-elements-v1/cache' }
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
