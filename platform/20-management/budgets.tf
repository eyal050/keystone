# Per-subscription monthly budgets with multi-threshold email alerts.
#
# CLAUDE.md §7 anchors the per-sub thresholds and explicitly requires
# they be Terraform'd rather than clicked. See ADR-0005 for why
# platform-connectivity gets the largest budget (Firewall Basic
# dominates) and the workload subs are sized at €100/mo.
#
# Notification thresholds 10/20/50/80/100 give an early-warning ramp
# rather than a single "you're over budget" panic event:
#   10% — first signal that something is consuming
#   20% — sanity check, normal-month should be on track here
#   50% — halfway, decide if any deallocation is needed
#   80% — last chance to react before the budget is breached
#   100% — over the threshold, time to investigate
#
# Each notification fires both an EMAIL (KEYSTONE_BUDGET_ALERT_EMAIL)
# and an Owner-role alert (anyone with Owner RBAC on the sub gets
# notified). Belt-and-suspenders — even if the email bounces or is
# filtered, the role-based alert still surfaces in the portal.

locals {
  # Monthly budget per Keystone sub, in the MCA billing profile's
  # currency (USD in Eyal's case). CLAUDE.md §7 lists these as €
  # values; USD vs EUR drift is within the precision of these
  # alert-threshold targets.
  budget_amounts = {
    "platform-management"   = 20  # state SA + LAW + cost exports = near-zero realised
    "platform-connectivity" = 900 # Firewall Basic dominates; ADR-0005 cost ceiling
    "platform-identity"     = 20  # custom RBAC + MIs — no continuous-meter resources
    "reelhouse-dev"         = 100 # ACA consumption + Postgres B1ms + workload SA
    "reelhouse-prod"        = 100 # same shape as dev, separated for cost attribution
  }

  budget_thresholds_pct = [10, 20, 50, 80, 100]
}

resource "azurerm_consumption_budget_subscription" "monthly" {
  for_each = data.terraform_remote_state.subscriptions.outputs.subscriptions

  name            = "keystone-${each.key}-monthly"
  subscription_id = "/subscriptions/${data.terraform_remote_state.subscriptions.outputs.subscription_ids[each.key]}"

  amount     = local.budget_amounts[each.key]
  time_grain = "Monthly"

  time_period {
    # Azure requires start_date on the 1st of a month. Use the current
    # billing month — Azure accepts past dates for time_period.start_date.
    start_date = "2026-05-01T00:00:00Z"
    end_date   = "2031-05-01T00:00:00Z" # Azure max is 5y future
  }

  # One notification per threshold. Both contact_emails and
  # contact_roles fire — defence in depth against a missed alert.
  dynamic "notification" {
    for_each = local.budget_thresholds_pct
    content {
      enabled        = true
      threshold      = notification.value
      threshold_type = "Actual" # use "Forecasted" instead to alert on projected end-of-month
      operator       = "GreaterThan"

      contact_emails = [var.budget_alert_email]
      contact_roles  = ["Owner"]
    }
  }

  lifecycle {
    precondition {
      condition     = contains(keys(local.budget_amounts), each.key)
      error_message = "Sub alias '${each.key}' has no entry in local.budget_amounts. Add a budget entry here when a new sub vends, or this for_each fails."
    }
  }
}
