# Provider version pins for platform/10-management-groups.
# Identical pin set to the other platform layers — see ADR-0007.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.16"
    }
  }
}
