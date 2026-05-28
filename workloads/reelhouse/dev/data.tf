# Data sources for cross-layer reads.

# Hardening pattern (same shape as every platform layer): verify the
# default provider's sub really is lab-foundation before any resource
# is created. Catches a misconfigured KEYSTONE_LAB_FOUNDATION_SUBSCRIPTION_ID
# before it can write into the wrong sub.
data "azurerm_subscription" "workload" {
  subscription_id = var.workload_subscription_id
}

# Read hub VNet ID, hub RG name, hub VNet name, and the central
# Private DNS zone IDs from platform/30-connectivity's outputs.
data "terraform_remote_state" "connectivity" {
  backend = "azurerm"

  config = {
    subscription_id      = var.mgmt_subscription_id
    tenant_id            = var.tenant_id
    resource_group_name  = "rg-tfstate-plat-weu-001"
    storage_account_name = var.state_storage_account_name
    container_name       = "tfstate"
    key                  = "platform-30-connectivity.tfstate"
  }
}
