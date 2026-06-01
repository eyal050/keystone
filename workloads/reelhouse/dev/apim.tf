# APIM Developer in External VNet mode: public gateway VIP (Front Door origin),
# but VNet-injected into snet-apim-001 so it reaches the internal ACA backend
# over the spoke VNet. Public IP is Azure-managed (optional in External mode).
# Gated on gateway_enabled. Per ADR-0019.
#
# publisher_email is required by APIM and is NOT a secret, but keep personal
# addresses out of this public repo (CLAUDE.md §6) — sourced from a variable
# with a non-personal default.

resource "azurerm_api_management" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "apim-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  publisher_name      = "ReelHouse Lab"
  publisher_email     = var.apim_publisher_email
  sku_name            = "Developer_1"

  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  tags = var.required_tags

  # The APIM subnet NSG association (Task 4) must exist before APIM provisions
  # in External mode.
  depends_on = [azurerm_subnet_network_security_group_association.apim]
}

# Single wildcard pass-through API: all paths proxy to the ACA internal app.
# The Container App's internal ingress FQDN resolves via the per-env private
# DNS zone (aca-dns.tf) from the APIM subnet.
resource "azurerm_api_management_api" "reelhouse" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "reelhouse"
  resource_group_name = azurerm_resource_group.workload.name
  api_management_name = azurerm_api_management.this[0].name
  revision            = "1"
  display_name        = "ReelHouse"
  path                = ""
  protocols           = ["https"]
  service_url         = "https://${azurerm_container_app.api.ingress[0].fqdn}"

  # Front Door does not inject an APIM subscription key, so requests would 401
  # if a subscription were required. The FD-only lockdown (NSG + X-Azure-FDID)
  # is the access control here, not APIM subscriptions. Per ADR-0019.
  subscription_required = false
}

resource "azurerm_api_management_api_operation" "wildcard" {
  count               = var.gateway_enabled ? 1 : 0
  operation_id        = "wildcard"
  api_name            = azurerm_api_management_api.reelhouse[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.workload.name
  display_name        = "Wildcard"
  method              = "*"
  url_template        = "/*"
  description         = "Catch-all proxy to the ReelHouse ACA backend."
}

# Inbound API policy:
#   1. check-header X-Azure-FDID == this Front Door's ID (lockdown layer 2 —
#      pins to THIS FD instance; the AzureFrontDoor.Backend NSG tag is shared
#      across all tenants). Per ADR-0019.
#   2. rate-limit-by-key — demonstrable gateway policy.
resource "azurerm_api_management_api_policy" "reelhouse" {
  count               = var.gateway_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.reelhouse[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.workload.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Direct access is not allowed." ignore-case="true">
      <value>${azurerm_cdn_frontdoor_profile.this[0].resource_guid}</value>
    </check-header>
    <rate-limit-by-key calls="100" renewal-period="60" counter-key="@(context.Request.IpAddress)" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
XML
}
