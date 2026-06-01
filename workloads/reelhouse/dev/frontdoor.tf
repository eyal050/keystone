# Front Door Standard + WAF (Prevention, custom rules). Public entry point for
# ReelHouse when gateway_enabled. This file also wires the APIM origin + route
# (below); the APIM gateway host is referenced by name, not resource attribute,
# to avoid a dependency cycle (APIM depends on the FD profile's resource_guid).
# Gated on gateway_enabled. Per ADR-0019.

resource "azurerm_cdn_frontdoor_profile" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "afd-reelhouse-dev-001"
  resource_group_name = azurerm_resource_group.workload.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.required_tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "fde-reelhouse-dev-001"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id
  tags                     = var.required_tags
}

# WAF — Prevention, CUSTOM rules only (Standard tier can't use managed DRS).
# One rule blocks common SQLi patterns in the query string — demonstrates WAF
# blocking. Rate-limiting is handled at APIM, not duplicated here.
resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "wafreelhousedev001" # alphanumeric only
  resource_group_name = azurerm_resource_group.workload.name
  sku_name            = "Standard_AzureFrontDoor"
  enabled             = true
  mode                = "Prevention"

  custom_rule {
    name     = "BlockSqliPatterns"
    enabled  = true
    priority = 100
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "QueryString"
      operator           = "Contains"
      negation_condition = false
      # Lowercase transform applied → keep match_values lowercase.
      match_values = ["drop table", "union select", "' or ", "--", ";--"]
      transforms   = ["Lowercase", "UrlDecode"]
    }
  }

  tags = var.required_tags
}

# Bind the WAF policy to the endpoint host.
resource "azurerm_cdn_frontdoor_security_policy" "this" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "secpol-reelhouse-dev-001"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this[0].id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this[0].id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}

resource "azurerm_cdn_frontdoor_origin_group" "apim" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "og-apim"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  load_balancing {}

  health_probe {
    interval_in_seconds = 100
    path                = "/status-0123456789abcdef" # APIM default health endpoint
    protocol            = "Https"
    request_type        = "GET"
  }
}

# Origin = APIM's public gateway hostname. FD reaches APIM over the internet
# (Standard FD can't use a private origin); the NSG + X-Azure-FDID header keep
# APIM reachable only through THIS Front Door. The gateway host is deterministic
# (<apim-name>.azure-api.net), referenced by name to avoid a dependency cycle
# with the FD profile (APIM already depends on the FD profile's resource_guid).
resource "azurerm_cdn_frontdoor_origin" "apim" {
  count                          = var.gateway_enabled ? 1 : 0
  name                           = "origin-apim"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.apim[0].id
  enabled                        = true
  certificate_name_check_enabled = true

  host_name          = "apim-reelhouse-dev-${var.location_short}-001.azure-api.net"
  origin_host_header = "apim-reelhouse-dev-${var.location_short}-001.azure-api.net"
  https_port         = 443
  http_port          = 80
  priority           = 1
  weight             = 1
}

resource "azurerm_cdn_frontdoor_route" "default" {
  count                         = var.gateway_enabled ? 1 : 0
  name                          = "route-default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.apim[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.apim[0].id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
}
