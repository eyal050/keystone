# Input variables for platform/30-connectivity.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID."
  }
}

variable "connectivity_subscription_id" {
  description = "keystone-platform-connectivity subscription ID. Vended in Phase 2 of platform/05-subscriptions; until then this variable has nothing to point at. Sourced from KEYSTONE_PLATFORM_CONNECTIVITY_SUBSCRIPTION_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.connectivity_subscription_id))
    error_message = "connectivity_subscription_id must be a valid GUID. Did you `source ~/.keystone/secrets.env && export TF_VAR_connectivity_subscription_id=\"$KEYSTONE_PLATFORM_CONNECTIVITY_SUBSCRIPTION_ID\"`?"
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
  description = "Short region code used in resource names (ADR-0003)."
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

variable "hub_address_space" {
  description = "Address space for the hub VNet. /16 gives plenty of room for firewall, management, gateway, and a half-dozen workload-test subnets."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "firewall_enabled" {
  description = "Whether the Azure Firewall and its public IPs exist. Per ADR-0010 the firewall is on-demand: default is false (€0 idle cost). Toggle via `make firewall-up` / `make firewall-down`, which call `terraform apply -var=firewall_enabled=true|false`. The firewall policy stays in state regardless."
  type        = bool
  default     = false
}
