# ADR-0013: Workload layer owns the spoke VNet, peering, and DNS links

- **Status**: Accepted
- **Date**: 2026-05-28
- **Decider**: Eyal
- **Supersedes**: —
- **Revises**: the implicit "30-connectivity E4 = spoke peering" plan
  from `platform/30-connectivity/README.md`

## Context

When `platform/30-connectivity` was scoped, E4 was sketched as
"spoke peering once workload VNets land" — with the implicit
assumption that the hub-team-owned connectivity layer would create
both sides of the hub↔spoke peering and the spoke-side DNS zone
links once the workload existed.

That sketch surfaced a real problem when the workload track became
imminent (2026-05-28, after [ADR-0012](0012-adopt-lab-foundation-as-workload-sub.md)
adopted `lab-foundation` as the workload host): **30-connectivity
would need to reach into the workload layer's state to discover the
spoke VNet ID before creating the hub-side peering and DNS links
pointing at it.** That inverts the layer dependency order — the
platform layers should be consumable by workloads, not consumers of
them.

Three patterns were considered, listed under "Alternatives" below.

## Decision

**The workload layer owns the entire network seam** between the
spoke and the hub:

- Spoke VNet, subnets, NSGs (when needed), route tables (when
  needed) — created in `workloads/reelhouse/dev/` against the
  workload subscription (currently `lab-foundation` per ADR-0012).
- **Hub-side peering** — created in `workloads/reelhouse/dev/`
  too, against the connectivity subscription via a *provider
  alias*. The hub VNet ID is read from `30-connectivity`'s remote
  state output.
- **Spoke-side peering** — created in `workloads/reelhouse/dev/`
  against the workload subscription.
- **Spoke-side Private DNS zone links** — created in
  `workloads/reelhouse/dev/` against the connectivity sub (the
  links live in the connectivity sub where the zones do, even
  though they reference the spoke VNet in the workload sub).

`platform/30-connectivity` therefore stops at the *hub*. Its
sub-chunk inventory shrinks from `E1, E2, E3, E4` to `E1, E2, E3` —
E4 dissolves into the workload layer.

### Concretely in code

```hcl
# workloads/reelhouse/dev/providers.tf
provider "azurerm" {
  alias           = "workload"
  subscription_id = var.workload_subscription_id  # lab-foundation
  features {}
}

provider "azurerm" {
  alias           = "connectivity"
  subscription_id = var.connectivity_subscription_id
  features {}
}

# Spoke VNet lives in workload sub
resource "azurerm_virtual_network" "spoke" {
  provider = azurerm.workload
  # ...
}

# Hub-side peering lives in connectivity sub
resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  provider             = azurerm.connectivity
  virtual_network_name = data.terraform_remote_state.connectivity.outputs.hub_vnet_name
  # ...
}

# Spoke DNS zone link lives in connectivity sub
resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  provider              = azurerm.connectivity
  for_each              = data.terraform_remote_state.connectivity.outputs.private_dns_zone_ids
  virtual_network_id    = azurerm_virtual_network.spoke.id
  # ...
}
```

## Consequences

**Positive:**

- **Layer dependency stays one-directional.** Workload depends on
  connectivity (via remote_state read); connectivity never reaches
  into workload state. New workloads are additive — they don't
  cause re-applies in connectivity.
- **Workload teardown is self-contained.** Destroying the workload
  layer cleans up its spoke VNet, both peerings, and the DNS
  links pointing at the spoke. The hub is left untouched. This is
  exactly the destroy-radius separation ADR-0010 / on-demand
  resources rely on.
- **Provider aliasing is genuine platform-engineering muscle.**
  Cross-subscription Terraform with the same provider pinned to
  different subscription_ids is the dominant pattern for any
  meaningful ESLZ workload — interview-defensible and used in the
  wild constantly.
