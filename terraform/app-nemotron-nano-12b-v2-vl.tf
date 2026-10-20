# nemotron-nano-12b-v2-vl : 12B VLM (vLLM) -> A100 profile.
# Registry: nvcr.io (user "$oauthtoken", password = NGC API key).
#
# Two containers share one A100 replica (24 vCPU / 220 GiB in total):
#   1. nemotron-nano-12b-v2-vl : the NIM server on :8000, 22 vCPU / 212 GiB. It MUST stay the first
#      container, only the first container of an app gets the GPU.
#   2. nginx                   : reverse proxy on :8080 -> 127.0.0.1:8000, 2 vCPU / 8 GiB.
# The ingress and the liveness/readiness probes target nginx (8080), which is up immediately, so the
# platform no longer probes the slow-starting NIM port during creation: everything is set at creation.
# The nginx configuration comes from conf/default.conf, stored as the app secret "nginx-conf" and mounted
# as /etc/nginx/conf.d/default.conf through a Secret volume.
#
# Created with azapi (direct ARM call) because azurerm_container_app cannot express a Secret volume with
# an explicit file path: it would mount ALL app secrets (including ngc-api-key) as files into the nginx
# container, named after the secrets instead of default.conf.
resource "azapi_resource" "nano_12b_v2_vl" {
  type      = "Microsoft.App/containerApps@2025-01-01"
  name      = "nemotron-nano-12b-v2-vl"
  parent_id = data.azurerm_resource_group.rg.id
  location  = local.location
  tags      = var.tags

  # Share folders (subPath) must exist before the app starts.
  depends_on = [
    azurerm_container_app_environment_storage.shared,
    azurerm_storage_share_directory.root,
    azurerm_storage_share_directory.child,
  ]

  body = {
    properties = {
      environmentId       = local.environment_id
      workloadProfileName = local.a100_profile
      configuration = {
        activeRevisionsMode = "Single"
        ingress = {
          external      = true
          targetPort    = 8080
          transport     = "Auto"
          allowInsecure = false
        }
        registries = [
          {
            server            = "nvcr.io"
            username          = "$oauthtoken"
            passwordSecretRef = "ngc-api-key"
          }
        ]
      }
      template = {
        containers = [
          {
            name  = "nemotron-nano-12b-v2-vl"
            image = "nvcr.io/nim/nvidia/nemotron-nano-12b-v2-vl:latest"
            resources = {
              cpu    = 22
              memory = "212Gi"
            }
            env = [
              { name = "NGC_API_KEY", secretRef = "ngc-api-key" },
              { name = "NCCL_P2P_DISABLE", value = "1" },
              { name = "NCCL_IB_DISABLE", value = "1" },
              { name = "VLLM_GPU_MEMORY_UTILIZATION", value = "0.80" },
              { name = "NIM_ENGINE_STARTUP_TIMEOUT", value = "600" },
            ]
            # Large model: allow up to ~4 h of startup (240 x 60 s) before the platform restarts the replica.
            probes = [
              {
                type                = "Startup"
                tcpSocket           = { port = 8000 }
                initialDelaySeconds = 60
                periodSeconds       = 60
                timeoutSeconds      = 3
                failureThreshold    = 240
                successThreshold    = 1
              },
              {
                type                = "Readiness"
                tcpSocket           = { port = 8080 }
                initialDelaySeconds = 60
                periodSeconds       = 60
                timeoutSeconds      = 10
                failureThreshold    = 48
                successThreshold    = 1
              },
              {
                type                = "Liveness"
                tcpSocket           = { port = 8080 }
                initialDelaySeconds = 60
                periodSeconds       = 60
                timeoutSeconds      = 10
                failureThreshold    = 30
                successThreshold    = 1
              },
            ]
            volumeMounts = [
              { volumeName = "dshm", mountPath = "/dev/shm" },
              { volumeName = "cache", mountPath = "/opt/nim/.cache", subPath = "nano-12b-v2-vl/cache" },
            ]
          },
          {
            name  = "nginx"
            image = var.nginx_image
            resources = {
              cpu    = 2
              memory = "8Gi"
            }
            volumeMounts = [
              { volumeName = "nginx-conf", mountPath = "/etc/nginx/conf.d" },
            ]
          },
        ]
        # Autoscaling disabled: exactly one always-on replica.
        scale = {
          minReplicas = 1
          maxReplicas = 1
        }
        volumes = [
          { name = "dshm", storageType = "EmptyDir" },
          {
            name         = "cache"
            storageType  = "AzureFile"
            storageName  = azurerm_container_app_environment_storage.shared.name
            mountOptions = local.share_mount_options
          },
          {
            name        = "nginx-conf"
            storageType = "Secret"
            secrets     = [{ secretRef = "nginx-conf", path = "default.conf" }]
          },
        ]
      }
    }
  }

  # App secret values are write-only in ARM, so they go through sensitive_body.
  sensitive_body = {
    properties = {
      configuration = {
        secrets = [
          { name = "ngc-api-key", value = var.ngc_api_key },
          { name = "nginx-conf", value = file("${path.module}/../conf/default.conf") },
        ]
      }
    }
  }

  response_export_values = ["properties.configuration.ingress.fqdn"]
}

output "nano_12b_v2_vl_fqdn" {
  value = azapi_resource.nano_12b_v2_vl.output.properties.configuration.ingress.fqdn
}
