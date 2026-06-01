# Front Door Standard + WAF (Prevention, custom rules). Public entry point for
# ReelHouse when gateway_enabled. Origin (APIM) and route are wired in Task 7
# once APIM exists. Gated on gateway_enabled. Per ADR-0019.

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
