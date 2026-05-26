# Same hardening pattern as 00-bootstrap, 10-management-groups,
# 20-management — verify the auth-context sub really is
# keystone-platform-management before any resource is created.
# Catches a misconfigured provider before it can write to the wrong sub.
data "azurerm_subscription" "mgmt" {
  subscription_id = var.mgmt_subscription_id
}

# Read MG IDs from platform/10-management-groups outputs. Custom role
# definitions in this layer are scoped at MG level, and assignable
# scopes also reference MG IDs.
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
