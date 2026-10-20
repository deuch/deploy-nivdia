# nemotron-ocr-v1 : NIM image from nvcr.io, runs on a T4 in the live deployment.
# If the NIM refuses to start on T4 for your image tag, switch workload_profile_name to local.a100_profile.
# Registry: nvcr.io (user "$oauthtoken", password = NGC API key).
resource "azurerm_container_app" "ocr_v1" {
  name                         = "nemotron-ocr-v1"
  container_app_environment_id = local.environment_id
  resource_group_name          = local.rg_name
  revision_mode                = "Single"
  workload_profile_name        = local.t4_profile
  tags                         = var.tags

  # Share folders (subPath) must exist before the app starts.
  depends_on = [
    azurerm_container_app_environment_storage.shared,
    azurerm_storage_share_directory.root,
    azurerm_storage_share_directory.child,
  ]

  secret {
    name  = "ngc-api-key"
    value = var.ngc_api_key
  }

  registry {
    server               = "nvcr.io"
    username             = "$oauthtoken"
    password_secret_name = "ngc-api-key"
  }

  ingress {
    external_enabled           = true
    target_port                = 8000
    transport                  = "auto"
    allow_insecure_connections = false

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    # Autoscaling disabled: exactly one always-on replica.
    min_replicas = 1
    max_replicas = 1

    volume {
      name         = "dshm"
      storage_type = "EmptyDir"
    }

    volume {
      name          = "nim-cache"
      storage_type  = "AzureFile"
      storage_name  = azurerm_container_app_environment_storage.shared.name
      mount_options = local.share_mount_options
    }

    container {
      name   = "nemotron-ocr-v1"
      image  = "nvcr.io/nim/nvidia/nemotron-ocr-v1:latest"
      cpu    = 8
      memory = "56Gi"

      env {
        name        = "NGC_API_KEY"
        secret_name = "ngc-api-key"
      }

      volume_mounts {
        name = "dshm"
        path = "/dev/shm"
      }
      volume_mounts {
        name     = "nim-cache"
        path     = "/opt/nim/.cache"
        sub_path = "ocr-v1"
      }
    }
  }
}

output "ocr_v1_fqdn" {
  value = azurerm_container_app.ocr_v1.ingress[0].fqdn
}
