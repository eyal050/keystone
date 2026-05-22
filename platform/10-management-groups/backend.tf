# Backend configuration for platform/10-management-groups.
#
# Uses the remote state SA created by platform/00-bootstrap. There is
# no local-backend chicken-and-egg for this layer: by the time
# 10-management-groups is applied, both 00-bootstrap and 05-subscriptions
# have already migrated their own state to the remote SA.
#
# Backend-config values supplied at init time (see README.md). subscription_id
# in particular MUST be passed explicitly — the azurerm backend has its own
# subscription parameter separate from the provider config, and silently
# falls back to the az CLI default if not set.

terraform {
  backend "azurerm" {}
}
