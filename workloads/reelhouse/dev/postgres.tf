# D1: PostgreSQL Flexible Server B1ms + private endpoint.
#
# Smallest tier (Burstable B1ms): 1 vCPU, 2 GB RAM, ~€12/mo always-on.
# Single AZ, no HA, 7-day backup retention. Public network access
# disabled — reachable only via private endpoint in snet-pe-001,
# with DNS resolution via the central privatelink.postgres zone.
#
# Auth: password (random_password resource, stored in Key Vault by K1
# and consumed by the workload via managed identity → KV → env var).
# Entra/AD auth is a future enhancement; password is simpler today.

resource "random_password" "postgres_admin" {
  length  = 32
  special = true
  # Postgres rejects some special chars in passwords; restrict to safe set.
  override_special = "!#%*-_=+"
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "pg-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  version = "16"
  # Omit `zone` — Azure assigns whichever AZ has capacity for this
  # subscription. Pinning to a specific zone hit AvailabilityZoneNotAvailable
  # on 2026-05-29 ("Availability zone '1' isn't available in location
  # 'westeurope' for subscription"); AZ-to-sub availability varies.

  sku_name   = "B_Standard_B1ms" # Burstable, 1 vCPU, 2 GB RAM
  storage_mb = 32768             # 32 GB minimum

  administrator_login    = "reelhouse_admin"
  administrator_password = random_password.postgres_admin.result

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  # Public access completely disabled — only the PE below reaches it.
  public_network_access_enabled = false

  # No high availability for lab. In azurerm 4.x the `high_availability`
  # block must be OMITTED for "no HA" — passing mode="Disabled" is
  # rejected by the provider.

  tags = var.required_tags

  lifecycle {
    # Provisioning takes 8-12 min — Terraform will look like it's hung.
    # Don't kill it. Zone can drift if Azure reassigns; not worth
    # replanning over.
    ignore_changes = [zone]
  }
}

resource "azurerm_postgresql_flexible_server_database" "reelhouse" {
  name      = "reelhouse"
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

# --- Private endpoint into snet-pe-001 --------------------------------------
#
# The PE lives in the workload sub (the spoke is here too). Its
# private_dns_zone_group references the central
# privatelink.postgres.database.azure.com zone in the connectivity sub —
# Azure auto-writes the A record into that zone on PE creation, which
# the spoke's DNS zone link makes resolvable from inside the spoke VNet.

resource "azurerm_private_endpoint" "postgres" {
  name                = "pe-pg-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-pg-reelhouse-dev"
    private_connection_resource_id = azurerm_postgresql_flexible_server.this.id
    is_manual_connection           = false
    subresource_names              = ["postgresqlServer"]
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      data.terraform_remote_state.connectivity.outputs.private_dns_zone_ids["privatelink.postgres.database.azure.com"],
    ]
  }

  tags = var.required_tags
}
