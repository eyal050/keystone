# Backend configuration for platform/00-bootstrap.
#
# Per ADR-0007, this layer is applied twice:
#
#   1. First apply uses the LOCAL backend block below. The state SA
#      and container resources are created in keystone-platform-management.
#
#   2. After step 1 succeeds, edit this file: comment out the `local`
#      block and uncomment the `azurerm` block. Then run:
#
#        terraform init -migrate-state \
#          -backend-config="resource_group_name=$(terraform output -raw tfstate_resource_group_name)" \
#          -backend-config="storage_account_name=$(terraform output -raw tfstate_storage_account_name)" \
#          -backend-config="container_name=tfstate" \
#          -backend-config="key=platform-00-bootstrap.tfstate"
#
#      Terraform will copy the local state into the new SA and from
#      that point on, every layer (including this one on re-apply)
#      uses the remote backend.
#
# After migration, delete terraform.tfstate and terraform.tfstate.backup
# from this directory.

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # backend "azurerm" {
  #   # Values supplied via terraform init -backend-config=... — see README.md.
  # }
}
