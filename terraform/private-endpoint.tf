# OPTIONAL: private access to every app through ONE private endpoint on the environment.
# Enable with:  enable_private_endpoint = true  and  public_network_access = "Disabled"
locals {
  pe_enabled = var.enable_private_endpoint
  # "<unique-id>.<region>.azurecontainerapps.io" -> "<unique-id>"
  env_unique_id = split(".", local.environment_default_domain)[0]
}

resource "azurerm_virtual_network" "pe" {
  count               = local.pe_enabled ? 1 : 0
  name                = var.private_endpoint_vnet_name
  location            = local.location
  resource_group_name = local.rg_name
  address_space       = ["10.50.0.0/16"]
  tags                = var.tags
}

resource "azurerm_subnet" "pe" {
  count                = local.pe_enabled ? 1 : 0
  name                 = "private-endpoints"
  resource_group_name  = local.rg_name
  virtual_network_name = azurerm_virtual_network.pe[0].name
  address_prefixes     = ["10.50.1.0/24"]
}

resource "azurerm_private_endpoint" "env" {
  count               = local.pe_enabled ? 1 : 0
  name                = "pe-${var.environment_name}"
  location            = local.location
  resource_group_name = local.rg_name
  subnet_id           = azurerm_subnet.pe[0].id
  tags                = var.tags

  private_service_connection {
    name                           = "aca-env"
    private_connection_resource_id = local.environment_id
    subresource_names              = ["managedEnvironments"]
    is_manual_connection           = false
  }
}

resource "azurerm_private_dns_zone" "aca" {
  count               = local.pe_enabled ? 1 : 0
  name                = "privatelink.${var.location}.azurecontainerapps.io"
  resource_group_name = local.rg_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca" {
  count                 = local.pe_enabled ? 1 : 0
  name                  = "${var.private_endpoint_vnet_name}-link"
  resource_group_name   = local.rg_name
  private_dns_zone_name = azurerm_private_dns_zone.aca[0].name
  virtual_network_id    = azurerm_virtual_network.pe[0].id
}

resource "azurerm_private_dns_a_record" "env" {
  count               = local.pe_enabled ? 1 : 0
  name                = local.env_unique_id
  zone_name           = azurerm_private_dns_zone.aca[0].name
  resource_group_name = local.rg_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.env[0].private_service_connection[0].private_ip_address]
}

resource "azurerm_private_dns_a_record" "apps" {
  count               = local.pe_enabled ? 1 : 0
  name                = "*.${local.env_unique_id}"
  zone_name           = azurerm_private_dns_zone.aca[0].name
  resource_group_name = local.rg_name
  ttl                 = 300
  records             = [azurerm_private_endpoint.env[0].private_service_connection[0].private_ip_address]
}
