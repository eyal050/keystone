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
  description = "FQDN of the Postgres Flexible Server when it exists. Empty string when var.postgres_enabled=false (per ADR-0017). Resolves to the private endpoint's IP from inside the spoke VNet (via privatelink.postgres.database.azure.com) when the PE is up."
  value       = var.postgres_enabled ? azurerm_postgresql_flexible_server.this[0].fqdn : ""
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
  description = "Internal FQDN of the Container App. Post-ADR-0019 the ACA env is internal-only, so this resolves to a private IP via the per-env DNS zone and is reachable only from inside the spoke VNet (by APIM) — not from the internet. The public entry point is frontdoor_endpoint_hostname when gateway_enabled."
  value       = azurerm_container_app.api.ingress[0].fqdn
}

output "github_actions_client_id" {
  description = "Client ID of the user-assigned managed identity GitHub Actions authenticates as via OIDC. Add this as a GitHub Actions repo secret named AZURE_CLIENT_ID (see workflow YAML)."
  value       = azurerm_user_assigned_identity.github_actions.client_id
  sensitive   = true
}

output "tfplan_client_id" {
  description = "Client ID of the read-only Terraform plan identity. Set as repo secret AZURE_TF_PLAN_CLIENT_ID."
  value       = azurerm_user_assigned_identity.tfplan.client_id
  sensitive   = true
}

output "tfapply_client_id" {
  description = "Client ID of the read-write Terraform apply identity. Set as workload-dev environment secret AZURE_TF_APPLY_CLIENT_ID."
  value       = azurerm_user_assigned_identity.tfapply.client_id
  sensitive   = true
}

output "frontdoor_endpoint_hostname" {
  description = "Public Front Door hostname for ReelHouse (null when gateway_enabled=false)."
  value       = var.gateway_enabled ? azurerm_cdn_frontdoor_endpoint.this[0].host_name : null
}
