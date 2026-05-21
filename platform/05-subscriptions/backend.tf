# Backend configuration for platform/05-subscriptions.
#
# This layer is applied BEFORE platform/00-bootstrap creates the remote
# state SA, so the first apply uses backend "local". After 00-bootstrap
# vends the state SA and migrates its own state, swap this block to
# `azurerm` with key = "platform-05-subscriptions.tfstate" and run:
#
#   terraform init -migrate-state \
#     -backend-config="resource_group_name=<from 00-bootstrap output>" \
#     -backend-config="storage_account_name=<from 00-bootstrap output>" \
#     -backend-config="container_name=tfstate" \
#     -backend-config="key=platform-05-subscriptions.tfstate"

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }

  # backend "azurerm" {
  #   # Values supplied via terraform init -backend-config=... — see README.md.
  # }
}
