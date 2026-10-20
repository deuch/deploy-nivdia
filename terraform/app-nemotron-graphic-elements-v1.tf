# nemotron-graphic-elements-v1 : NIM image from nvcr.io -> T4 profile (8 vCPU / 56 GiB per replica).
# The stock NIM matrix lists A100-class GPUs; if it fails to start on T4, switch to local.a100_profile.
# Registry: nvcr.io (user "$oauthtoken", password = NGC API key).
resource "azurerm_container_app" "graphic_elements_v1" {
  name                         = "nemotron-graphic-elements-v1"
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
      name          = "storage"
      storage_type  = "AzureFile"
      storage_name  = azurerm_container_app_environment_storage.shared.name
      mount_options = local.share_mount_options
    }

    container {
      name   = "nemotron-graphic-elements-v1"
      image  = "nvcr.io/nim/nvidia/nemotron-graphic-elements-v1:latest"
      cpu    = 8
      memory = "56Gi"

      env {
        name        = "NGC_API_KEY"
        secret_name = "ngc-api-key"
      }
      # Must point inside the mounted torch cache path below to persist compiled kernels.
      env {
        name  = "TORCHINDUCTOR_CACHE_DIR"
        value = "/tmp/inductor"
      }

      volume_mounts {
        name = "dshm"
        path = "/dev/shm"
      }
      volume_mounts {
        name     = "storage"
        path     = "/tmp/inductor"
        sub_path = "graphic-elements-v1/torch"
      }
      volume_mounts {
        name     = "storage"
        path     = "/opt/nim/.cache"
        sub_path = "graphic-elements-v1/cache"
      }
    }
  }
}

output "graphic_elements_v1_fqdn" {
  value = azurerm_container_app.graphic_elements_v1.ingress[0].fqdn
}
