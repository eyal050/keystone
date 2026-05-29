# C1: Azure Container Apps environment + Container App.
#
# Per ADR-0014 the workload's public entry point is ACA's external
# ingress directly — no APIM, no Front Door. TLS on the ACA-managed
# *.azurecontainerapps.io domain.
#
# Topology:
#   - ACA env in snet-aca-001 (delegation to Microsoft.App/environments
#     is set inline on the subnet in network.tf).
#   - System-assigned managed identity on the Container App.
#   - The MI receives RBAC roles for KV (Secrets User) and Blob
#     (Data Contributor). Postgres connectivity is via the KV-stored
#     connection string (password auth, not Entra).
#   - Logs forward to the centralized Log Analytics workspace in
#     keystone-platform-management (LAW ID read from 20-management's
#     remote state; the cross-sub key fetch is handled internally by
#     the Microsoft.App service when the env is created — the
#     operator's credentials need Reader on the LAW for the resource
#     ID validation at plan time, which Eyal-as-Owner satisfies).

# Read the central LAW ID from 20-management's outputs. No third
# provider needed — the LAW resource ID is non-sensitive, and the
# Microsoft.App service handles the cross-sub key fetch internally
# when the env is created.
data "terraform_remote_state" "management" {
  backend = "azurerm"

  config = {
    subscription_id      = var.mgmt_subscription_id
    tenant_id            = var.tenant_id
    resource_group_name  = "rg-tfstate-plat-weu-001"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "platform-20-management.tfstate"
  }
}

# --- Container Apps environment ---------------------------------------------

resource "azurerm_container_app_environment" "this" {
  name                = "cae-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  # VNet injection — subnet has the Microsoft.App/environments
  # delegation inline (network.tf).
  infrastructure_subnet_id = azurerm_subnet.aca.id

  # External ingress endpoint (*.azurecontainerapps.io) reachable
  # from the internet. Per ADR-0014 this is the workload's public
  # entry point (no APIM, no Front Door).
  internal_load_balancer_enabled = false

  # Logs to platform LAW.
  log_analytics_workspace_id = data.terraform_remote_state.management.outputs.law_id

  # Workload profile: Consumption only (cheap, scale-to-zero).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = var.required_tags
}

# --- Container App -----------------------------------------------------------

resource "azurerm_container_app" "api" {
  name                         = "ca-reelhouse-api-${var.location_short}-001"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.workload.name
  revision_mode                = "Single"

  identity {
    type = "SystemAssigned"
  }

  template {
    min_replicas = 0 # scale-to-zero for cost
    max_replicas = 2

    container {
      name   = "reelhouse-api"
      image  = var.workload_image
      cpu    = 0.5
      memory = "1Gi"

      env {
        name  = "KEYVAULT_URI"
        value = azurerm_key_vault.this.vault_uri
      }

      env {
        name  = "STORAGE_ACCOUNT_NAME"
        value = azurerm_storage_account.videos.name
      }

      env {
        name  = "STORAGE_CONTAINER"
        value = azurerm_storage_container.videos.name
      }

      env {
        name  = "PORT"
        value = "8080"
      }
    }
  }

  ingress {
    external_enabled = true
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  tags = var.required_tags
}

# --- RBAC: ACA MI → KV / Blob -----------------------------------------------
#
# Postgres access does not need an Azure RBAC role assignment — the
# connection string in KV embeds the password, so the MI just needs
# Key Vault Secrets User (above) to read the connection string.

resource "azurerm_role_assignment" "aca_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_container_app.api.identity[0].principal_id
}

resource "azurerm_role_assignment" "aca_blob_contributor" {
  scope                = azurerm_storage_account.videos.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_container_app.api.identity[0].principal_id
}
