# `platform/40-identity`

Custom RBAC role definitions and (eventually) platform-scoped managed
identities for Keystone. Per [ADR-0011](../../docs/decisions/0011-identity-collapsed-into-management.md)
this layer **operates from `keystone-platform-management`**, not from
a dedicated `keystone-platform-identity` subscription — the MCA quota
hit during Phase 2 vending forced the documented "collapse Identity
into Management" compromise from CLAUDE.md §3.

Role *definitions* are scoped at management-group level regardless of
which sub runs Terraform, so the collapse changes the layer's home
but not the surface it exercises.

## Role catalog

| Role | Scope (assignable) | Status |
|---|---|---|
| **Keystone Spoke Network Operator** | `keystone-landing-zones` | ✅ defined, ❌ unassigned (workload identities don't exist yet) |

### Keystone Spoke Network Operator

Delegates *spoke-side* network operations to a workload team without
giving up hub control. The canonical hub-spoke ESLZ delegation pattern.

**Allows (Actions):**
- Full operation of spoke VNets, subnets, NSGs, route tables
- Network interfaces, private endpoints, public IPs
- Network Watcher / packet capture
- Read access to RGs and subs (to navigate the deployment)

**Denies (NotActions):**
- `Microsoft.Network/virtualNetworks/virtualNetworkPeerings/write`+`delete`
  → hub team owns peering; a spoke operator who could rewrite peerings
  could exfiltrate past the firewall.
- `Microsoft.Network/privateDnsZones/virtualNetworkLinks/write`+`delete`
  → hub team owns central DNS per CLAUDE.md §2; rogue links could
  shadow names to attacker-controlled IPs.

**Why this role exists in interview-defensible terms:**
delegation without blast-radius escalation. The reviewer should think
of two attacks the role *prevents*: traffic redirection (via peering
rewrite) and name shadowing (via DNS link). Both are hub-team
responsibilities precisely because misuse crosses the workload boundary.

## Cost

Free. RBAC role definitions are not billed.

## Why no managed identities (yet)

CLAUDE.md §2 calls for "custom RBAC role definitions **and** managed
identities used by the workload." Today there are no platform-scoped
MIs that need a home — the diagnostic-settings DfN policy MI in
`platform/20-management` lives where it's used. The workload-side
MIs (Function/Container App MIs, Postgres MIs, etc.) will land
alongside the workload code in `workloads/reelhouse/`.

When a platform-scoped MI does appear (e.g. a cross-sub automation
identity), it lands here.

## Re-vending platform-identity in the future

If MCA quota is later raised and the identity sub is vended:

1. `make vend-sub ALIAS=platform-identity` (or whatever the new sub
   alias is).
2. Update `var.mgmt_subscription_id` reference in this layer to
   point at the new sub, OR add a new var and switch the provider.
3. `terraform state mv` the role definitions if their scope changes
   (it won't — MG-scoped roles don't move when the operator sub
   changes).
4. Re-apply.

The role definitions themselves are MG-scoped and immune to the
operator sub change. The state file moves; the resources don't.
