# Provider configuration for platform/05-subscriptions.
#
# Subscription vending operates at MCA billing scope, not at subscription
# scope. The provider's subscription_id is therefore only an auth context:
# any subscription in the tenant where Eyal has billing-admin rights works.
#
# var.vending_subscription_id holds one of Eyal's existing subs (sourced
# from KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID in ~/.keystone/secrets.env)
# and is used purely as that auth context.

provider "azurerm" {
  subscription_id = var.vending_subscription_id
  tenant_id       = var.tenant_id

  features {}
}
