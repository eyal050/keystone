# Input variables for platform/00-bootstrap.
#
# Sensitive values are sourced from environment variables (TF_VAR_<name>)
# populated by `source ~/.keystone/secrets.env`. Non-sensitive values
# have defaults that match ADR-0002 (region) and ADR-0008 (tags).

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID. Did you `source ~/.keystone/secrets.env && export TF_VAR_tenant_id=\"$KEYSTONE_TENANT_ID\"`?"
  }
}

variable "mgmt_subscription_id" {
  description = "Subscription ID of keystone-platform-management. The state storage account is created here. Sourced from KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID in ~/.keystone/secrets.env (populated after platform/05-subscriptions vends the sub)."
  type        = string
  sensitive   = true

  # This validation catches the 2026-05-21 incident class: an empty
  # TF_VAR_mgmt_subscription_id silently fell through to the azurerm
  # provider's "use az CLI default sub" fallback, creating resources in
  # the wrong subscription. A "not a GUID" error here fails loudly at
  # plan time instead.
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mgmt_subscription_id))
    error_message = "mgmt_subscription_id must be a valid GUID — empty or malformed values cause the provider to silently use the az CLI default subscription. Did you `source ~/.keystone/secrets.env && export TF_VAR_mgmt_subscription_id=\"$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID\"`?"
  }
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
