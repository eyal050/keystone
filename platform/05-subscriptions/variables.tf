# Input variables for platform/05-subscriptions.
#
# Sensitive values come from environment variables (TF_VAR_<name>)
# populated by `source ~/.keystone/secrets.env`.

variable "tenant_id" {
  description = "Microsoft Entra tenant ID. Sourced from KEYSTONE_TENANT_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true
}

variable "vending_subscription_id" {
  description = "Any existing subscription Eyal has access to in this tenant. Used by the azurerm provider purely as an auth context — subscription vending operates at billing scope, not at this sub. Sourced from KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID in ~/.keystone/secrets.env."
  type        = string
  sensitive   = true
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
