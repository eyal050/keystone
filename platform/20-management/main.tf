# Management plane: Log Analytics workspace + its resource group.
#
# F1 of platform/20-management. Subsequent chunks add the
# DeployIfNotExists diagnostic-settings policy (F2 — the CLAUDE.md
# §8 break/debug scenario), MCA cost data export (F3), and
# per-subscription budget alerts (F4).

resource "azurerm_resource_group" "mgmt" {
  name     = "rg-platmgmt-${var.location_short}-001"
  location = var.location

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.azurerm_subscription.mgmt.display_name == "keystone-platform-management"
      error_message = "var.mgmt_subscription_id resolves to '${data.azurerm_subscription.mgmt.display_name}' but expected 'keystone-platform-management'. Same incident class as 2026-05-21."
    }
  }
}

# Log Analytics workspace — the destination for every diagnostic
# setting across Keystone subs. SKU PerGB2018 is the only Azure
# Monitor billing SKU at this point; older tiers (Free, Standalone,
# Per Node) are deprecated.
#
# Cost shape: consumption-only. ~€2.50/GB ingested in westeurope.
# Retention beyond 30 days adds ~€0.10/GB/mo for retained data.
# daily_quota_gb caps the worst case to ~€75/mo even if a runaway
# logger floods the workspace.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-platmgmt-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = azurerm_resource_group.mgmt.location

  sku               = "PerGB2018"
  retention_in_days = var.law_retention_in_days
  daily_quota_gb    = var.law_daily_quota_gb

  # Internet ingestion + query are intentionally enabled today.
  # Tighten when platform/30-connectivity lands the workspace's
  # private endpoint and DNS, mirroring the same TODO on the state
  # SA in platform/00-bootstrap/main.tf.
  internet_ingestion_enabled = true
  internet_query_enabled     = true

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true
  }
}
