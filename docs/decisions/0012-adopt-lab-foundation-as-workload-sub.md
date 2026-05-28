# ADR-0012: Adopt the pre-existing `lab-foundation` sub as the workload host

- **Status**: Accepted
- **Date**: 2026-05-28
- **Decider**: Eyal
- **Supersedes**: —
- **Builds on**: [ADR-0011](0011-identity-collapsed-into-management.md) (same MCA quota wall, different blocked goal)

## Context

[ADR-0011](0011-identity-collapsed-into-management.md) records the MCA
`SubscriptionCountReachedLimit` wall hit on 2026-05-25 and the collapse
of Identity into Management. The same wall still blocks the two
workload subs the lab needs (`keystone-reelhouse-dev`,
`keystone-reelhouse-prod`).

Three days later (2026-05-28), the Microsoft quota-raise ticket is
still pending with no ETA. The workload track has been idle and is the
single biggest learning gap remaining — every platform piece built so
far (private DNS zones, custom RBAC, on-demand firewall, central
logging) exists *to be consumed by a workload*.

Eyal has a pre-existing MCA subscription named `lab-foundation` that:

- Predates Keystone (was already in the MCA before this lab started).
- Is **empty**: zero resources, zero resource groups (verified
  2026-05-28 via `az resource list` and `az group list`).
- Sits at **Tenant Root**: no MG association in any non-root MG
  (verified via `az account management-group entities list`).

It is, in other words, a perfect candidate for a *brownfield landing
zone adoption* — the pattern most real enterprises use when standing
up CAF Enterprise-Scale on top of pre-existing Azure footprint.

## Decision

Adopt `lab-foundation` into the Keystone management-group hierarchy
under `keystone-landing-zones-corp`, and use it as the host for
ReelHouse workload resources.

Concretely:

1. **`platform/10-management-groups`** gains a new variable
   `var.adopted_subscriptions` — a map of `{ alias =
   { subscription_id, target_mg } }`. A second `for_each` creates
   `azurerm_management_group_subscription_association` instances for
   adopted subs in parallel to the existing vended-subs `for_each`.
2. **`platform/20-management`** widens the `for_each` on budgets and
   cost exports to `merge(vended_subs, adopted_subs)` so adopted subs
   get the same monitoring envelope as vended ones. The cost-export
   storage and budget alert plumbing is identical.
3. **Workload layer** (`workloads/reelhouse/dev/`, when written) uses
   `lab-foundation` as its target. The workload layer's Terraform
   `provider` block authenticates to lab-foundation; the workload
   doesn't need to know it was adopted vs. vended.
4. **Sub remains named `lab-foundation`.** Renaming would orphan
   resources and break operator muscle memory; the Keystone naming
   convention applies to *resources*, not to a pre-existing sub name
   the lab inherited.
