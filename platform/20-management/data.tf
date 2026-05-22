# Same hardening pattern as 00-bootstrap and 10-management-groups —
# verify the auth-context sub really is keystone-platform-management
# before any resource is created.
data "azurerm_subscription" "mgmt" {
  subscription_id = var.mgmt_subscription_id
}

# Read MG IDs from platform/10-management-groups outputs. The
# diagnostic-settings DfN policy assignment lives in this layer (per
# CLAUDE.md §4 "diagnostic policies" belong to 20-management), but
# its scope is the keystone top-level MG which is owned by layer 10.
data "terraform_remote_state" "management_groups" {
  backend = "azurerm"

  config = {
    subscription_id      = var.mgmt_subscription_id
    tenant_id            = var.tenant_id
    resource_group_name  = "rg-tfstate-plat-weu-001"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "platform-10-management-groups.tfstate"
  }
}
