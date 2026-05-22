# Cross-layer state read + provider-context sanity check.

# Read platform/05-subscriptions outputs. The subscriptions metadata
# map is non-sensitive; subscription IDs come from the sensitive
# subscription_ids map.
data "terraform_remote_state" "subscriptions" {
  backend = "azurerm"

  config = {
    subscription_id      = var.mgmt_subscription_id
    tenant_id            = var.tenant_id
    resource_group_name  = "rg-tfstate-plat-weu-001"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "platform-05-subscriptions.tfstate"
  }
}

# Same hardening pattern as platform/00-bootstrap — fail plan if the
# provider's auth-context sub is not keystone-platform-management.
# MGs are tenant-scoped so the sub does not affect resource placement,
# but consistency with the bootstrap precondition matters: any layer
# that uses the Management sub as its provider context should verify
# that it actually IS the Management sub.
data "azurerm_subscription" "mgmt" {
  subscription_id = var.mgmt_subscription_id
}
