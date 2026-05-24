# Outputs consumed by downstream layers via terraform_remote_state.
# Spoke VNets in the workload layer link to these zones; private
# endpoints in any layer create A records inside them.

output "hub_vnet_id" {
  description = "Resource ID of the hub VNet. Spokes peer to this."
  value       = azurerm_virtual_network.hub.id
}

output "hub_vnet_name" {
  description = "Name of the hub VNet (used in DNS zone link naming)."
  value       = azurerm_virtual_network.hub.name
}

output "hub_resource_group_name" {
  description = "Resource group holding the hub VNet, NSG, and DNS zones."
  value       = azurerm_resource_group.hub.name
}

output "subnet_ids" {
  description = "Map of subnet short name → ARM resource ID. Firewall and gateway subnets are reserved for those resources by Azure-imposed naming."
  value = {
    azure_firewall            = azurerm_subnet.azure_firewall.id
    azure_firewall_management = azurerm_subnet.azure_firewall_management.id
    gateway                   = azurerm_subnet.gateway.id
    default                   = azurerm_subnet.default.id
  }
}

output "private_dns_zone_ids" {
  description = "Map of platform-side private DNS zone name → resource ID. Workload layers reference these when creating private endpoints with private_dns_zone_group blocks."
  value = {
    for k, v in azurerm_private_dns_zone.platform : k => v.id
  }
}
