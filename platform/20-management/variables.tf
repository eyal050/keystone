# Input variables for platform/20-management.

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
  description = "keystone-platform-management subscription ID. Sourced from KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mgmt_subscription_id))
    error_message = "mgmt_subscription_id must be a valid GUID. Did you `source ~/.keystone/secrets.env && export TF_VAR_mgmt_subscription_id=\"$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID\"`?"
  }
}

variable "location" {
  description = "Primary Azure region for the lab (ADR-0002)."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "swedencentral"], var.location)
    error_message = "location must be one of: westeurope, northeurope, swedencentral."
  }
}

variable "location_short" {
  description = "Short code for the region used in resource names (ADR-0003)."
  type        = string
  default     = "weu"
}

variable "required_tags" {
  description = "Tags applied to every resource in this layer (ADR-0008)."
  type        = map(string)
  default = {
    Environment        = "platform"
    CostCenter         = "keystone-lab"
    Owner              = "eyal050"
    DataClassification = "internal"
  }

  validation {
    condition = alltrue([
      contains(["platform", "dev", "prod", "sandbox"], var.required_tags["Environment"]),
      var.required_tags["CostCenter"] == "keystone-lab",
      var.required_tags["Owner"] == "eyal050",
      contains(["public", "internal", "confidential", "restricted"], var.required_tags["DataClassification"]),
    ])
    error_message = "required_tags must conform to the enumerated values in ADR-0008."
  }
}

variable "law_retention_in_days" {
  description = "Log Analytics workspace retention in days. 30 is free; 31-730 incur ~€0.10/GB/mo for retained data. Decided 90 in chunk F1 review."
  type        = number
  default     = 90

  validation {
    condition     = var.law_retention_in_days >= 30 && var.law_retention_in_days <= 730
    error_message = "law_retention_in_days must be between 30 and 730 (Azure-imposed bounds)."
  }
}

variable "law_daily_quota_gb" {
  description = "Daily ingestion cap on the LAW in GB. Acts as a circuit-breaker against runaway logging. -1 means uncapped; 1 GB is the lab default and gives a worst-case ceiling of ~€75/mo at PerGB2018 pricing."
  type        = number
  default     = 1
}

variable "state_storage_account_name" {
  description = "Name of the state SA created by platform/00-bootstrap. Required for reading platform/10-management-groups outputs via terraform_remote_state. Sourced from KEYSTONE_STATE_STORAGE_ACCOUNT_NAME."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.state_storage_account_name))
    error_message = "state_storage_account_name must be lowercase alphanumeric, 3-24 chars."
  }
}

variable "budget_alert_email" {
  description = "Recipient email address for per-sub budget threshold alerts (F4). Sourced from KEYSTONE_BUDGET_ALERT_EMAIL — Section 6 marks email addresses as sensitive."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.budget_alert_email))
    error_message = "budget_alert_email must be a valid email address."
  }
}

variable "lab_foundation_subscription_id" {
  description = "Pre-existing `lab-foundation` MCA subscription ID, adopted into keystone-landing-zones-corp per ADR-0012. Empty string means no adoption — graceful on fresh clones / first apply. Sourced from KEYSTONE_LAB_FOUNDATION_SUBSCRIPTION_ID. Required for the budget + cost-export for_each to include the adopted sub."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = var.lab_foundation_subscription_id == "" || can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.lab_foundation_subscription_id))
    error_message = "lab_foundation_subscription_id must be either an empty string or a valid GUID."
  }
}
