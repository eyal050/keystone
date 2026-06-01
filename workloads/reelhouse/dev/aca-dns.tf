# An internal ACA environment is resolvable only via a private DNS zone for its
# default domain. APIM (same spoke VNet) resolves the app FQDN to the env's
# internal static IP through this zone. Per ADR-0019.
#
# This zone is PERMANENT (not gated on gateway_enabled): it belongs to the
# internal env, which is permanent. It is a per-env zone, distinct from the
# central privatelink.* zones in the hub (those are for private endpoints).

resource "azurerm_private_dns_zone" "aca_env" {
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.workload.name
  tags                = var.required_tags
}

resource "azurerm_private_dns_a_record" "aca_env_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca_env.name
  resource_group_name = azurerm_resource_group.workload.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
  tags                = var.required_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_env_spoke" {
  name                  = "link-${azurerm_virtual_network.spoke.name}"
  resource_group_name   = azurerm_resource_group.workload.name
  private_dns_zone_name = azurerm_private_dns_zone.aca_env.name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.required_tags
}
