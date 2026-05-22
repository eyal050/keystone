# Outputs consumed by F2 (diagnostic-settings policy needs the
# workspace ID as the policyAssignment's workspaceId parameter),
# subsequent platform layers (any DfN diagnostic assignment), and
# the workload layer (its Application Insights gets the same LAW
# as workspace_id).

output "law_id" {
  description = "Resource ID of the platform Log Analytics workspace."
  value       = azurerm_log_analytics_workspace.this.id
}

output "law_workspace_id" {
  description = "Workspace (customer) ID of the LAW — the GUID used by agents and SDKs, not the ARM resource id."
  value       = azurerm_log_analytics_workspace.this.workspace_id
  sensitive   = true
}

output "mgmt_resource_group_name" {
  description = "Resource group hosting the management plane (LAW today; cost export SA + budgets in subsequent chunks)."
  value       = azurerm_resource_group.mgmt.name
}
