# Hardening: verify the auth-context sub is keystone-platform-connectivity
# before creating anything. Same precondition pattern as the other
# platform layers — catches the 2026-05-21 wrong-sub incident class.
data "azurerm_subscription" "conn" {
  subscription_id = var.connectivity_subscription_id
}
