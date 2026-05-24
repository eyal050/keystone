# Provider configuration for platform/30-connectivity.
#
# Resources land inside keystone-platform-connectivity. The same
# hardening pattern as previous platform layers: provider
# subscription_id from a validated variable + display-name
# precondition on the first resource.
#
# NOTE: until keystone-platform-connectivity is vended (Phase 2 of
# 05-subscriptions, blocked on the MCA quota ticket), terraform plan
# fails immediately at the data.azurerm_subscription lookup. That is
# intentional — this layer is in the repo for review, not for apply.

provider "azurerm" {
  subscription_id = var.connectivity_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
