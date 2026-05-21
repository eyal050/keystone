# Provider version pins for platform/00-bootstrap.
#
# Per session-0 decision: pin azurerm to the latest stable 4.x minor;
# patch-level updates auto-allowed, minor bumps require deliberate
# version-line edit. The Terraform CLI version itself uses >= because
# the lockfile (.terraform.lock.hcl) is the authoritative pin for
# provider hashes.

terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.16"
    }

    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
