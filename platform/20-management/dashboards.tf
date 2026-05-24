# Azure dashboards for the Keystone lab.
#
# Two complementary surfaces:
#
#   1. azurerm_application_insights_workbook  — interactive multi-section
#      report with KQL via Azure Resource Graph. Lives under Monitor →
#      Workbooks. Best for "show me a table / chart, let me drill in."
#
#   2. azurerm_portal_dashboard               — tile-based at-a-glance
#      view. Lives under the portal Dashboard hub. Best for "what's the
#      state of the world right now?"
#
# Both are €0/mo. Resource Graph queries are free; the dashboard
# resources themselves have no continuous-meter cost.
#
# After apply:
#   - Workbook is reachable via Portal → Monitor → Workbooks →
#     scope = log-platmgmt-weu-001 → "Keystone — Overview".
#   - Portal dashboard appears under Portal → Dashboard hub →
#     "Keystone — Overview" (shared dashboards visible to anyone with
#     Reader on this resource group).

# ----------------------------------------------------------------------------
# 1. Workbook (KQL via Azure Resource Graph)
# ----------------------------------------------------------------------------

# Workbook names in Azure are GUIDs. Generate one deterministically from
# the workbook's logical name so re-creating the resource doesn't change it.
locals {
  workbook_overview_name = uuidv5("dns", "keystone.overview.workbook")
}

resource "azurerm_application_insights_workbook" "overview" {
  name                = local.workbook_overview_name
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = azurerm_resource_group.mgmt.location

  display_name = "Keystone — Overview"
  description  = "Cross-subscription resource inventory + policy + diagnostic-settings coverage for the Keystone ESLZ lab. Resource Graph queries (free)."

  # source_id binds the workbook to a "scope" — here, the platform LAW.
  # Workbooks listed under Monitor → Workbooks with this LAW selected.
  # Lowercased because the API normalizes IDs to lowercase and we'd get
  # perpetual drift otherwise.
  source_id = lower(azurerm_log_analytics_workspace.this.id)

  category = "workbook"

  # Content lives in a sibling JSON file for readability. file() reads
  # it as a string; the resource expects data_json to be a string of
  # serialized workbook content.
  data_json = file("${path.module}/workbooks/keystone-overview.json")

  tags = var.required_tags
}

# ----------------------------------------------------------------------------
# 2. Portal Dashboard (tile-based)
# ----------------------------------------------------------------------------

# Building the dashboard in HCL via jsonencode() rather than a sibling JSON
# file: the structure has a lot of repetition (tile positions, metadata
# wrappers) and HCL with jsonencode is easier to read and edit than raw
# JSON with escaped newlines inside query strings.

locals {
  # Common ARG (Azure Resource Graph) query fragment: subs under keystone MG.
  _subs_under_keystone = "resourcecontainers | where type == 'microsoft.resources/subscriptions' | where properties.managementGroupAncestorsChain has 'keystone'"

  dashboard_overview_lenses = {
    "0" = {
      order = 0
      parts = {
        # Tile (0,0): Markdown header, full width
        "0" = {
          position = { x = 0, y = 0, rowSpan = 2, colSpan = 12 }
          metadata = {
            type = "Extension/HubsExtension/PartType/MarkdownPart"
            settings = {
              content = {
                settings = {
                  content        = "## Keystone — Overview\n\n_At-a-glance view. For interactive analysis open the [**Keystone — Overview workbook**](https://portal.azure.com/#view/Microsoft_Azure_MonitoringMetrics/Workbook.ReactView) under Monitor → Workbooks._"
                  title          = ""
                  subtitle       = ""
                  markdownSource = 1
                }
              }
            }
          }
        }

        # Tile (0,2): Subscriptions under keystone MG (ARG grid)
        "1" = {
          position = { x = 0, y = 2, rowSpan = 4, colSpan = 6 }
          metadata = {
            type = "Extension/HubsExtension/PartType/ArgQueryGridTile"
            inputs = [
              {
                name  = "query"
                value = "${local._subs_under_keystone} | project Subscription = name, State = tostring(properties.state)"
              },
              { name = "selectedSubscriptions", value = [] },
            ]
            settings = {
              content = { PartTitle = "Subscriptions under keystone MG" }
            }
          }
        }

        # Tile (6,2): Resource count by subscription (ARG bar chart)
        "2" = {
          position = { x = 6, y = 2, rowSpan = 4, colSpan = 6 }
          metadata = {
            type = "Extension/HubsExtension/PartType/ArgQueryChartTile"
            inputs = [
              {
                name  = "query"
                value = "resources | join kind=inner (${local._subs_under_keystone} | project subscriptionId, SubName = name) on subscriptionId | summarize Resources = count() by Subscription = SubName | order by Resources desc"
              },
              { name = "chartType", value = "bar" },
              { name = "isShared", value = true },
              { name = "selectedSubscriptions", value = [] },
            ]
            settings = {
              content = { PartTitle = "Resource count by subscription" }
            }
          }
        }

        # Tile (0,6): All resources under keystone MG (ARG grid, full width)
        "3" = {
          position = { x = 0, y = 6, rowSpan = 5, colSpan = 12 }
          metadata = {
            type = "Extension/HubsExtension/PartType/ArgQueryGridTile"
            inputs = [
              {
                name  = "query"
                value = "resources | join kind=inner (${local._subs_under_keystone} | project subscriptionId, SubName = name) on subscriptionId | project Name = name, Type = type, Location = location, ResourceGroup = resourceGroup, Subscription = SubName | order by Subscription asc, ResourceGroup asc, Name asc"
              },
              { name = "selectedSubscriptions", value = [] },
            ]
            settings = {
              content = { PartTitle = "All resources under keystone MG" }
            }
          }
        }

        # Tile (0,11): Markdown footer with Cost Management deep-links
        "4" = {
          position = { x = 0, y = 11, rowSpan = 3, colSpan = 12 }
          metadata = {
            type = "Extension/HubsExtension/PartType/MarkdownPart"
            settings = {
              content = {
                settings = {
                  content        = "### Cost views (open in Cost Management)\n\nResource Graph doesn't expose Cost Management data. Cost views live in Cost Management's own UI — these deep-links pre-scope to `keystone` MG:\n\n- **[Cost by subscription (MTD)](https://portal.azure.com/#view/Microsoft_Azure_CostManagement/Menu/~/costanalysis/scope/%2Fproviders%2FMicrosoft.Management%2FmanagementGroups%2Fkeystone)** — default view, change group-by dropdown for slice.\n- **Cost by resource** — same link, then change the *Group by* dropdown to **ResourceId**.\n- **Cost by service** — same link, *Group by* → **ServiceName**.\n\nProgrammatic / CLI: `scripts/cost-snapshot.sh` from the repo."
                  title          = ""
                  subtitle       = ""
                  markdownSource = 1
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "azurerm_portal_dashboard" "overview" {
  name                = "keystone-overview-${var.location_short}"
  resource_group_name = azurerm_resource_group.mgmt.name
  location            = azurerm_resource_group.mgmt.location

  # The dashboard_properties field expects the full `properties` object of
  # a Microsoft.Portal/dashboards resource, serialized to JSON.
  dashboard_properties = jsonencode({
    lenses   = local.dashboard_overview_lenses
    metadata = { model = {} }
  })

  tags = var.required_tags
}
