# Keystone management-group hierarchy. Hand-rolled per ADR-0004:
# each MG is an explicit resource so every line is something Eyal
# authored and can defend in an interview.
#
# Hierarchy (also documented in CLAUDE.md §2 and docs/subscription-topology.md):
#
#   Tenant Root
#   └── keystone
#       ├── keystone-platform
#       │   ├── keystone-platform-connectivity
#       │   ├── keystone-platform-management
#       │   └── keystone-platform-identity
#       ├── keystone-landing-zones
#       │   └── keystone-landing-zones-corp
#       ├── keystone-decommissioned
#       └── keystone-sandbox
#
# parent_management_group_id wiring builds the tree. Subscription
# associations live in associations.tf (driven by remote state from
# platform/05-subscriptions, so they appear as subs are vended).

# --- Top of hierarchy ------------------------------------------------------

resource "azurerm_management_group" "top" {
  name         = "keystone"
  display_name = "Keystone (Top-Level)"

  lifecycle {
    precondition {
      condition     = data.azurerm_subscription.mgmt.display_name == "keystone-platform-management"
      error_message = "var.mgmt_subscription_id resolves to '${data.azurerm_subscription.mgmt.display_name}' but expected 'keystone-platform-management'. Same incident class as 2026-05-21."
    }
  }
}

# --- Platform branch -------------------------------------------------------

resource "azurerm_management_group" "platform" {
  name                       = "keystone-platform"
  display_name               = "Platform"
  parent_management_group_id = azurerm_management_group.top.id
}

resource "azurerm_management_group" "platform_connectivity" {
  name                       = "keystone-platform-connectivity"
  display_name               = "Platform — Connectivity"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "platform_management" {
  name                       = "keystone-platform-management"
  display_name               = "Platform — Management"
  parent_management_group_id = azurerm_management_group.platform.id
}

resource "azurerm_management_group" "platform_identity" {
  name                       = "keystone-platform-identity"
  display_name               = "Platform — Identity"
  parent_management_group_id = azurerm_management_group.platform.id
}

# --- Landing Zones branch --------------------------------------------------

resource "azurerm_management_group" "landing_zones" {
  name                       = "keystone-landing-zones"
  display_name               = "Landing Zones"
  parent_management_group_id = azurerm_management_group.top.id
}

# Corp = internal-only workloads. CAF also defines an `online` sibling
# for internet-facing workloads — out of scope for this lab (per CLAUDE.md §2).
resource "azurerm_management_group" "landing_zones_corp" {
  name                       = "keystone-landing-zones-corp"
  display_name               = "Landing Zones — Corp"
  parent_management_group_id = azurerm_management_group.landing_zones.id
}

# --- Lifecycle MGs ---------------------------------------------------------

# Subscriptions ready to be cancelled get moved here first — keeps the
# active hierarchy clean and gives Cost Management one place to watch
# for residual spend during the 90-day MCA cancellation window.
resource "azurerm_management_group" "decommissioned" {
  name                       = "keystone-decommissioned"
  display_name               = "Decommissioned"
  parent_management_group_id = azurerm_management_group.top.id
}

# Scratch space for experimentation. Carries the loosest policy posture
# of any MG (Audit instead of Deny on most assignments) — to be wired
# up in a later chunk when policy lands.
resource "azurerm_management_group" "sandbox" {
  name                       = "keystone-sandbox"
  display_name               = "Sandbox"
  parent_management_group_id = azurerm_management_group.top.id
}
