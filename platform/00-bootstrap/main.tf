# Bootstrap layer: Terraform state storage account.
#
# Creates the resource group, storage account, and blob container that
# every other Keystone layer uses for its remote state. See ADR-0007.

# Globally-unique suffix for the storage account name. Stored in state
# so the name remains stable across re-plans.
resource "random_id" "tfstate_suffix" {
  byte_length = 3
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate-plat-${var.location_short}-001"
  location = var.location

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true
  }
}

# Storage account hosting all layer state files.
#
# Security posture:
#  - TLS 1.2 minimum
#  - Public blob access disabled
#  - Blob versioning + 30-day soft-delete on blobs and containers
#  - GRS replication (paired-region failover available)
#
# Network posture is permissive in this first pass (default_action = Allow)
# because the connectivity layer (platform/30) does not yet exist to
# provide a private endpoint. Tightening to Deny + private endpoint
# is a deliberate step once 30-connectivity lands; see TODO in this file.
resource "azurerm_storage_account" "tfstate" {
  name                = "sttfstateplat${var.location_short}${random_id.tfstate_suffix.hex}"
  resource_group_name = azurerm_resource_group.tfstate.name
  location            = azurerm_resource_group.tfstate.location

  account_tier             = "Standard"
  account_replication_type = "GRS"
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }

  network_rules {
    # TODO(connectivity): change to "Deny" + private_endpoint once
    # platform/30-connectivity provides the private DNS zone for blob.
    default_action = "Allow"
    bypass         = ["AzureServices"]
  }

  tags = var.required_tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.tfstate.id
  container_access_type = "private"
}
