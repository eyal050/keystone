# Provider configuration for platform/00-bootstrap.
#
# subscription_id is supplied via var.mgmt_subscription_id, which itself
# comes from the TF_VAR_mgmt_subscription_id env var sourced from
# ~/.keystone/secrets.env. tenant_id likewise.
#
# Authentication is via az CLI for local runs (no client_id/client_secret).
# Once OIDC federation is wired in (deferred to a later chunk), CI uses
# federated credentials and these provider blocks gain ARM_USE_OIDC
# enablement via env var, no code change here.

provider "azurerm" {
  subscription_id = var.mgmt_subscription_id
  tenant_id       = var.tenant_id

  features {
    resource_group {
      prevent_deletion_if_contains_resources = true
    }

    storage {
      data_plane_available = true
    }
  }
}

provider "azuread" {
  tenant_id = var.tenant_id
}
