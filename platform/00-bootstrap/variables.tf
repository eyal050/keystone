# Input variables for platform/00-bootstrap.
#
# Sensitive values are sourced from environment variables (TF_VAR_<name>)
# populated by `source ~/.keystone/secrets.env`. Non-sensitive values
# have defaults that match ADR-0002 (region) and ADR-0008 (tags).

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true
}

variable "mgmt_subscription_id" {
  description = "Subscription ID of keystone-platform-management. The state storage account is created here. Sourced from KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID in ~/.keystone/secrets.env (populated after platform/05-subscriptions vends the sub)."
  type        = string
  sensitive   = true
}

variable "location" {
  description = "Primary Azure region for the lab. See ADR-0002."
  type        = string
  default     = "westeurope"

  validation {
    condition     = contains(["westeurope", "northeurope", "swedencentral"], var.location)
    error_message = "location must be one of: westeurope, northeurope, swedencentral."
  }
}

variable "location_short" {
  description = "Short code for the location used in resource names. See ADR-0003."
  type        = string
  default     = "weu"

  validation {
    condition     = length(var.location_short) <= 4
    error_message = "location_short must be at most 4 characters."
  }
}

variable "required_tags" {
  description = "Tags applied to every resource created by this layer. See ADR-0008."
  type        = map(string)
  default = {
    Environment        = "platform"
    CostCenter         = "keystone-lab"
    Owner              = "eyal050"
    DataClassification = "restricted"
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
