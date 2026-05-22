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
    # storage accounts that do not enforce HTTPS. Originally assigned
    # as Audit (graduated rollout); promoted to Deny on 2026-05-22
    # after the compliance dashboard showed zero historical violators.
    secure_transfer_storage = "/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9"

    # "Storage accounts should disable public network access" — denies
    # create/update of SAs that have public network access enabled.
    # Effect parameter accepts Audit / Deny / Disabled.
    storage_public_network_access = "/providers/Microsoft.Authorization/policyDefinitions/b2982f36-99f2-4db5-8eff-283140c09693"
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
# Assignment 3: Secure transfer (HTTPS) on storage — Deny (was Audit)
#
# Rolled out 2026-05-21 as Audit at keystone scope. After the
# compliance dashboard's first refresh cycle, no historical SA was
# flagged non-compliant (the only SA at the time was the bootstrap
# state SA, which is HTTPS-only by code). Promoted to Deny on
# 2026-05-22 — this is the graduated-rollout transition the
# original E3 commit message described.
#
# The Azure resource name keeps its "secure-transfer-audit" suffix
# for state stability — renaming would force destroy+recreate of
# the assignment and lose its compliance history. The display_name
# and description reflect the current effect.
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "secure_transfer_storage_audit" {
  name                 = "secure-transfer-audit"
  display_name         = "Storage accounts: secure transfer required (Deny)"
  description          = "Enforces HTTPS-only on storage accounts at keystone scope. Originally rolled out 2026-05-21 as Audit; promoted to Deny on 2026-05-22 after zero historical violators. Resource name retains the -audit suffix for state stability."
  management_group_id  = azurerm_management_group.top.id
  policy_definition_id = local.builtin_policy_ids.secure_transfer_storage

  parameters = jsonencode({
    effect = {
      value = "Deny"
    }
  })
}

# ---------------------------------------------------------------------------
# Assignment 4: Deny public network access on storage — landing zones only
#
# Workload-scope assignment, not platform-scope. The platform state SA
# (rg-tfstate-plat-weu-001/sttfstateplat…) currently has
# public_network_access_enabled = true (with a TODO to tighten once
# 30-connectivity provides a private endpoint). Applying this policy
# at keystone scope would block its own backing storage.
#
# So scope to keystone-landing-zones-corp instead: workload SAs (the
# ReelHouse video blob store, when it lands) must be private-endpoint-
# only from day one. Platform SAs get their own assignment when
# 30-connectivity is in place.
# ---------------------------------------------------------------------------

resource "azurerm_management_group_policy_assignment" "storage_public_network_deny" {
  name                 = "deny-storage-public"
  display_name         = "Storage accounts: public network access denied (workloads)"
  description          = "Denies create/update of storage accounts with public network access enabled, scoped to keystone-landing-zones-corp. Platform SAs are not in scope — the state SA is still public-network-accessible pending 30-connectivity (see TODO in platform/00-bootstrap/main.tf)."
  management_group_id  = azurerm_management_group.landing_zones_corp.id
  policy_definition_id = local.builtin_policy_ids.storage_public_network_access

  parameters = jsonencode({
    effect = {
      value = "Deny"
    }
  })
}
