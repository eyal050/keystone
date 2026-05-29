# Shared resource group for the workload's data + compute plane.
# Network resources live in their own RG (rg-reelhouse-dev-net-weu-001)
# per the CAF separate-RG pattern — different destroy radius, cleaner
# cost attribution between "spoke plumbing" and "actual workload."

resource "azurerm_resource_group" "workload" {
  name     = "rg-reelhouse-dev-workload-${var.location_short}-001"
  location = var.location
  tags     = var.required_tags
}
