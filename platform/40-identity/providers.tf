# Provider configuration for platform/40-identity.
#
# Per ADR-0011 this layer operates from keystone-platform-management
# (Identity collapsed into Management due to MCA quota). Custom RBAC
# role definitions are scoped at MG level — they don't *need* a home
# sub — but Terraform's provider still needs to be authenticated to
# *some* subscription. We use Management for consistency with the
# layer's state file location.

provider "azurerm" {
  subscription_id = var.mgmt_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
