# Outputs for downstream consumption (future workload sub-layers,
# observability tooling, etc.).

output "spoke_vnet_id" {
  description = "Resource ID of the reelhouse-dev spoke VNet."
  value       = azurerm_virtual_network.spoke.id
}

output "spoke_vnet_name" {
  description = "Name of the reelhouse-dev spoke VNet."
  value       = azurerm_virtual_network.spoke.name
}

output "network_resource_group_name" {
  description = "Resource group containing the spoke VNet and subnets."
  value       = azurerm_resource_group.network.name
}

output "subnet_ids" {
  description = "Map of subnet short name → ARM resource ID. Consumed by future workload resources (ACA env, private endpoints, APIM)."
  value = {
    aca  = azurerm_subnet.aca.id
    pe   = azurerm_subnet.pe.id
    apim = azurerm_subnet.apim.id
  }
}
