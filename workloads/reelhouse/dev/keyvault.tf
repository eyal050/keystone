# K1: Key Vault + private endpoint + initial secrets.
#
# Standard SKU. RBAC auth model (modern recommendation; Access Policies
# are legacy). Public network access disabled — only the PE in
# snet-pe-001 + the operator running terraform apply over the public
# control plane (vault creation goes via the management API, not the
# data plane).
#
# Operator-identity RBAC grant: even as subscription Owner, the
# control-plane permissions don't include data-plane access to KV
# secrets. The operator running `terraform apply` needs an explicit
# Key Vault Administrator role assignment on the vault before secret
# resources can be created. The role_assignment resource below grants
# that to whoever is running terraform (data.azurerm_client_config).
#
# ACA's managed identity gets Key Vault Secrets User (read-only) on
# this vault — that role assignment lives in C1 alongside the MI.

data "azurerm_client_config" "current" {}

# Two deliberate lab trade-offs, justified inline below and suppressed for
# tfsec (directives must be on the lines immediately above the resource):
#   - specify-network-acl: public_network_access_enabled=true (see comment
#     below) is required so the operator can write secrets over the public
#     control plane; RBAC is the actual access control. A default-Deny ACL
#     would block that path and the ACA app's public-endpoint + RBAC access
#     when the PE is off (ADR-0017). Production would use default-Deny + PE-only.
#   - no-purge: purge protection is off so `terraform destroy` can fully clean
#     up the vault during lab iteration. Production should enable it.
#tfsec:ignore:azure-keyvault-specify-network-acl
#tfsec:ignore:azure-keyvault-no-purge
resource "azurerm_key_vault" "this" {
  name                = "kv-reelhdev-${random_string.kv_suffix.result}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tenant_id = var.tenant_id
  sku_name  = "standard"

  # RBAC mode (modern), not Access Policies.
  rbac_authorization_enabled = true

  # Public network access ENABLED — but RBAC is the actual access
  # control (Key Vault Secrets User to read, Administrator to write).
  # PNA=false would block the operator running `terraform apply` from
  # writing secrets via the data plane, since the operator is on the
  # public internet rather than inside the spoke VNet.
  #
  # The workload (ACA Container App) still uses the PE below for its
  # KV calls — that's the path from inside the spoke. PNA=true just
  # opens the *option* of public-internet access; RBAC denies unless
  # the caller has the right role.
  #
  # No `deny-public-kv` policy exists at the keystone-landing-zones-corp
  # MG scope (only deny-storage-public for storage), so this doesn't
  # conflict with platform policy.
  public_network_access_enabled = true

  # Soft delete is non-optional in Azure since 2020.
  soft_delete_retention_days = 7

  # No purge protection for lab — would block `terraform destroy`.
  # Production should enable this.
  purge_protection_enabled = false

  tags = var.required_tags
}

# KV names are globally unique within Azure and capped at 24 chars.
# `kv-reelhdev-` is 12 chars; suffix budget is 12 chars; use 8 to leave
# slack.
resource "random_string" "kv_suffix" {
  length  = 8
  upper   = false
  special = false
}

# --- Operator data-plane RBAC -----------------------------------------------
#
# Grants whoever is running `terraform apply` Key Vault Administrator
# on this vault so secret creation below works. Without this, the
# secrets fail with "Forbidden" even when the operator is sub Owner.

resource "azurerm_role_assignment" "operator_kv_admin" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id

  # Pinned to whoever bootstrapped this grant (the human operator). Under CI,
  # data.azurerm_client_config.current resolves to the apply UAMI, which would
  # otherwise try to re-point this grant — a change our ABAC allow-list
  # (rightly) blocks (Key Vault Administrator is not allow-listed). Pinning the
  # principal keeps this an operator-owned grant; CI never touches it.
  lifecycle {
    ignore_changes = [principal_id]
  }
}

# --- Initial secrets --------------------------------------------------------
#
# DB password (from D1) + admin user password for the ReelHouse app's
# single hardcoded admin login (per CLAUDE.md §2 workload scope).
# Connection string is assembled here so the workload only needs to
# read one secret to talk to Postgres.

resource "random_password" "reelhouse_admin" {
  length  = 24
  special = true
}

# Captures a single creation timestamp so secret expiry is set once and stays
# stable across applies. Using timestamp() directly would re-evaluate every
# plan (perpetual diff); a literal date would go stale (break-debug-log
# 2026-05-29). time_static records the first-apply instant and never changes.
resource "time_static" "secret_created" {}

resource "azurerm_key_vault_secret" "postgres_password" {
  name         = "postgres-admin-password"
  key_vault_id = azurerm_key_vault.this.id
  value        = random_password.postgres_admin.result

  content_type = "text/plain"

  # Expiry 1 year after first apply (time_static.secret_created is stable).
  expiration_date = timeadd(time_static.secret_created.rfc3339, "8760h")

  depends_on = [azurerm_role_assignment.operator_kv_admin]
}

resource "azurerm_key_vault_secret" "postgres_connection_string" {
  # Conn string is meaningful only while Postgres exists (its FQDN
  # depends on the PG server resource). When postgres_enabled=false,
  # secret goes away with PG. App's psycopg connect would fail without
  # this secret — that's fine, the app's only callers between sessions
  # are health probes which don't touch PG.
  count = var.postgres_enabled ? 1 : 0

  name         = "postgres-connection-string"
  key_vault_id = azurerm_key_vault.this.id
  value        = "postgresql://reelhouse_admin:${random_password.postgres_admin.result}@${azurerm_postgresql_flexible_server.this[0].fqdn}:5432/reelhouse?sslmode=require"

  content_type = "text/plain"

  expiration_date = timeadd(time_static.secret_created.rfc3339, "8760h")

  depends_on = [azurerm_role_assignment.operator_kv_admin]
}

resource "azurerm_key_vault_secret" "reelhouse_admin_password" {
  name         = "reelhouse-admin-password"
  key_vault_id = azurerm_key_vault.this.id
  value        = random_password.reelhouse_admin.result

  content_type = "text/plain"

  expiration_date = timeadd(time_static.secret_created.rfc3339, "8760h")

  depends_on = [azurerm_role_assignment.operator_kv_admin]
}

# --- Private endpoint into snet-pe-001 --------------------------------------

resource "azurerm_private_endpoint" "keyvault" {
  count = var.workload_pe_enabled ? 1 : 0

  name                = "pe-kv-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-kv-reelhouse-dev"
    private_connection_resource_id = azurerm_key_vault.this.id
    is_manual_connection           = false
    subresource_names              = ["vault"]
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      data.terraform_remote_state.connectivity.outputs.private_dns_zone_ids["privatelink.vaultcore.azure.net"],
    ]
  }

  tags = var.required_tags
}
