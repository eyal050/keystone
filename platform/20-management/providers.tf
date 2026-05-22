# Provider configuration for platform/20-management.
#
# Resources land inside keystone-platform-management. The same
# hardening pattern as 00-bootstrap and 10-management-groups: provider
# subscription_id sourced from a validated variable, and a precondition
# on the first resource verifies the sub's display name.

provider "azurerm" {
  subscription_id = var.mgmt_subscription_id
  tenant_id       = var.tenant_id

  features {
    log_analytics_workspace {
      # Permanent delete the workspace immediately on destroy rather
      # than soft-deleting (30-day recovery period). Recovery on a
      # lab workspace is unnecessary; the soft-deleted name would
      # block re-creation under the same name for a month.
      permanently_delete_on_destroy = true
    }
  }
}
