# Terraform CI/CD identities for workloads/reelhouse/dev.
#
# Two OIDC-federated user-assigned managed identities run this layer in
# GitHub Actions (CLAUDE.md §5, design spec 2026-05-29):
#
#   - tfplan  (read-only)  — runs `terraform plan` on pull_request
#   - tfapply (read-write) — runs `terraform apply` on push-to-main,
#                            gated behind the `workload-dev` GitHub
#                            Environment.
#
# CHICKEN-AND-EGG: CI cannot create the identity it authenticates as,
# so the FIRST apply of this file is run locally by the operator (same
# pattern as platform/00-bootstrap). Thereafter CI owns the layer.
#
# These identities' OWN role assignments are deliberately NOT in the
# tfapply ABAC allow-list (see locals.rbac_admin_condition) — CI must
# not be able to modify its own privileges. They stay operator/local-
# apply-owned, exactly like operator_kv_admin in keyvault.tf.

# --- Plan identity (read-only) ---------------------------------------------

resource "azurerm_user_assigned_identity" "tfplan" {
  name                = "uami-tfplan-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tags = var.required_tags
}

# Federated to PRs: subject `repo:eyal050/keystone:pull_request`. Any PR
# in the repo can mint this identity's token to run plan — read-only, so
# safe by construction.
resource "azurerm_federated_identity_credential" "tfplan_pr" {
  name                = "github-pull-request"
  resource_group_name = azurerm_resource_group.workload.name
  parent_id           = azurerm_user_assigned_identity.tfplan.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "repo:eyal050/keystone:pull_request"
}

# --- Apply identity (read-write) -------------------------------------------

resource "azurerm_user_assigned_identity" "tfapply" {
  name                = "uami-tfapply-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  tags = var.required_tags
}

# Federated to the `workload-dev` ENVIRONMENT, not a branch. GitHub only
# issues a token with subject `...:environment:workload-dev` AFTER the
# environment's required-reviewer approval passes — so this credential is
# cryptographically unobtainable without the human gate.
resource "azurerm_federated_identity_credential" "tfapply_env" {
  name                = "github-env-workload-dev"
  resource_group_name = azurerm_resource_group.workload.name
  parent_id           = azurerm_user_assigned_identity.tfapply.id

  audience = ["api://AzureADTokenExchange"]
  issuer   = "https://token.actions.githubusercontent.com"
  subject  = "repo:eyal050/keystone:environment:workload-dev"
}
