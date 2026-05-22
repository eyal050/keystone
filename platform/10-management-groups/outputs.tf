# Outputs consumed by downstream layers via terraform_remote_state.

output "management_group_ids" {
  description = "Map of MG short name → fully-qualified MG resource ID. Downstream layers reference these to scope policy assignments, RBAC role assignments, etc."
  value = {
    top                   = azurerm_management_group.top.id
    platform              = azurerm_management_group.platform.id
    platform_connectivity = azurerm_management_group.platform_connectivity.id
    platform_management   = azurerm_management_group.platform_management.id
    platform_identity     = azurerm_management_group.platform_identity.id
    landing_zones         = azurerm_management_group.landing_zones.id
    landing_zones_corp    = azurerm_management_group.landing_zones_corp.id
    decommissioned        = azurerm_management_group.decommissioned.id
    sandbox               = azurerm_management_group.sandbox.id
  }
}

output "associations" {
  description = "Map of sub alias → MG id where that sub is currently associated."
  value = {
    for k, v in azurerm_management_group_subscription_association.this : k => v.management_group_id
  }
}

output "policy_definition_ids" {
  description = "Map of custom policy definition short name → definition ID. Consumed by E3 (policy assignments) and by any other layer that needs to reference these definitions."
  value = {
    required_tag_enum = azurerm_policy_definition.required_tag_enum.id
  }
}
