// nemotron-nano-12b-v2-vl : 12B vision-language NIM (vLLM). Needs 80 GB GPU memory -> A100 profile.
// Registry: nvcr.io (user "$oauthtoken", password = NGC API key).
//
// Two containers share one A100 replica (24 vCPU / 220 GiB in total):
//   1. nemotron-nano-12b-v2-vl : the NIM server on :8000, 22 vCPU / 212 GiB. It MUST stay the first
//      container, only the first container of an app gets the GPU.
//   2. nginx                   : reverse proxy on :8080 -> 127.0.0.1:8000, 2 vCPU / 8 GiB.
// The ingress and the liveness/readiness probes target nginx (8080), which is up immediately, so the
// platform no longer probes the slow-starting NIM port during creation: everything is set at creation.
// The nginx configuration comes from conf/default.conf, stored as the app secret "nginx-conf" and mounted
// as /etc/nginx/conf.d/default.conf through a Secret volume.

param name string = 'nemotron-nano-12b-v2-vl'
param location string
param environmentId string
param workloadProfileName string
param storageName string
param image string = 'nvcr.io/nim/nvidia/nemotron-nano-12b-v2-vl:latest'
param nginxImage string = 'docker.io/nginx:stable-alpine'
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
        targetPort: 8080
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
        // The nginx config is not sensitive, it is only stored as an app secret because a Secret volume is the way to
        // mount it as a file. It will show in the deployment template/history like any other parameter.
        #disable-next-line use-secure-value-for-secure-inputs
        { name: 'nginx-conf', value: loadTextContent('../../conf/default.conf') }
      ]
    }
    template: {
      containers: [
        {
          name: name
          image: image
          resources: {
            cpu: json('22')
            memory: '212Gi'
          }
          env: [
            { name: 'NGC_API_KEY', secretRef: 'ngc-api-key' }
            { name: 'NCCL_P2P_DISABLE', value: '1' }
            { name: 'NCCL_IB_DISABLE', value: '1' }
            { name: 'VLLM_GPU_MEMORY_UTILIZATION', value: '0.80' }
            { name: 'NIM_ENGINE_STARTUP_TIMEOUT', value: '600' }
          ]
          // Large model: allow up to ~4 h of startup (240 x 60 s) before the platform restarts the replica.
          probes: [
            {
              type: 'Startup'
              tcpSocket: { port: 8000 }
              initialDelaySeconds: 60
              periodSeconds: 60
              timeoutSeconds: 3
              failureThreshold: 240
              successThreshold: 1
            }
            {
              type: 'Readiness'
              tcpSocket: { port: 8080 }
              initialDelaySeconds: 60
              periodSeconds: 60
              timeoutSeconds: 10
              failureThreshold: 48
              successThreshold: 1
            }
            {
              type: 'Liveness'
              tcpSocket: { port: 8080 }
              initialDelaySeconds: 60
              periodSeconds: 60
              timeoutSeconds: 10
              failureThreshold: 30
              successThreshold: 1
            }
          ]
          volumeMounts: [
            { volumeName: 'dshm', mountPath: '/dev/shm' }
            { volumeName: 'cache', mountPath: '/opt/nim/.cache', subPath: 'nano-12b-v2-vl/cache' }
          ]
        }
        {
          name: 'nginx'
          image: nginxImage
          resources: {
            cpu: json('2')
            memory: '8Gi'
          }
          volumeMounts: [
            { volumeName: 'nginx-conf', mountPath: '/etc/nginx/conf.d' }
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
          name: 'cache'
          storageType: 'AzureFile'
          storageName: storageName
          mountOptions: 'dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks'
        }
        {
          name: 'nginx-conf'
          storageType: 'Secret'
          secrets: [
            { secretRef: 'nginx-conf', path: 'default.conf' }
          ]
        }
      ]
    }
  }
}

output fqdn string = app.properties.configuration.ingress.fqdn
