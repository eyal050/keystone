# Subscription-to-MG associations.
#
# Reads the list of currently-vended subs from platform/05-subscriptions
# via terraform_remote_state. The iteration set is `subscriptions` (the
# non-sensitive metadata map); the actual sub IDs come from the sensitive
# `subscription_ids` companion map.
#
# Phase 1: only "platform-management" appears → 1 association created.
# Phase 2: 4 more subs land → 5 associations total.
#
# The local.sub_alias_to_mg map declares the target MG for every alias
# the project knows about. If 05-subscriptions ever adds a new alias
# without a corresponding entry here, plan fails with a clear "no entry
# for alias X" lookup error — better than a silent association into
# an unintended MG.

locals {
  sub_alias_to_mg = {
    "platform-management"   = azurerm_management_group.platform_management.id
    "platform-connectivity" = azurerm_management_group.platform_connectivity.id
    "platform-identity"     = azurerm_management_group.platform_identity.id
    "reelhouse-dev"         = azurerm_management_group.landing_zones_corp.id
    "reelhouse-prod"        = azurerm_management_group.landing_zones_corp.id
  }
}

resource "azurerm_management_group_subscription_association" "this" {
  for_each = data.terraform_remote_state.subscriptions.outputs.subscriptions

  management_group_id = local.sub_alias_to_mg[each.key]
  subscription_id     = "/subscriptions/${data.terraform_remote_state.subscriptions.outputs.subscription_ids[each.key]}"

  lifecycle {
    # Belt-and-suspenders: if 05-subscriptions ever vends a sub with an
    # alias we have not mapped (e.g., someone added "reelhouse-staging"
    # in 05/locals.tf without updating local.sub_alias_to_mg here),
    # for_each lookup fails earlier — but this precondition explains
    # the failure with an actionable error.
    precondition {
      condition     = contains(keys(local.sub_alias_to_mg), each.key)
      error_message = "Sub alias '${each.key}' has no entry in local.sub_alias_to_mg. Update associations.tf to declare which MG this sub should land under."
    }
  }
}