- **Trust model matches the role definitions.** The Keystone Spoke
  Network Operator role (ADR-0011-adjacent work in 40-identity)
  explicitly NotActions `virtualNetworkPeerings/write` so that a
  workload-team-only identity *cannot* create peerings. In this
  Terraform setup, peerings are created with the **operator's**
  cross-sub identity (initially Eyal's Owner; in CI later, a
  platform-team federated identity with both-sub access). The
  delegation pattern still works — workload teams build into the
  spoke, but the peering itself is created by an identity scoped
  to both sides.

**Negative / trade-offs:**

- **Workload Terraform requires permissions in two subscriptions.**
  Locally this is Eyal-with-Owner. For CI, the workload's federated
  identity needs Network Contributor (or similar) on the hub RG in
  the connectivity sub. This is *more* privilege than a workload
  team would have in a real enterprise; in production the peering
  creation often goes through a platform-owned automation pipeline,
  not the workload's own pipeline.
- **State-file blast radius grows.** A bad apply in the workload
  state can touch resources in the connectivity sub (the hub-side
  peering, the spoke DNS link). Less isolation than if those
  resources were owned by a separate state.
- **Provider aliasing adds plumbing.** Every workload-network
  resource has to be explicit about `provider = azurerm.workload`
  or `azurerm.connectivity`. Forgetting it lands in the wrong sub,
  with a confusing error. Mitigation: a project-wide convention to
  always set `provider =` explicitly on every resource in any
  layer that uses aliases.

**What this does NOT change:**

- Hub VNet, hub firewall, central DNS *zones* — all still owned by
  `platform/30-connectivity`. The hub team is still the source of
  truth for hub-side IP allocation, central DNS naming, and the
  firewall policy.
- IP allocation discipline is still a hub-team responsibility,
  enforced **by convention** (documentation, code review, naming).
  The workload picks its own /20 from the documented allocation
  table.

## Alternatives considered

- **A. Platform layer owns the spoke shell, workload deploys into
  it.** Rejected. 30-connectivity would need to know the workload
  sub ID at apply time *and* have credentials in that sub. That
  is feasible but it inverts which layer "depends on" which — the
  platform layer would have to be re-applied every time a new
  workload sub is adopted, which makes the platform layer's
  blast radius grow with the workload count. Also: hub-team
  Terraform creating resources in workload subs is exactly the
  role-segregation hazard the Spoke Network Operator NotActions
  exist to prevent.

- **B. Workload owns the spoke; hub owns the peering** *(split
  ownership)*. Rejected. Each side of the peering would live in
  different state; creating them in the right order requires
  coordinated applies. A workload apply that creates the spoke
  but then waits for a hub-side apply to add the peering would
  leave the spoke islanded between applies. Operationally
  brittle.

- **C. Workload owns the spoke, both peerings, and the DNS
  links via provider aliasing.** Accepted (this ADR).

- **D. A separate `platform/30-connectivity/spokes/` sub-layer
  per workload, hub-team owned.** Rejected. A per-workload
  Terraform state in the platform tree multiplies platform-layer
  count by the number of workloads, which doesn't pay rent in a
  small lab. Could be revisited if Keystone grew to host 5+
  workloads.

## IP allocation table (initial)

| VNet | Address space | Sub |
|---|---|---|
| Hub (`vnet-hub-conn-weu-001`) | `10.10.0.0/16` | `keystone-platform-connectivity` |
| Spoke — reelhouse-dev (`vnet-reelhouse-dev-weu-001`) | `10.20.0.0/20` | `lab-foundation` (adopted) |
| Reserved future spokes | `10.30.0.0/20` onward | TBD |

The hub's /16 and each spoke's /20 are deliberately non-adjacent —
plenty of room to grow either without forcing a renumbering.

## Future revisit triggers

Revisit this ADR when:

- A workload-team-only federated identity needs to exist with
  *restricted* access (e.g. cannot touch the connectivity sub).
  At that point, peering creation has to move out of the
  workload-team's Terraform — either into a platform-team CI
  pipeline or into a coordinated apply via something like
  Atlantis / Terraform Cloud.
- The lab grows beyond 1-2 workloads and the explicit
  per-workload provider-aliasing plumbing becomes repetitive.
  Refactor into a shared module at that point.

Until either fires, the workload-owns-the-seam pattern stands.