5. **Budget**: €50/mo soft cap on lab-foundation (smaller than
   platform-management's €100 because no firewall lives in workload).
   Alerts at 10/20/50/80/100%.
6. **Policy inheritance**: no exemptions. Once lab-foundation is under
   `keystone-landing-zones-corp`, every keystone-MG policy applies to
   it (allowed-locations, env-tag-enum, secure-transfer-audit,
   deny-storage-public, diag-storage-to-law). The workload is
   designed to comply with all of them.
7. **Single-env start.** Only `workloads/reelhouse/dev/` will be
   written initially. A second env (prod) is deferred until the
   quota raise lands and a real `keystone-reelhouse-prod` sub can be
   vended. Doubling cost on the lab's most expensive layer for the
   sake of directory-per-env symmetry isn't a worthwhile trade today.

## Consequences

**Positive:**

- **Unblocks the workload track immediately.** Every platform layer
  built so far gets to be exercised end-to-end against a real workload
  rather than sitting unused.
- Exercises the **canonical CAF brownfield-onboarding pattern** —
  declarative MG association of a sub that Terraform did not create.
  This is the dominant pattern in real enterprise ESLZ rollouts, where
  most subscriptions long predate the landing zone effort.
- **Drift visibility preserved**: the MG association is declared in
  Terraform, so portal-side moves of the sub show up in `terraform
  plan` as drift to reconcile. The same is true of budgets and cost
  exports.
- **Reversible**: if the MCA quota raise approves later, vend a
  dedicated `keystone-reelhouse-dev` sub and migrate the workload via
  `terraform state mv` + import. `lab-foundation` can then return to
  its previous role (or be retired through the
  `subscription-graveyard.md` process).

**Negative / trade-offs:**

- Sub name `lab-foundation` does not conform to the `keystone-*`
  naming convention. **Pre-rehearse for interviews:** the brownfield
  reality of ESLZ is that you rarely get to rename your sub
  inventory; you adopt names and govern the *resources* inside.
- Lab topology now mixes vended (`platform-management`,
  `platform-connectivity`) and adopted (`lab-foundation`)
  subscriptions. Some operator commands need to handle both classes
  — e.g. `make destroy-platform` correctly avoids 05-subscriptions
  (which contains only vended subs), but anything that walks all
  subs needs to consume the merged set.
- The `keystone-reelhouse-dev` and `keystone-reelhouse-prod` MG-slot
  placement in CLAUDE.md §3 / `subscription-topology.md` no longer
  reflects reality. Both subs are blocked; lab-foundation replaces
  reelhouse-dev for now.

**What this does NOT change:**

- The MG hierarchy from CLAUDE.md §2 is intact. `keystone-landing-zones-corp`
  is the target MG, as originally planned for workload subs.
- Policy posture is unchanged. Every existing policy inherits to
  lab-foundation automatically; no new policies, no exemptions.
- The workload's *internal* design (Container Apps, Postgres, Key
  Vault, etc.) is independent of which sub it lives in.

## Alternatives considered

- **Wait for the MCA quota raise via the open Microsoft support
  ticket.** Rejected: Microsoft support is slow with no ETA. The lab
  has productive learning to do today.
- **Collapse workload into `keystone-platform-management`.**
  Rejected: violates blast-radius separation — mixing platform
  control-plane resources with workload data-plane resources in the
  same sub defeats the entire point of ESLZ subscription topology.
  ADR-0011's "collapse Identity into Management" was tolerable
  because Identity has no runtime workload; that is not true here.
- **Cancel a vended sub (e.g. platform-connectivity) to free a slot.**
  Rejected hard per CLAUDE.md §3 and §7: 90-day quota lockup, no
  vended sub is safe to cancel, and `prevent_destroy = true`
  lifecycle blocks would have to be bypassed deliberately.
- **Vend the workload sub through a different MCA billing profile.**
  Not possible — the lab is on a single MCA.

## Deferred questions

- **Q5 from the design discussion** — *Where does the spoke VNet
  live? In `30-connectivity/` (hub team) or in `workloads/reelhouse/dev/`
  (workload team)?* The original wording in the discussion was
  ambiguous about layer ownership vs. resource ownership. This will
  be answered in its own (smaller) ADR when E4 of 30-connectivity
  starts, since the answer also dictates the layout of the workload
  layer's network section.

## Future revisit triggers

Revisit this ADR when:

- MCA quota raise is approved and `keystone-reelhouse-dev` /
  `keystone-reelhouse-prod` subs can be vended. At that point,
  migrate workload state and either retire `lab-foundation` or
  repurpose it for sandbox / experimentation.
- Workload reaches a point where dev and prod need to be hard-isolated
  by sub boundary (e.g. compliance scope, blast-radius drill). At
  that point, sharing one sub for both envs is no longer acceptable.
- Any future ADR needs to delete an MG-scoped policy that
  lab-foundation is currently relying on for compliance.

Until any of those fires, the adopted topology stands.
