variable "subscription_id" {
  description = "Target Azure subscription ID."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into."
  type        = string
}

variable "location" {
  description = "Azure region where serverless A100/T4 GPUs are available."
  type        = string
}

variable "environment_name" {
  type    = string
  default = "nim-gpu-env"
}

variable "log_analytics_name" {
  type    = string
  default = "nim-gpu-logs"
}

variable "storage_account_name" {
  description = "Globally unique storage account name (3-24 lowercase letters/digits). Must not be an existing account."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "storage_account_name must be 3-24 lowercase letters and digits."
  }
}

variable "share_name" {
  type    = string
  default = "containers"
}

variable "share_quota_gib" {
  type    = number
  default = 1024
}

variable "custom_image" {
  description = "Custom object-detection image used by page-elements-v3 and table-structure-v1. The registry is treated as public (anonymous pull)."
  type        = string
  default     = "containerdemosdec.azurecr.io/nvidia/nemotron-object-detection:custom"
}

variable "ngc_api_key" {
  description = "NGC API key. Pass with TF_VAR_ngc_api_key; never commit it."
  type        = string
  sensitive   = true
}

variable "public_network_access" {
  description = "Enabled or Disabled. Use Disabled together with enable_private_endpoint."
  type        = string
  default     = "Enabled"

  validation {
    condition     = contains(["Enabled", "Disabled"], var.public_network_access)
    error_message = "public_network_access must be Enabled or Disabled."
  }
}

variable "enable_private_endpoint" {
  description = "Create VNet + private endpoint + private DNS zone for the environment."
  type        = bool
  default     = false
}

variable "private_endpoint_vnet_name" {
  type    = string
  default = "vnet-nim-private"
}

variable "nginx_image" {
  description = "Image of the nginx sidecar of nemotron-nano-12b-v2-vl (reverse proxy in front of the NIM)."
  type        = string
  default     = "docker.io/nginx:stable-alpine"
}

variable "tags" {
  type    = map(string)
  default = { workload = "nvidia-nim" }
}
