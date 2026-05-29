# Provider configuration for workloads/reelhouse/dev.
#
# Per ADR-0013, this layer creates resources in TWO subscriptions:
#
#   1. Workload sub (default provider) — spoke VNet, subnets, NSGs,
#      spoke-side peering, future workload resources (ACA, Postgres,
#      Key Vault, APIM, storage, etc.)
#
#   2. Connectivity sub (`azurerm.connectivity` alias) — hub-side
#      peering pointing at the spoke VNet, spoke-side Private DNS
#      zone links (which live in the hub RG even though they
#      reference the spoke VNet).
#
# CONVENTION: every resource in this layer that lands in the
# connectivity sub MUST explicitly set `provider = azurerm.connectivity`.
# Forgetting it lands the resource in the workload sub by mistake —
# usually surfaces as a confusing "resource not found" or "no such
# parent resource" error at plan time.

# Default provider — workload sub (lab-foundation today per ADR-0012).
#
# storage_use_azuread = true is REQUIRED because the workload's blob SA
# sets `shared_access_key_enabled = false` (we use Entra/MI auth, not
# storage keys). Without this provider flag, terraform's own polling
# of the blob service falls back to shared-key auth and fails with
# 403 KeyBasedAuthenticationNotPermitted.
provider "azurerm" {
  subscription_id = var.workload_subscription_id
  tenant_id       = var.tenant_id

  storage_use_azuread = true

  features {}
}

# Aliased provider — connectivity sub. Used for hub-side peering and
# spoke-side DNS zone links.
provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
