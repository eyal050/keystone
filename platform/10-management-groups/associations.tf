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

# --- Adopted subscriptions (brownfield onboarding per ADR-0012) -------------
#
# Pre-existing subs that Terraform did not vend, brought under the
# Keystone MG hierarchy. Declarative MG association preserves drift
# visibility: any portal-side move shows up as a `terraform plan`
# delta to reconcile.
#
# Today the only adopted sub is `lab-foundation`, hosting the
# ReelHouse workload. If more adopted subs land, add a sibling
# entry to the local map.

locals {
  # `length(sensitive_var) > 0` is itself marked sensitive by Terraform
  # because it's derived from a sensitive value — even though "is the
  # var populated" is not itself sensitive. nonsensitive() explicitly
  # downgrades just this boolean so it can flow into for_each / count
  # without leaking the underlying GUID. The sensitive GUID itself
  # never crosses this barrier.
  adoption_enabled = nonsensitive(length(var.lab_foundation_subscription_id) > 0)

  # Non-sensitive metadata — used as the for_each key set. Sub IDs are
  # sensitive (CLAUDE.md §6) and Terraform won't accept sensitive
  # values as for_each keys (the key would appear in resource
  # addresses, leaking the ID). Same split-shape as 05-subscriptions:
  # non-sensitive metadata in one map, sensitive IDs in a companion.
  adopted_subscriptions = local.adoption_enabled ? {
    "lab-foundation" = {
      management_group_id = azurerm_management_group.landing_zones_corp.id
    }
  } : {}

  # Sensitive — looked up by alias inside the resource body.
  adopted_subscription_ids = local.adoption_enabled ? {
    "lab-foundation" = var.lab_foundation_subscription_id
  } : {}
}

resource "azurerm_management_group_subscription_association" "adopted" {
  for_each = local.adopted_subscriptions

  management_group_id = each.value.management_group_id
  subscription_id     = "/subscriptions/${local.adopted_subscription_ids[each.key]}"
}
