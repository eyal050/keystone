# Spoke network for reelhouse-dev. Per ADR-0013, this layer creates:
#
#   - RG, spoke VNet, subnets — in the workload sub.
#   - Spoke-side peering (peer_to_hub) — in the workload sub.
#   - Hub-side peering (hub_to_spoke) — in the connectivity sub (via
#     `provider = azurerm.connectivity`).
#   - Spoke DNS zone links — in the connectivity sub (zones live in
#     the hub RG; links reference the spoke VNet).
#
# Subnet layout (within 10.20.0.0/20):
#
#   10.20.0.0/23    snet-aca-001       (Container Apps env; ACA
#                                       consumption-mode minimum)
#   10.20.2.0/26    snet-pe-001        (Private Endpoints)
#   10.20.3.0/28    snet-apim-001      (API Management, External VNet mode)
#   10.20.4.0/22+   reserved           (future)
#
# Delegations / NSGs / route tables are added when their consumers land
# (ACA needs Microsoft.App/environments delegation, APIM has its own
# requirements). For now, plain subnets.

# --- Resource group in workload sub -----------------------------------------

resource "azurerm_resource_group" "network" {
  # provider = workload (default)
  name     = "rg-reelhouse-dev-net-${var.location_short}-001"
  location = var.location
  tags     = var.required_tags

  lifecycle {
    # Verify the default provider really lands in lab-foundation before
    # creating anything. Mirrors the platform layers' precondition pattern.
    precondition {
      condition     = data.azurerm_subscription.workload.display_name == "lab-foundation"
      error_message = "var.workload_subscription_id resolves to '${data.azurerm_subscription.workload.display_name}' but expected 'lab-foundation'. Per ADR-0012 this layer adopts that sub. Check KEYSTONE_LAB_FOUNDATION_SUBSCRIPTION_ID."
    }
  }
}

# --- Spoke VNet + subnets (workload sub) ------------------------------------

resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  address_space       = var.spoke_address_space

  tags = var.required_tags
}

resource "azurerm_subnet" "aca" {
  name                 = "snet-aca-001"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.20.0.0/23"]

  # Delegation required by `azurerm_container_app_environment.infrastructure_subnet_id`.
  # Azure-mandated action list for ACA env VNet injection.
  delegation {
    name = "Microsoft.App.environments"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-pe-001"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.20.2.0/26"]

  # private_endpoint_network_policies is no longer required as of
  # azurerm 4.x; PE subnets work without disabling network policies.
}

resource "azurerm_subnet" "apim" {
  name                 = "snet-apim-001"
  resource_group_name  = azurerm_resource_group.network.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = ["10.20.3.0/28"]
}

# --- Bidirectional peering --------------------------------------------------
#
# Both sides are independent resources. Terraform creates them in
# parallel; Azure links them via the remote_virtual_network_id pointer.
#
# allow_forwarded_traffic = true on both sides because eventually the
# hub firewall will forward traffic between spokes (when more workloads
# land). For a single-spoke topology today it's a no-op.

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  # provider = workload (default)
  name                      = "peer-to-hub"
  resource_group_name       = azurerm_resource_group.network.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = data.terraform_remote_state.connectivity.outputs.hub_vnet_id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider = azurerm.connectivity

  name                      = "peer-to-reelhouse-dev"
  resource_group_name       = data.terraform_remote_state.connectivity.outputs.hub_resource_group_name
  virtual_network_name      = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  remote_virtual_network_id = azurerm_virtual_network.spoke.id

  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = false
  use_remote_gateways          = false
}

# --- Spoke-side links to central Private DNS zones (connectivity sub) -------
#
# Iterates over the 8 zones exposed by 30-connectivity. Each link is
# named "link-vnet-reelhouse-dev-weu-001" within the corresponding zone.
# This makes the spoke able to resolve every privatelink.* FQDN to the
# private IP of the matching private endpoint — once those PEs exist.

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  provider = azurerm.connectivity

  for_each = data.terraform_remote_state.connectivity.outputs.private_dns_zone_ids

  name                  = "link-${azurerm_virtual_network.spoke.name}"
  resource_group_name   = data.terraform_remote_state.connectivity.outputs.hub_resource_group_name
  private_dns_zone_name = each.key
  virtual_network_id    = azurerm_virtual_network.spoke.id

  registration_enabled = false

  tags = var.required_tags
}
