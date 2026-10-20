// nemotron-ocr-v1 : OCR NIM from nvcr.io, running on a T4 (8 vCPU / 56 GiB) in the live deployment.
// Registry: nvcr.io (user "$oauthtoken", password = NGC API key).
// If the NIM refuses to start on T4 for your image tag, switch workloadProfileName to the A100 profile.

param name string = 'nemotron-ocr-v1'
param location string
param environmentId string
param workloadProfileName string
param storageName string
param image string = 'nvcr.io/nim/nvidia/nemotron-ocr-v1:latest'
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
          ]
          volumeMounts: [
            { volumeName: 'dshm', mountPath: '/dev/shm' }
            { volumeName: 'nim-cache', mountPath: '/opt/nim/.cache', subPath: 'ocr-v1' }
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
          name: 'nim-cache'
          storageType: 'AzureFile'
          storageName: storageName
          mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks'
        }
      ]
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
