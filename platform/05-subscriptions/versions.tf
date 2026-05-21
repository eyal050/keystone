# Provider version pins for platform/05-subscriptions.
# Identical to platform/00-bootstrap by intent — every platform layer
# uses the same pin set so a provider bump propagates uniformly.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.16"
    }
  }
}
