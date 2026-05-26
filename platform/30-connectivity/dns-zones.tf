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
# The file splits zones into two sets:
#
#   - PLATFORM zones (E1) — services that exist or will exist as part
#     of the platform layers (storage, Log Analytics).
#   - WORKLOAD zones (E3) — services consumed by ReelHouse (Key Vault,
#     Postgres, Container Apps, APIM).
#
# Both sets are created and linked identically. The split is for
# documentation / `terraform state list` legibility, not for any
# behavioural difference.
#
# Cost: ~€0.50/zone/month, no free tier. 4 + 4 = 8 zones = ~€4/month
# flat-monthly. Query cost (first 1M/month/zone free) is deep in the
# free tier at lab volumes.

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

  workload_private_dns_zones = toset([
    # Key Vault — workload secrets (SAS signing keys, DB connection
    # strings per CLAUDE.md §2 workload scope).
    "privatelink.vaultcore.azure.net",

    # PostgreSQL Flexible Server — workload metadata (users, videos,
    # share links).
    "privatelink.postgres.database.azure.com",

    # Azure Container Apps environment with internal ingress.
    # IMPORTANT: this zone is REGION-SCOPED — the region segment is
    # part of the zone name, not the record. Moving region means a
    # different zone name. ADR-0002 pins this to westeurope.
    "privatelink.${var.location}.azurecontainerapps.io",

    # API Management with internal mode behind Front Door.
    "privatelink.azure-api.net",
  ])
}

resource "azurerm_private_dns_zone" "platform" {
  for_each = local.platform_private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name

  tags = var.required_tags
}

resource "azurerm_private_dns_zone" "workload" {
  for_each = local.workload_private_dns_zones

  name                = each.value
  resource_group_name = azurerm_resource_group.hub.name

  tags = var.required_tags
}

# Link every zone (platform + workload) to the hub VNet.
# registration_enabled = false because privatelink zones are
# RESOLUTION-only: clients query them to resolve names, they don't
# auto-register VMs / NICs into the zone.
#
# `merge()` is safe here because platform and workload zone names do
# not overlap — each set is a `toset()` and the two sets are disjoint
# by construction.
resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = merge(
    azurerm_private_dns_zone.platform,
    azurerm_private_dns_zone.workload,
  )

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
