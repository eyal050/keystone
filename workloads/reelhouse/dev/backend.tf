# Remote backend in the state SA created by platform/00-bootstrap.
# Backend-config values supplied at init time by scripts/_tf-cmd.sh.
# State key for this layer: workloads-reelhouse-dev.tfstate.

terraform {
  backend "azurerm" {}
}
