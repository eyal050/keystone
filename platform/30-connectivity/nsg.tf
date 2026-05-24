# Default NSG attached to snet-default-001.
#
# Azure NSGs have implicit default rules that already deny inbound
# from internet, allow inbound from VNet, and allow outbound to
# internet. So an "empty" NSG already enforces a sensible baseline.
# Defining custom rules here is left for later chunks — once the
# firewall is in place, the egress-via-firewall pattern is enforced
# by UDR + (optionally) explicit NSG deny rules.
#
# AzureFirewallSubnet, AzureFirewallManagementSubnet, and GatewaySubnet
# cannot have NSGs (Azure constraint). Only snet-default-001 gets
# this association.

resource "azurerm_network_security_group" "default" {
  name                = "nsg-default-hub-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  tags = var.required_tags
}

resource "azurerm_subnet_network_security_group_association" "default" {
  subnet_id                 = azurerm_subnet.default.id
  network_security_group_id = azurerm_network_security_group.default.id
}
