# Input variables for platform/05-subscriptions.
#
# Sensitive values come from environment variables (TF_VAR_<name>)
# populated by `source ~/.keystone/secrets.env`.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a valid GUID. Did you `source ~/.keystone/secrets.env && export TF_VAR_tenant_id=\"$KEYSTONE_TENANT_ID\"`?"
  }
}

variable "vending_subscription_id" {
  description = "Any existing subscription Eyal has access to in this tenant. Used by the azurerm provider purely as an auth context — subscription vending operates at billing scope, not at this sub. Sourced from KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true

  # See note on mgmt_subscription_id in platform/00-bootstrap/variables.tf —
  # GUID validation catches the empty-falls-through-to-az-default bug class.
  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.vending_subscription_id))
    error_message = "vending_subscription_id must be a valid GUID — empty or malformed values cause the provider to silently use the az CLI default subscription. Did you `source ~/.keystone/secrets.env && export TF_VAR_vending_subscription_id=\"$KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID\"`?"
  }
}

variable "billing_scope_id" {
  description = "MCA invoice section ARM path. New subscriptions are billed against this scope. Sourced from KEYSTONE_MCA_BILLING_SCOPE_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^/providers/Microsoft\\.Billing/billingAccounts/[^/]+/billingProfiles/[^/]+/invoiceSections/[^/]+$", var.billing_scope_id))
    error_message = "billing_scope_id must be a full MCA invoice section ARM path."
  }
}

variable "vend_phase" {
  description = "Which staging phase to apply. \"phase-1\" vends only keystone-platform-management (within current MCA quota). \"phase-2\" vends the remaining four platform/workload subs after the quota ticket is approved. See ADR-0009."
  type        = string
  default     = "phase-1"

  validation {
    condition     = contains(["phase-1", "phase-2"], var.vend_phase)
    error_message = "vend_phase must be either \"phase-1\" or \"phase-2\"."
  }
}
