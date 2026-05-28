# MCA cost data export, one per Keystone-vended subscription.
#
# CLAUDE.md §3 calls for a daily cost data export to a storage account
# in keystone-platform-management, queryable with Kusto. This file
# wires that up at SUBSCRIPTION scope (one export per vended sub)
# rather than at MCA billing-profile scope, because:
#
#   - The azurerm provider only ships subscription/RG/MG-scoped cost
#     management export resources. Billing-profile-scoped exports
#     require azapi or raw REST calls.
#
#   - Per-sub exports give per-sub blobs, which is exactly the shape
#     downstream Kusto / Azure Monitor queries want anyway. The MCA
#     billing-profile export is one big undifferentiated dump; you
#     end up grouping by SubscriptionName in queries to do what
#     per-sub exports give you for free.
#
# As more subs vend in Phase 2 of ADR-0009, the for_each over the
# 05-subscriptions output map picks them up automatically — no code
# change needed here.

# Cost data destination: a new container alongside the tfstate container
# in the existing state SA. Conceptual separation; physical co-location
# is fine because access is RBAC-scoped at the container level.
resource "azurerm_storage_container" "cost_exports" {
  name                  = "cost-exports"
  storage_account_id    = data.azurerm_storage_account.tfstate.id
  container_access_type = "private"
}

# One daily export per vended sub. for_each iterates the non-sensitive
# subscriptions map; sub GUIDs come from the sensitive subscription_ids
# companion (Terraform allows sensitive values inside resource attributes,
# just not as for_each keys).
resource "azurerm_subscription_cost_management_export" "monthly" {
  for_each = local.all_subscriptions

  name            = "keystone-${each.key}-mtd"
  subscription_id = "/subscriptions/${local.all_subscription_ids[each.key]}"

  recurrence_type = "Daily"

  # Microsoft's cost-export API rejects `recurrence_period_start_date` if
  # it's in the past at the moment of CREATE. A hardcoded literal therefore
  # rots: it works on the day it's written, then breaks the next sub vend.
  # See docs/break-debug-log.md 2026-05-25.
  #
  # Use "tomorrow at midnight UTC" so the value is unambiguously in the
  # future regardless of what time of day apply runs. Paired with
  # `ignore_changes` below so `timestamp()`'s impurity doesn't cause
  # permadrift on existing exports.
  recurrence_period_start_date = formatdate("YYYY-MM-DD'T'00:00:00'Z'", timeadd(timestamp(), "24h"))
  recurrence_period_end_date   = "2031-05-22T00:00:00Z" # Azure caps at 5 years
  active                       = true

  export_data_storage_location {
    container_id     = azurerm_storage_container.cost_exports.id
    root_folder_path = each.key
  }

  export_data_options {
    type       = "ActualCost"
    time_frame = "MonthToDate"
  }

  lifecycle {
    # `recurrence_period_start_date` uses timestamp() — re-evaluated every
    # plan. Without this, every plan would show a diff for every existing
    # export. The start date is only meaningful at create time anyway.
    ignore_changes = [recurrence_period_start_date]
  }
}
