# Input variables for workloads/reelhouse/dev.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID."
  }
}

variable "workload_subscription_id" {
  description = "Subscription where the workload runs. Today maps to lab-foundation per ADR-0012; will switch to a dedicated `keystone-reelhouse-dev` sub if MCA quota is later raised. Sourced from KEYSTONE_LAB_FOUNDATION_SUBSCRIPTION_ID via TF_VAR_workload_subscription_id."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.workload_subscription_id))
    error_message = "workload_subscription_id must be a valid GUID. Did you source ~/.keystone/secrets.env?"
  }
}

variable "connectivity_subscription_id" {
  description = "keystone-platform-connectivity subscription ID. The aliased connectivity provider authenticates here to create the hub-side peering and the spoke DNS zone links (resources that live in the hub RG even though they reference the spoke VNet)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.connectivity_subscription_id))
    error_message = "connectivity_subscription_id must be a valid GUID."
  }
}

variable "mgmt_subscription_id" {
  description = "keystone-platform-management subscription ID. Used solely for terraform_remote_state config (state SA lives here)."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.mgmt_subscription_id))
    error_message = "mgmt_subscription_id must be a valid GUID."
  }
}

variable "state_storage_account_name" {
  description = "Name of the Terraform state SA in rg-tfstate-plat-weu-001. Used by terraform_remote_state to read platform layer outputs. Sourced from KEYSTONE_STATE_STORAGE_ACCOUNT_NAME."
  type        = string
}

variable "location" {
  description = "Azure region for this workload. ADR-0002 pins westeurope."
  type        = string
  default     = "westeurope"
}

variable "location_short" {
  description = "Short region code used in resource names (ADR-0003)."
  type        = string
  default     = "weu"
}

variable "spoke_address_space" {
  description = "Address space for the reelhouse-dev spoke VNet. Per ADR-0013 the spoke gets 10.20.0.0/20 — non-adjacent to the hub's 10.10.0.0/16 so either can grow without renumbering. /20 = 4096 IPs, plenty for ACA + PE + APIM and future."
  type        = list(string)
  default     = ["10.20.0.0/20"]
}

variable "postgres_enabled" {
  description = "Whether the Postgres Flexible Server + DB + PE + connection-string KV secret exist. Per ADR-0017 the default is OFF — Postgres is brought up only when DB-backed workload features are needed. Provisioning is ~10-15 min on bring-up. Data is lost on destroy (no backup retention)."
  type        = bool
  default     = false
}

variable "workload_pe_enabled" {
  description = "Whether the workload-side private endpoints (KV + Blob) exist. Per ADR-0017 the default is OFF — operator toggles per session. ACA Container App still reaches KV via the public endpoint + RBAC when PE is off; Blob is firewalled to operator IP only and won't be reachable from ACA without its PE."
  type        = bool
  default     = false
}

variable "operator_ip" {
  description = "Operator's current public IP, allowlisted on the workload storage account for ad-hoc portal / az CLI inspection (per ADR-0016). Empty string means no allowlist (PE-only, no operator access). When the operator's residential IP changes, update KEYSTONE_OPERATOR_IP in ~/.keystone/secrets.env and re-apply."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    # Either empty or a valid IPv4 (CIDR added below).
    condition     = var.operator_ip == "" || can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.operator_ip))
    error_message = "operator_ip must be either empty or a bare IPv4 address (no CIDR — /32 is appended by the storage rule)."
  }
}

variable "workload_image" {
  description = "Container image for the ReelHouse API Container App. Defaults to Microsoft's aci-helloworld placeholder so Terraform applies cleanly before the real image exists. Swap with `ghcr.io/eyal050/reelhouse-api:latest` (or wherever you push the built image from `app/api/Dockerfile`) and re-apply once available."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
}

variable "required_tags" {
  description = "Tags applied to every resource in this layer. Environment=dev per ADR-0008 (the policy in 10-management-groups enforces the enum)."
  type        = map(string)
  default = {
    Environment        = "dev"
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
