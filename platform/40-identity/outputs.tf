# Outputs consumed by downstream layers via terraform_remote_state.
# Workload layers reference these when assigning custom roles to
# workload identities.

output "custom_role_definition_ids" {
  description = "Map of custom role short name → fully-qualified role definition resource ID. Downstream layers reference these when creating role assignments."
  value = {
    spoke_network_operator = azurerm_role_definition.spoke_network_operator.role_definition_resource_id
  }
}
