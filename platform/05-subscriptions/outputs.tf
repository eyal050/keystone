# Outputs consumed by:
#   - ~/.keystone/secrets.env (operator copies sub IDs there after apply).
#   - platform/00-bootstrap (reads KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID
#     to know where to put the state SA).
#   - platform/10-management-groups (associates each sub to its target MG).
#   - Subsequent layers via terraform_remote_state.

output "mgmt_subscription_id" {
  description = "Subscription ID (GUID) of keystone-platform-management. Always present (vended in both phase-1 and phase-2)."
  value       = azurerm_subscription.this["platform-management"].subscription_id
  sensitive   = true
}

# Non-sensitive metadata about each vended sub. Keys are aliases
# (e.g. "platform-management") which are not sensitive — they are
# derived from the public subscription names in CLAUDE.md §3.
# This output is consumed by downstream layers' for_each — sensitive
# maps cannot be iterated.
output "subscriptions" {
  description = "Map of sub alias → { name, workload, phase }. Only includes subs actually vended in the current phase. Non-sensitive — for ID lookups use subscription_ids."
  value = {
    for k, v in azurerm_subscription.this : k => {
      name     = v.subscription_name
      workload = v.workload
      phase    = contains(keys(local.phase_1_subs), k) ? "phase-1" : "phase-2"
    }
  }
}

# Sensitive companion to `subscriptions` — separated so downstream
# layers can for_each over the metadata map and look up IDs here.
output "subscription_ids" {
  description = "Map of sub alias → subscription GUID. Sensitive (per Section 6, subscription IDs are tenant-identifying)."
  value = {
    for k, v in azurerm_subscription.this : k => v.subscription_id
  }
  sensitive = true
}

output "vend_phase" {
  description = "Phase reflected by the current state."
  value       = var.vend_phase
}
