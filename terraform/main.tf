data "azurerm_resource_group" "rg" {
  name = var.resource_group_name
}

locals {
  rg_name  = data.azurerm_resource_group.rg.name
  location = var.location

  # Profile names referenced by the apps.
  a100_profile = "A100-Profile"
  t4_profile   = "T4-Profile"

  share_mount_options = "dir_mode=0777,file_mode=0777,uid=1000,gid=1000,mfsymlinks"
}

# ---------- Observability ----------
resource "azurerm_log_analytics_workspace" "law" {
  name                = var.log_analytics_name
  location            = local.location
  resource_group_name = local.rg_name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------- Azure Files share holding NIM caches / model weights ----------
resource "azurerm_storage_account" "files" {
  name                            = var.storage_account_name
  location                        = local.location
  resource_group_name             = local.rg_name
  account_kind                    = "FileStorage"
  account_tier                    = "Premium"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = true # Container Apps mounts Azure Files with the account key
  tags                            = var.tags
}

resource "azurerm_storage_share" "containers" {
  name               = var.share_name
  storage_account_id = azurerm_storage_account.files.id
  quota              = var.share_quota_gib
  enabled_protocol   = "SMB"
}

# Folders used as `subPath` by the apps. They are created (data plane) before any app, parents first.
locals {
  share_root_folders = [
    "graphic-elements-v1",
    "ocr-v1",
    "page-elements-v3",
    "table-structure-v1",
    "nano-12b-v2-vl",
  ]
  share_child_folders = [
    "graphic-elements-v1/torch",
    "graphic-elements-v1/cache",
    "page-elements-v3/cache",
    "page-elements-v3/weight",
    "table-structure-v1/cache",
    "table-structure-v1/weight",
    "nano-12b-v2-vl/cache",
  ]
}

resource "azurerm_storage_share_directory" "root" {
  for_each          = toset(local.share_root_folders)
  name              = each.value
  storage_share_url = azurerm_storage_share.containers.url
}

resource "azurerm_storage_share_directory" "child" {
  for_each          = toset(local.share_child_folders)
  name              = each.value
  storage_share_url = azurerm_storage_share.containers.url

  depends_on = [azurerm_storage_share_directory.root]
}
