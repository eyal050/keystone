# Same hardening pattern as 00-bootstrap and 10-management-groups —
# verify the auth-context sub really is keystone-platform-management
# before any resource is created.
data "azurerm_subscription" "mgmt" {
  subscription_id = var.mgmt_subscription_id
}
