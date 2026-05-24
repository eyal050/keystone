# Private DNS zones — centrally managed in the hub per CLAUDE.md §2.
#
# Each zone is created in the connectivity sub and linked to the hub
# VNet so resources inside the hub resolve <service>.privatelink.<domain>
# to the private IP of any private endpoint that points at it.
#
# Spoke VNets get their own link to each zone when peering lands
# (chunk E4 / spoke creation). Until then, only the hub itself can
# resolve via these zones.
#
# This file covers the PLATFORM-side zones — services that already
# exist or will exist as part of the platform layers (storage SAs,
# Log Analytics ingestion endpoints). Workload-side zones (Key Vault,
# Postgres, Container Apps, APIM) land in a later chunk alongside the
# workload deployment.
#
# Cost: ~€0.50/zone/month, no free tier. 4 zones = ~€2/month constant
# flat-monthly. First lab resource where realised cost moves above
# the noise floor.

locals {
  platform_private_dns_zones = toset([
    # Blob storage private endpoints — covers the state SA's future
    # private endpoint, and any blob SAs we create later.
    "privatelink.blob.core.windows.net",

    # Azure Monitor — covers monitor.azure.com private endpoints
    # used by Application Insights, AMPLS, etc.
    "privatelink.monitor.azure.com",

    # Log Analytics ingestion (modern endpoint).
    "privatelink.ods.opinsights.azure.com",

    # Log Analytics agents (legacy / OMS path). Still active in
    # current Azure — separate from the ods endpoint.
    "privatelink.oms.opinsights.azure.com",
  ])
}

resource "azurerm_private_dns_zone" "platform" {
  for_each = local.platform_private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name

  tags = var.required_tags
}

# Link each zone to the hub VNet. registration_enabled = false because
# privatelink zones are RESOLUTION-only: clients query them to resolve
# names, they don't auto-register VMs / NICs into the zone.
resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = azurerm_private_dns_zone.platform

  # Link names must be unique within a zone. Use the VNet name as the
  # disambiguator — when spokes get peered in, they'll add their own
  # link with their own VNet name.
  name                  = "link-${azurerm_virtual_network.hub.name}"
  resource_group_name   = azurerm_resource_group.hub.name
  private_dns_zone_name = each.value.name
  virtual_network_id    = azurerm_virtual_network.hub.id

  registration_enabled = false

  tags = var.required_tags
}
