# S1: Workload Blob storage + private endpoint.
#
# StorageV2, LRS, Hot tier. Public network access disabled (the
# deny-storage-public policy at keystone-landing-zones-corp scope
# enforces this anyway — belt-and-suspenders by setting it explicitly).
#
# SAS strategy: USER-DELEGATED SAS, signed by ACA's managed identity
# token (no shared storage key in play). This exercises the modern
# MI-driven SAS pattern. The MI gets `Storage Blob Data Contributor`
# on the SA in C1; the app calls
# `BlobServiceClient.get_user_delegation_key()` then
# `generate_blob_sas(user_delegation_key=...)` to mint share links.

resource "random_string" "storage_suffix" {
  length  = 8
  upper   = false
  special = false
  numeric = true
}

resource "azurerm_storage_account" "videos" {
  name = "streelhdev${random_string.storage_suffix.result}"

  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  access_tier              = "Hot"

  # Secure-transfer-required policy is enforced at MG scope; setting
  # this explicitly aligns the resource to the policy upfront.
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  # Disable shared-key access — forces all data-plane operations
  # through Entra-token-based auth. Pairs with the user-delegated
  # SAS pattern above; the workload's MI signs SAS via its own token,
  # not via an account key.
  shared_access_key_enabled = false

  # PE only — public network access denied by both policy and config.
  public_network_access_enabled = false

  # Soft delete: 7 days for blobs (lab default — recoverable
  # mistakes without long-term storage cost). No container soft delete
  # (not useful at lab scale; containers rarely get deleted by mistake).
  blob_properties {
    delete_retention_policy {
      days = 7
    }
  }

  tags = var.required_tags
}

resource "azurerm_storage_container" "videos" {
  name                  = "videos"
  storage_account_id    = azurerm_storage_account.videos.id
  container_access_type = "private"
}

# --- Private endpoint into snet-pe-001 --------------------------------------

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-st-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  subnet_id           = azurerm_subnet.pe.id

  private_service_connection {
    name                           = "psc-blob-reelhouse-dev"
    private_connection_resource_id = azurerm_storage_account.videos.id
    is_manual_connection           = false
    # Storage has multiple sub-resources (blob, file, queue, table,
    # dfs). We only need blob — separate PEs would be created for
    # additional services if ever needed.
    subresource_names = ["blob"]
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      data.terraform_remote_state.connectivity.outputs.private_dns_zone_ids["privatelink.blob.core.windows.net"],
    ]
  }

  tags = var.required_tags
}
