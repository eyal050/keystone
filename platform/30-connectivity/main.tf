# Hub network skeleton for the Keystone hub-spoke topology.
#
# E1 of platform/30-connectivity: RG, hub VNet, reserved subnets.
# Subsequent chunks add the firewall (E2), private DNS zones for
# additional services (E3), spoke peering once workloads land (E4).
#
# Subnet layout — IPv4 first /18 of the /16 (room for 64 subnets of /24):
#
#   10.10.0.0/26    AzureFirewallSubnet              (firewall data plane;
#                                                     Azure-mandated name)
#   10.10.0.64/26   AzureFirewallManagementSubnet    (firewall control plane;
#                                                     required by Firewall Basic)
#   10.10.1.0/27    GatewaySubnet                    (VPN / ExpressRoute,
#                                                     future)
#   10.10.2.0/24    snet-default-001                 (placeholder workload
#                                                     subnet; NSG attaches here)
#
# /26 = 64 IPs (Azure reserves 5, so ~59 usable) — adequate for AFW.
# /27 = 32 IPs — adequate for one VPN gateway + ER gateway.

resource "azurerm_resource_group" "hub" {
  name     = "rg-hub-conn-${var.location_short}-001"
  location = var.location

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.azurerm_subscription.conn.display_name == "keystone-platform-connectivity"
      error_message = "var.connectivity_subscription_id resolves to '${data.azurerm_subscription.conn.display_name}' but expected 'keystone-platform-connectivity'. Same incident class as 2026-05-21."
    }
  }
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub-conn-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  address_space = var.hub_address_space

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true
  }
}

# --- Reserved subnets for future firewall + gateway --------------------------

# AzureFirewallSubnet — Azure-imposed name; cannot be renamed. Firewall
# Basic and Standard both require this subnet to be at least /26.
resource "azurerm_subnet" "azure_firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.10.0.0/26"]
}

# AzureFirewallManagementSubnet — required by Firewall Basic (not by
# Standard). Carries the firewall's control-plane traffic. Must also
# be at least /26 and named exactly this.
resource "azurerm_subnet" "azure_firewall_management" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.10.0.64/26"]
}

# GatewaySubnet — Azure-imposed name for ExpressRoute / VPN gateways.
# Reserved now so future VPN work doesn't force a VNet expansion.
resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.10.1.0/27"]
}

# snet-default-001 — placeholder for ad-hoc workload-style testing in
# the hub. Default NSG attaches here (nsg.tf). This is also a useful
# subnet for break/debug experiments — drop a VM in here, then
# observe how policy / NSG / firewall interact.
resource "azurerm_subnet" "default" {
  name                 = "snet-default-001"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.10.2.0/24"]
}
