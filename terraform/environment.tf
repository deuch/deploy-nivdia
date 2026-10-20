# Container Apps environment with the Consumption, A100 and T4 serverless GPU workload profiles.
#
# Created with the azapi provider (direct ARM call, same API as the Bicep module) instead of
# azurerm_container_app_environment: the azurerm resource always sends `MinimumCount` for workload
# profiles and the platform rejects it for serverless GPU profiles (WorkloadProfilePropertyNotSupported,
# hashicorp/terraform-provider-azurerm#31763).
resource "azapi_resource" "env" {
  type      = "Microsoft.App/managedEnvironments@2025-02-02-preview"
  name      = var.environment_name
  parent_id = data.azurerm_resource_group.rg.id
  location  = local.location
  tags      = var.tags

  body = {
    properties = {
      zoneRedundant       = false
      publicNetworkAccess = var.public_network_access
      appLogsConfiguration = {
        destination = "log-analytics"
        logAnalyticsConfiguration = {
          customerId = azurerm_log_analytics_workspace.law.workspace_id
        }
      }
      workloadProfiles = [
        {
          name                = "Consumption"
          workloadProfileType = "Consumption"
        },
        {
          name                = local.a100_profile
          workloadProfileType = "Consumption-GPU-NC24-A100" # 24 vCPU / 220 GiB / 1x A100 80 GB per replica
        },
        {
          name                = local.t4_profile
          workloadProfileType = "Consumption-GPU-NC8as-T4" # 8 vCPU / 56 GiB / 1x T4 16 GB per replica
        },
      ]
    }
  }

  sensitive_body = {
    properties = {
      appLogsConfiguration = {
        logAnalyticsConfiguration = {
          sharedKey = azurerm_log_analytics_workspace.law.primary_shared_key
        }
      }
    }
  }

  response_export_values = ["properties.defaultDomain"]
}

locals {
  environment_id             = azapi_resource.env.id
  environment_default_domain = azapi_resource.env.output.properties.defaultDomain
}

# Storage link that every app volume references (storage_name = "shared-volume").
resource "azurerm_container_app_environment_storage" "shared" {
  name                         = "shared-volume"
  container_app_environment_id = local.environment_id
  account_name                 = azurerm_storage_account.files.name
  share_name                   = azurerm_storage_share.containers.name
  access_key                   = azurerm_storage_account.files.primary_access_key
  access_mode                  = "ReadWrite"
}
