# Azure Firewall Basic + supporting resources.
#
# E2 of platform/30-connectivity. Per ADR-0010, the firewall is
# **on-demand**: it does not exist by default and is brought up only
# during sessions that need it.
#
# Resources here split into two groups:
#
#   - ALWAYS-ON (no count):
#       azurerm_firewall_policy.this
#         Free. Standalone. Survives across up/down cycles so rules
#         don't have to be re-derived every session.
#
#   - CONDITIONAL (count = var.firewall_enabled ? 1 : 0):
#       azurerm_public_ip.fw_data
#       azurerm_public_ip.fw_mgmt
#       azurerm_firewall.this
#         Cost-bearing. Default off → €0 idle. Bring up with
#         `make firewall-up`, tear down with `make firewall-down`.
#
# Cost when running: ~€115/mo (firewall ~€275/mo prorated, 2× PIP
# ~€6.40/mo, data processing negligible at lab volumes).
# Cost when idle:    €0 (all conditional resources removed).

# --- Firewall policy (always-on, free) --------------------------------------
#
# Basic-tier firewall requires a Basic-tier policy. The two SKUs must
# match — you cannot attach a Standard policy to a Basic firewall.
#
# The policy survives across firewall up/down cycles deliberately. When
# rules are added in a later sub-chunk, they live on the policy, so
# they persist while the firewall comes and goes.
resource "azurerm_firewall_policy" "this" {
  name                = "afwp-hub-conn-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location
  sku                 = "Basic"

  tags = var.required_tags
}

# --- Public IPs for the firewall (conditional) ------------------------------
#
# Azure Firewall requires Standard-SKU, Static-allocation public IPs.
# Basic-tier firewalls require TWO PIPs — one for the data plane and
# one for the management plane.
#
# Each up cycle gets *new* PIPs with *new* IP addresses (Static here
# means the IP is fixed for the lifetime of the resource, not across
# resource cycles). ADR-0010 flags this as the main ergonomic cost of
# the on-demand model.

resource "azurerm_public_ip" "fw_data" {
  count = var.firewall_enabled ? 1 : 0

  name                = "pip-afw-data-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  allocation_method = "Static"
  sku               = "Standard"

  tags = var.required_tags
}

resource "azurerm_public_ip" "fw_mgmt" {
  count = var.firewall_enabled ? 1 : 0

  name                = "pip-afw-mgmt-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  allocation_method = "Static"
  sku               = "Standard"

  tags = var.required_tags
}

# --- Firewall (conditional) -------------------------------------------------
#
# Basic tier specifics:
#   - sku_name = "AZFW_VNet" (the only SKU name Basic supports;
#     "AZFW_Hub" is for Virtual WAN deployments, not classic hub-spoke)
#   - sku_tier = "Basic"
#   - management_ip_configuration is REQUIRED for Basic (it's
#     optional/forbidden for Standard depending on context)
#
# Provisioning time: ~10–15 minutes. Use this window to read CAF docs
# or do other lab prep.

resource "azurerm_firewall" "this" {
  count = var.firewall_enabled ? 1 : 0

  name                = "afw-hub-conn-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.hub.name
  location            = azurerm_resource_group.hub.location

  sku_name = "AZFW_VNet"
  sku_tier = "Basic"

  firewall_policy_id = azurerm_firewall_policy.this.id

  ip_configuration {
    name                 = "data"
    subnet_id            = azurerm_subnet.azure_firewall.id
    public_ip_address_id = azurerm_public_ip.fw_data[0].id
  }

  management_ip_configuration {
    name                 = "mgmt"
    subnet_id            = azurerm_subnet.azure_firewall_management.id
    public_ip_address_id = azurerm_public_ip.fw_mgmt[0].id
  }

  tags = var.required_tags
}
