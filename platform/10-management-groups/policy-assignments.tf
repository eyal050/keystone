# Policy assignments at MG scope. Each block declares a single
# assignment — where the policy lives, with which parameters, at what
# effect. Inheritance flows downward: an assignment at keystone (the
# top-level MG) evaluates against every resource in every descendant
# MG and subscription.
#
# Per CLAUDE.md §2, the minimum set to exercise is: allowed locations,
# required tags (custom), require HTTPS on storage, deny public IPs,
# require diagnostic settings. This file covers the first three; the
# remaining two land in E4 (deny-public-network on storage, and the
# DeployIfNotExists for diagnostic settings — both have more moving
# parts).
#
# ---------------------------------------------------------------------------

# Locals: the well-known built-in policy IDs we reference here.
# Built-in policy definitions exist in every Azure tenant by default —
# they don't need a Terraform resource. The ID format is the same for
# all tenants; only assignments are scoped to your hierarchy.
locals {
  builtin_policy_ids = {
    # "Allowed locations" — denies create/update if location is not in
    # the listOfAllowedLocations parameter.
    allowed_locations = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"

    # "Secure transfer to storage accounts should be enabled" — flags
    # storage accounts that do not enforce HTTPS. Built-in default
    # effect is Audit; assignment below leaves it Audit deliberately
    # to demonstrate the graduated-rollout pattern.
    secure_transfer_storage = "/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9"
  }
}

# ---------------------------------------------------------------------------
# Assignment 1: Environment-tag enum (custom)
#
# Uses the keystone-required-tag-enum custom definition to enforce
# Environment ∈ {platform, dev, prod, sandbox} (per ADR-0008).
# Scoped to keystone (top-level) so it inherits everywhere; the
# sandbox MG is exempted via policy-exemptions.tf so experimental
# deploys there are not blocked.
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "environment_tag_enum" {
  name                 = "env-tag-enum"
  display_name         = "Environment tag must be one of platform/dev/prod/sandbox"
  description          = "Enforces ADR-0008's Environment-tag taxonomy at keystone scope. Inheritance applies to every descendant MG and subscription. keystone-sandbox is exempted (see policy-exemptions.tf)."
  management_group_id  = azurerm_management_group.top.id
  policy_definition_id = azurerm_policy_definition.required_tag_enum.id

  parameters = jsonencode({
    tagName = {
      value = "Environment"
    }
    allowedValues = {
      value = ["platform", "dev", "prod", "sandbox"]
    }
    effect = {
      value = "Deny"
    }
  })
}

# ---------------------------------------------------------------------------
# Assignment 2: Allowed locations (built-in)
#
# Restricts every resource to westeurope (per ADR-0002). Scoped to
# keystone so the entire hierarchy inherits. Mode is Indexed (built-in
# default), so resources without a location property (e.g., MGs
# themselves) are unaffected.
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "allowed_locations" {
  name                 = "allowed-locations-weu"
  display_name         = "Allowed locations: westeurope only"
  description          = "Restricts resource creation to westeurope (ADR-0002). Indexed-mode policy — global / location-less resources are not evaluated."
  management_group_id  = azurerm_management_group.top.id
  policy_definition_id = local.builtin_policy_ids.allowed_locations

  parameters = jsonencode({
    listOfAllowedLocations = {
      value = ["westeurope"]
    }
  })
}

# ---------------------------------------------------------------------------
# Assignment 3: Secure transfer (HTTPS) on storage — Audit-only
#
# Built-in policy 404c3081 has only Audit / Deny effects, and its
# parameter is named "effect". This assignment is deliberately Audit
# rather than Deny to demonstrate the graduated-rollout pattern:
#   1. Roll out as Audit at the broadest scope (keystone).
#   2. Watch the compliance dashboard for ~one cycle (24h) to find
#      any historical SAs that violate.
#   3. Flip to Deny by editing the `effect` value here and re-applying.
#
# A new E4 assignment will be added in the next chunk to denyHTTP on
# new SAs at landing-zones-corp scope — different threat model,
# different effect.
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "secure_transfer_storage_audit" {
  name                 = "secure-transfer-audit"
  display_name         = "Storage accounts: secure transfer required (Audit)"
  description          = "Audit-only roll-out of the HTTPS-only requirement for storage accounts. Per CLAUDE.md §2, HTTPS on storage is a required platform-baseline policy; the Audit→Deny transition is itself the lesson."
  management_group_id  = azurerm_management_group.top.id
  policy_definition_id = local.builtin_policy_ids.secure_transfer_storage

  parameters = jsonencode({
    effect = {
      value = "Audit"
    }
  })
}
