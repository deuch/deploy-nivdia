# nemotron-table-structure-v1 : ~1 GiB of GPU memory -> T4 profile.
# Custom image in containerdemosdec.azurecr.io (stock NIM does not list T4).
# Registry is treated as PUBLIC (anonymous pull): no registry block, no identity.
# NGC_API_KEY is only used at runtime by the image to download the weights into /model.
resource "azurerm_container_app" "table_structure_v1" {
  name                         = "nemotron-table-structure-v1"
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
      name          = "storage"
      storage_type  = "AzureFile"
      storage_name  = azurerm_container_app_environment_storage.shared.name
      mount_options = local.share_mount_options
    }

    volume {
      name         = "dshm"
      storage_type = "EmptyDir"
    }

    container {
      name   = "nemotron-table-structure-v1"
      image  = var.custom_image
      cpu    = 8
      memory = "56Gi"

      env {
        name        = "NGC_API_KEY"
        secret_name = "ngc-api-key"
      }
      env {
        name  = "NIM_ENGINE_MODEL_DOWNLOAD_PROVIDER"
        value = "ngc"
      }
      env {
        name  = "NIM_ENGINE_MODEL_NAME"
        value = "nvidia/nemotron-table-structure-v1"
      }
      env {
        name  = "NIM_ENGINE_MODEL_PATH"
        value = "/model/table-structure"
      }
      env {
        name  = "LOG_FORMAT"
        value = "pretty"
      }
      env {
        name  = "RUST_LOG"
        value = "info"
      }

      volume_mounts {
        name     = "storage"
        path     = "/model"
        sub_path = "table-structure-v1/weight"
      }
      volume_mounts {
        name     = "storage"
        path     = "/opt/cache"
        sub_path = "table-structure-v1/cache"
      }
      volume_mounts {
        name = "dshm"
        path = "/dev/shm"
      }
    }
  }
}

output "table_structure_v1_fqdn" {
  value = azurerm_container_app.table_structure_v1.ingress[0].fqdn
}
