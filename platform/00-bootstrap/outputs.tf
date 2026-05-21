# Outputs consumed by:
#   - The terraform init -migrate-state step (see backend.tf).
#   - Every subsequent layer's backend block, via terraform_remote_state
#     or via the GitHub Actions workflow that wires -backend-config args.

output "tfstate_resource_group_name" {
  description = "Resource group hosting the Terraform state storage account."
  value       = azurerm_resource_group.tfstate.name
}

output "tfstate_storage_account_name" {
  description = "Storage account holding remote state for every Keystone layer."
  value       = azurerm_storage_account.tfstate.name
}

output "tfstate_container_name" {
  description = "Blob container holding per-layer state files (key = <layer>.tfstate)."
  value       = azurerm_storage_container.tfstate.name
}

output "tfstate_storage_account_id" {
  description = "ARM resource ID of the state storage account. Used by later layers when assigning Storage Blob Data Contributor to CI identities."
  value       = azurerm_storage_account.tfstate.id
}
