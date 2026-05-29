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

  # Per ADR-0016, this SA needs PNA=true (gated by network_rules).
  # The deny-storage-public policy at keystone-landing-zones-corp MG
  # scope would block that without an exemption. The exemption is
  # constructed below to reference this SA by reconstructed ID (not
  # via resource ref) so Terraform can order: exemption first, then
  # SA update. Otherwise SA→exemption would cycle.
  depends_on = [azurerm_resource_policy_exemption.videos_pna_operator_access]

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

  # Public network access ENABLED but gated by network_rules below.
  # Per ADR-0016 the operator's IP is allowlisted so portal blob browse
  # and `az storage blob list` work from the operator's laptop. ACA
  # still reaches this SA via the PE — the public endpoint only opens
  # for the explicit allowlist.
  #
  # The deny-storage-public policy at keystone-landing-zones-corp MG
  # scope would normally reject PNA=true; the resource-scoped exemption
  # at the bottom of this file is what makes it possible.
  public_network_access_enabled = true

  network_rules {
    default_action = "Deny"

    # AzureServices bypass lets Azure-internal services (some Azure
    # Monitor paths, diagnostic settings, etc.) reach the account
    # without per-service IP rules. Belt-and-suspenders; not strictly
    # required for operator portal browse.
    bypass = ["AzureServices"]

    # Operator's home IP per ADR-0016. Bare IPv4, no CIDR — Azure
    # storage's ip_rules accepts either bare IPv4 (single host) or
    # CIDR with /0-30 (range). /32 is explicitly rejected.
    ip_rules = var.operator_ip != "" ? [var.operator_ip] : []
  }

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

# Resource-scoped exemption from the deny-storage-public policy at
# keystone-landing-zones-corp MG scope. Per ADR-0016 the operator
# needs PNA enabled (with strict ACLs) for ad-hoc portal browse and
# `az storage blob list`. The exemption is scoped to THIS SA only —
# every other workload SA still inherits the deny.
resource "azurerm_resource_policy_exemption" "videos_pna_operator_access" {
  name         = "videos-pna-operator-access"
  display_name = "Operator IP allowlist exemption per ADR-0016"
  description  = "Exempts this storage account from deny-storage-public so the operator can inspect blob contents from their laptop (portal + az CLI). The SA still denies all public traffic except the operator's IP via network_rules."

  # Construct the resource ID from the same primitives the SA uses
  # (RG name + random suffix) instead of referencing the SA resource
  # directly. This breaks the dependency cycle that would otherwise
  # form (SA needs exemption to apply, exemption would need SA to
  # exist). With this shape, the exemption depends only on RG +
  # random_string, and the SA depends on the exemption — clean
  # ordering, no cycle.
  resource_id = "/subscriptions/${var.workload_subscription_id}/resourceGroups/${azurerm_resource_group.workload.name}/providers/Microsoft.Storage/storageAccounts/streelhdev${random_string.storage_suffix.result}"

  exemption_category = "Waiver"

  # The assignment lives at keystone-landing-zones-corp MG scope
  # (see platform/10-management-groups/policy-assignments.tf). The
  # exemption references the assignment ID, not the definition ID.
  policy_assignment_id = "${data.terraform_remote_state.management_groups.outputs.management_group_ids.landing_zones_corp}/providers/Microsoft.Authorization/policyAssignments/deny-storage-public"
}

resource "azurerm_storage_container" "videos" {
  name                  = "videos"
  storage_account_id    = azurerm_storage_account.videos.id
  container_access_type = "private"
}

# Operator data-plane RBAC. Owner on the sub is control-plane only;
# without an explicit Storage Blob Data role, even `az storage blob list
# --auth-mode login` returns "do not have the required permissions."
# Mirror the keyvault operator_kv_admin pattern: grant the current
# `terraform apply` identity full data-plane access on this SA.
resource "azurerm_role_assignment" "operator_blob_contributor" {
  scope                = azurerm_storage_account.videos.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- Private endpoint into snet-pe-001 --------------------------------------

resource "azurerm_private_endpoint" "blob" {
  count = var.workload_pe_enabled ? 1 : 0

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
