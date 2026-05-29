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

# --- ABAC allow-list for the apply identity's RBAC-admin grant -------------

locals {
  # App-plane roles the layer grants to application principals (app-deploy
  # UAMI + ACA managed identity). The tfapply identity may write/delete role
  # assignments ONLY for these. RBAC-admin / Owner / Key Vault Administrator
  # are intentionally absent → no privilege escalation, and CI cannot touch
  # operator grants or its own grants. GUIDs are public Azure built-in role
  # IDs (https://learn.microsoft.com/azure/role-based-access-control/built-in-roles).
  cicd_allowed_role_guids = [
    "7f951dda-4ed3-4680-a7ca-43fe172d538d", # AcrPull
    "8311e382-0749-4cb8-b61a-304f252e45ec", # AcrPush
    "b24988ac-6180-42a0-ab88-20f7382dd24c", # Contributor
    "4633458b-17de-408a-b874-0445c86b69e6", # Key Vault Secrets User
    "ba92f5b4-2d11-453d-a403-e96b0029c9fe", # Storage Blob Data Contributor
  ]

  cicd_role_guids_csv = join(", ", local.cicd_allowed_role_guids)

  # Write checks @Request, delete checks @Resource — Microsoft's documented
  # "constrain roles" pattern for delegating role-assignment management.
  rbac_admin_condition = <<-COND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
     )
     OR
     (
      @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.cicd_role_guids_csv}}
     )
    )
    AND
    (
     (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
     )
     OR
     (
      @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${local.cicd_role_guids_csv}}
     )
    )
  COND
}

# --- Plan identity: Reader on both workload-sub RGs ------------------------

resource "azurerm_role_assignment" "tfplan_workload_reader" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfplan_network_reader" {
  scope                = azurerm_resource_group.network.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: Contributor on both workload-sub RGs ------------------

resource "azurerm_role_assignment" "tfapply_workload_contributor" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_network_contributor" {
  scope                = azurerm_resource_group.network.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: constrained RBAC-admin on the workload RG -------------
# Contributor excludes Microsoft.Authorization/roleAssignments/write, so the
# apply identity needs RBAC-admin to create the layer's role assignments. The
# ABAC condition restricts it to the five app-plane roles only.
resource "azurerm_role_assignment" "tfapply_rbac_admin" {
  scope                = azurerm_resource_group.workload.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"

  condition_version = "2.0"
  condition         = local.rbac_admin_condition
}

# --- Cross-sub data sources ------------------------------------------------

# Hub RG (connectivity sub) — scope for the narrow connectivity grant. Name
# comes from 30-connectivity's remote state; resolve its ID via the
# connectivity-aliased provider.
data "azurerm_resource_group" "hub" {
  provider = azurerm.connectivity
  name     = data.terraform_remote_state.connectivity.outputs.hub_resource_group_name
}

locals {
  # ARM ID of the state blob container the azurerm backend uses. Constructed
  # from known values rather than read via a data source — reading the SA
  # would require management-plane storageAccounts/read on the state SA, which
  # the CI identities deliberately don't have (they only get data-plane Storage
  # Blob Data roles on the container).
  state_container_id = "/subscriptions/${var.mgmt_subscription_id}/resourceGroups/rg-tfstate-plat-weu-001/providers/Microsoft.Storage/storageAccounts/${var.state_storage_account_name}/blobServices/default/containers/tfstate"
}

# --- Plan identity: Reader on the hub RG (connectivity sub) ----------------

resource "azurerm_role_assignment" "tfplan_hub_reader" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

# --- Apply identity: narrow connectivity grants (hub RG only) --------------

resource "azurerm_role_assignment" "tfapply_hub_network" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_hub_dns" {
  provider             = azurerm.connectivity
  scope                = data.azurerm_resource_group.hub.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}

# --- State container access (management sub, via use_azuread_auth) ---------

resource "azurerm_role_assignment" "tfplan_state_reader" {
  provider             = azurerm.management
  scope                = local.state_container_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azurerm_user_assigned_identity.tfplan.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "tfapply_state_contributor" {
  provider             = azurerm.management
  scope                = local.state_container_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.tfapply.principal_id
  principal_type       = "ServicePrincipal"
}
