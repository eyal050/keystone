# DeployIfNotExists diagnostic-settings policy assignment.
#
# This is the CLAUDE.md §8 break/debug scenario, set up "correctly"
# in F2a: every Microsoft.Storage/storageAccounts resource under
# keystone gets a diagnostic setting forwarding metrics into the
# platform LAW. F2b (to be done in a later session) deliberately
# breaks the role assignments to observe the silent-non-compliance
# failure mode.
#
# Components:
#
#   1. The policy assignment with `identity = SystemAssigned` — this
#      creates a system-assigned managed identity for the assignment.
#
#   2. Two `azurerm_role_assignment` resources granting the MI the
#      roles the policy needs (declared in the policy definition's
#      `roleDefinitionIds` field):
#        - Monitoring Contributor on the keystone MG: lets the MI
#          create diagnostic-setting resources on anything under it.
#        - Log Analytics Contributor on the LAW: lets the MI tell
#          the workspace to accept logs from those settings.
#
# Without (2), the MI exists but can't act — remediation tasks fail
# with 403, the compliance dashboard says "Non-compliant" for every
# storage account, and there's no obvious failure to point at.
# That is the failure mode the lab exists to surface.

locals {
  # Built-in: "Configure diagnostic settings for Storage Accounts to
  # Log Analytics workspace". Declares roleDefinitionIds for
  # Monitoring Contributor + Log Analytics Contributor. Parameterized
  # effect; we pin to DeployIfNotExists.
  storage_diag_settings_policy_id = "/providers/Microsoft.Authorization/policyDefinitions/59759c62-9a22-4cdf-ae64-074495983fef"
}

resource "azurerm_management_group_policy_assignment" "storage_diag_settings" {
  name                 = "diag-storage-to-law"
  display_name         = "Storage Accounts: diagnostic settings to platform LAW"
  description          = "DeployIfNotExists policy that creates a diagnostic setting forwarding storage account metrics to the keystone platform Log Analytics workspace. CLAUDE.md §8 break/debug scenario — the MI's role assignments below are the silent-failure point if removed."
  management_group_id  = data.terraform_remote_state.management_groups.outputs.management_group_ids.top
  policy_definition_id = local.storage_diag_settings_policy_id

  # SystemAssigned MI required for DeployIfNotExists. `location` is
  # required when identity is set — pick the lab's primary region.
  location = var.location
  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    effect = {
      value = "DeployIfNotExists"
    }
    logAnalytics = {
      value = azurerm_log_analytics_workspace.this.id
    }
    profileName = {
      value = "keystone-default-diag"
    }
    metricsEnabled = {
      value = true
    }
  })
}

# ---------------------------------------------------------------------------
# Role assignments for the policy's MI. These are the F2b break-point.
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "diag_mi_monitoring_contributor" {
  scope                = data.terraform_remote_state.management_groups.outputs.management_group_ids.top
  role_definition_name = "Monitoring Contributor"
  principal_id         = azurerm_management_group_policy_assignment.storage_diag_settings.identity[0].principal_id

  # MI propagation: a brand-new SystemAssigned identity is not
  # immediately visible across all Azure regions / role assignment
  # endpoints. Without skip_service_principal_aad_check = true,
  # azurerm hits an intermittent "principal not found" error on
  # first apply. The flag tells the API to trust us.
  skip_service_principal_aad_check = true

  description = "Lets the storage_diag_settings policy's MI create diagnostic-setting resources on storage accounts under keystone MG. Removing this assignment is the F2b break/debug exercise."
}

resource "azurerm_role_assignment" "diag_mi_log_analytics_contributor" {
  # Using role_definition_name (not role_definition_id) intentionally:
  # when scope is a sub-scoped resource (the LAW), Azure normalizes
  # role_definition_id to the sub-prefixed form, which doesn't match
  # the tenant-scoped form Terraform writes, causing perpetual drift.
  # role_definition_name avoids that since it's resolved server-side.
  scope                            = azurerm_log_analytics_workspace.this.id
  role_definition_name             = "Log Analytics Contributor"
  principal_id                     = azurerm_management_group_policy_assignment.storage_diag_settings.identity[0].principal_id
  skip_service_principal_aad_check = true

  description = "Lets the storage_diag_settings policy's MI write diagnostic data into the platform LAW. Without this, remediation deploys would 403 at the LAW side."
}
