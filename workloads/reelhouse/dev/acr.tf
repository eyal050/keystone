# ACR + CI/CD identity per ADR-0015.
#
# ACR Basic SKU (cheapest tier with full RBAC). Admin user disabled —
# all access is via Entra/RBAC. ACA pulls images using the Container
# App's system-assigned MI (granted AcrPull below). GitHub Actions
# pushes images using a UAMI bound to the repo via federated OIDC.

# --- Azure Container Registry ----------------------------------------------

resource "random_string" "acr_suffix" {
  length  = 8
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_container_registry" "this" {
  # ACR names: alphanumeric only, 5-50 chars, globally unique.
  name                = "acrreelhdev${random_string.acr_suffix.result}"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  sku           = "Basic"
  admin_enabled = false # all auth via Entra RBAC; no admin user

  # Public access is enabled — ACR Basic doesn't support private
  # endpoints (Premium-only). RBAC is the access control. Documented
  # in ADR-0015.
  public_network_access_enabled = true

  tags = var.required_tags
}

# --- ACA managed identity → AcrPull on the workload ACR ---------------------

resource "azurerm_role_assignment" "aca_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_container_app.api.identity[0].principal_id
}

# --- User-assigned managed identity for GitHub Actions ----------------------
#
# This identity is what the workflow authenticates as via OIDC. Bound
# to the repo `eyal050/keystone` on the `refs/heads/main` ref via a
# federated identity credential (no client secret stored anywhere).

resource "azurerm_user_assigned_identity" "github_actions" {
  name                = "uami-gha-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tags = var.required_tags
}

# Federated identity credential: binds the UAMI to GitHub Actions
# runs on the main branch of eyal050/keystone. The OIDC token issued
# by GitHub during the workflow run gets exchanged for an Azure access
# token for this UAMI.
resource "azurerm_federated_identity_credential" "github_main" {
  name                = "github-main"
  resource_group_name = azurerm_resource_group.workload.name
  parent_id           = azurerm_user_assigned_identity.github_actions.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "repo:eyal050/keystone:ref:refs/heads/main"
}

# --- UAMI permissions: AcrPush + Contributor on the Container App ----------

resource "azurerm_role_assignment" "gha_acr_push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

resource "azurerm_role_assignment" "gha_containerapp_contributor" {
  # Scoped to the specific Container App resource, not the RG —
  # narrower than necessary in practice (workflow only needs
  # Microsoft.App/containerApps/write + read on revisions) but
  # Contributor is the simplest correct answer. Custom role can
  # replace this later if least-privilege-exercise has interview value.
  scope                = azurerm_container_app.api.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}

# ARM's "linked authorization" model: even though `az containerapp
# update` targets the Container App, ARM verifies the caller also has
# `Microsoft.App/managedEnvironments/join/action` on the linked ACA
# environment. Without this, `az containerapp registry set` and
# `az containerapp update --image` both fail with LinkedAuthorizationFailed.
resource "azurerm_role_assignment" "gha_aca_env_contributor" {
  scope                = azurerm_container_app_environment.this.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.github_actions.principal_id
}
