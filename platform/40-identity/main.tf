# Custom RBAC role definitions for the Keystone platform.
#
# Per CLAUDE.md §2 the identity baseline requires *at least one custom
# RBAC role definition* — this is the first one. More can land later
# as patterns demand them (cost-data readers, sandbox-only owners, etc).
#
# Role definitions are scoped at management-group level. The MG ID
# determines where the role *can be assigned* (assignable_scopes) and
# where the role definition itself lives (scope).
#
# Cost: free. RBAC role definitions are not billed.

# --- Keystone Spoke Network Operator ----------------------------------------
#
# What it does: allows full operation of *spoke-side* networking
# resources (VNets, subnets, NSGs, route tables, private endpoints) in
# any subscription under keystone-landing-zones.
#
# What it CANNOT do (NotActions):
#   1. Modify VNet peerings — hub→spoke peering is the hub team's
#      responsibility. A spoke operator who could rewrite peerings
#      could exfiltrate traffic past the firewall.
#   2. Link private DNS zones to VNets — central DNS is managed by
#      the hub team per CLAUDE.md §2. A spoke operator who could
#      add zone links could shadow names that resolve to attacker-
#      controlled IPs from inside the spoke.
#
# This is the canonical "delegate spoke ownership without giving up
# hub control" pattern for hub-spoke ESLZ.
#
# Assignment: deferred. No workload identities exist yet to assign
# this to; that lands when the workload layer does.

resource "azurerm_role_definition" "spoke_network_operator" {
  name        = "Keystone Spoke Network Operator"
  description = "Manage spoke-side network resources (VNets, NSGs, route tables, private endpoints) within keystone-landing-zones. Cannot modify hub peerings or link to central Private DNS zones — those remain the hub team's responsibility."

  scope = data.terraform_remote_state.management_groups.outputs.management_group_ids["landing_zones"]

  permissions {
    actions = [
      # Spoke VNets + everything that lives inside them.
      "Microsoft.Network/virtualNetworks/*",
      "Microsoft.Network/networkSecurityGroups/*",
      "Microsoft.Network/routeTables/*",
      "Microsoft.Network/networkInterfaces/*",
      "Microsoft.Network/privateEndpoints/*",
      "Microsoft.Network/publicIPAddresses/*",
      "Microsoft.Network/networkWatchers/*",

      # Need to read RGs to deploy resources into them, but RG
      # *creation* and *deletion* are deliberately not granted —
      # the platform layer creates spoke RGs via subscription vending.
      "Microsoft.Resources/subscriptions/resourceGroups/read",

      # Need to read sub metadata to find the right scope.
      "Microsoft.Resources/subscriptions/read",
    ]

    not_actions = [
      # Cannot create / modify peerings. Hub team owns this — if a
      # spoke could rewrite its peering, it could redirect traffic
      # past the firewall.
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write",
      "Microsoft.Network/virtualNetworks/virtualNetworkPeerings/delete",

      # Cannot link to central Private DNS zones. Hub team owns
      # central DNS per CLAUDE.md §2; rogue links could shadow
      # names that resolve to attacker-controlled IPs.
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks/write",
      "Microsoft.Network/privateDnsZones/virtualNetworkLinks/delete",
    ]

    data_actions     = []
    not_data_actions = []
  }

  # Assignable only within keystone-landing-zones — the role cannot
  # be assigned at scopes outside the landing-zone hierarchy. This is
  # belt-and-suspenders on top of the `scope` field above.
  assignable_scopes = [
    data.terraform_remote_state.management_groups.outputs.management_group_ids["landing_zones"],
  ]
}
