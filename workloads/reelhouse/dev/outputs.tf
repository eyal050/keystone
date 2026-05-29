# Outputs for downstream consumption (future workload sub-layers,
# observability tooling, etc.).

output "spoke_vnet_id" {
  description = "Resource ID of the reelhouse-dev spoke VNet."
  value       = azurerm_virtual_network.spoke.id
}

output "spoke_vnet_name" {
  description = "Name of the reelhouse-dev spoke VNet."
  value       = azurerm_virtual_network.spoke.name
}

output "network_resource_group_name" {
  description = "Resource group containing the spoke VNet and subnets."
  value       = azurerm_resource_group.network.name
}

output "subnet_ids" {
  description = "Map of subnet short name → ARM resource ID. Consumed by future workload resources (ACA env, private endpoints, APIM)."
  value = {
    aca  = azurerm_subnet.aca.id
    pe   = azurerm_subnet.pe.id
    apim = azurerm_subnet.apim.id
  }
}

output "postgres_server_fqdn" {
  description = "FQDN of the Postgres Flexible Server. Resolves to the private endpoint's IP from inside the spoke VNet (via privatelink.postgres.database.azure.com)."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "workload_resource_group_name" {
  description = "Resource group containing the workload's data + compute plane (Postgres, KV, Blob, ACA)."
  value       = azurerm_resource_group.workload.name
}

output "acr_login_server" {
  description = "ACR login server FQDN (e.g. acrreelhdevXXXX.azurecr.io). Consumed by the GitHub Actions workflow when tagging / pushing images and when updating the Container App."
  value       = azurerm_container_registry.this.login_server
}

output "acr_name" {
  description = "ACR resource name (the portion before .azurecr.io). Needed for `az acr login` and `az acr repository show`."
  value       = azurerm_container_registry.this.name
}

output "container_app_name" {
  description = "Container App resource name. Needed for `az containerapp update`."
  value       = azurerm_container_app.api.name
}

output "container_app_fqdn" {
  description = "Public FQDN of the Container App (*.azurecontainerapps.io). Used by the workflow's final verification step (curl /healthz) and by humans visiting the running app."
  value       = azurerm_container_app.api.ingress[0].fqdn
}

output "github_actions_client_id" {
  description = "Client ID of the user-assigned managed identity GitHub Actions authenticates as via OIDC. Add this as a GitHub Actions repo secret named AZURE_CLIENT_ID (see workflow YAML)."
  value       = azurerm_user_assigned_identity.github_actions.client_id
  sensitive   = true
}
