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

output "subscriptions" {
  description = "Map of sub alias → { id, name, workload, phase }. Only includes subs actually vended in the current phase."
  value = {
    for k, v in azurerm_subscription.this : k => {
      id       = v.subscription_id
      name     = v.subscription_name
      workload = v.workload
      phase    = contains(keys(local.phase_1_subs), k) ? "phase-1" : "phase-2"
    }
  }
  sensitive = true
}

output "vend_phase" {
  description = "Phase reflected by the current state."
  value       = var.vend_phase
}
