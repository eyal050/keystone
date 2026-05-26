# Input variables for platform/40-identity.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID."
  }
}

variable "mgmt_subscription_id" {
  description = "keystone-platform-management subscription ID. Per ADR-0011 this layer operates from Management because the platform-identity sub was deferred at the MCA quota wall. Sourced from KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mgmt_subscription_id))
    error_message = "mgmt_subscription_id must be a valid GUID. Did you source ~/.keystone/secrets.env?"
  }
}

variable "state_storage_account_name" {
  description = "Name of the Terraform state SA in rg-tfstate-plat-weu-001. Sourced from KEYSTONE_STATE_STORAGE_ACCOUNT_NAME, or resolved from az CLI by the Makefile helper."
  type        = string
}
