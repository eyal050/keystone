# Provider configuration for platform/10-management-groups.
#
# Management groups are tenant-scoped: they live above subscriptions.
# subscription_id here is therefore only the provider's auth context.
# We use keystone-platform-management for symmetry with the other
# platform layers (and so the same precondition pattern as 00-bootstrap
# applies — if you accidentally run this against a wrong sub, plan fails).

provider "azurerm" {
  subscription_id = var.mgmt_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
