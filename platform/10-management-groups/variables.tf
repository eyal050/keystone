# Input variables for platform/10-management-groups.

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
  description = "keystone-platform-management subscription ID. Used as the provider's auth context (this layer creates tenant-scoped resources). Sourced from KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mgmt_subscription_id))
    error_message = "mgmt_subscription_id must be a valid GUID. Did you `source ~/.keystone/secrets.env && export TF_VAR_mgmt_subscription_id=\"$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID\"`?"
  }
}

variable "state_storage_account_name" {
  description = "Name of the Terraform state SA created by platform/00-bootstrap. Used in the terraform_remote_state config for reading 05-subscriptions outputs. Sourced from KEYSTONE_STATE_STORAGE_ACCOUNT_NAME."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.state_storage_account_name))
    error_message = "state_storage_account_name must be lowercase alphanumeric, 3-24 chars (Azure SA name constraint)."
  }
}

variable "lab_foundation_subscription_id" {
  description = "Pre-existing `lab-foundation` MCA subscription ID, adopted into keystone-landing-zones-corp per ADR-0012. Empty string means no adoption — graceful on fresh clones / first apply. Sourced from KEYSTONE_LAB_FOUNDATION_SUBSCRIPTION_ID."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.lab_foundation_subscription_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.lab_foundation_subscription_id))
    error_message = "lab_foundation_subscription_id must be either an empty string or a valid GUID."
  }
}
