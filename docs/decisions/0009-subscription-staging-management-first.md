# ADR-0009: Stage subscription vending — Management first, others post-quota

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

CLAUDE.md §3 targets five Terraform-vended subscriptions:

1. `keystone-platform-management`
2. `keystone-platform-connectivity`
3. `keystone-platform-identity`
4. `keystone-reelhouse-dev`
5. `keystone-reelhouse-prod`

The MCA billing profile in use has a soft cap of ~5 active subscriptions
per profile and already holds 4 pre-Keystone subscriptions. Vending all
five new subs at once requires either a quota increase or a topology
compromise (collapsing Identity into Management per §3's fallback note).

Two further constraints apply:

- Cancelled MCA subscriptions count against quota for **90 days** before
  they are fully purged. Freeing a slot by cancellation is a 90-day
  operation, not an immediate one.
- The bootstrap chicken-and-egg (ADR-0007) requires the Management sub
  to exist before remote Terraform state can live anywhere useful.

## Decision

**Stage the subscription vending in two phases.**

**Phase 1 — within current quota (1 sub):**

- Raise an MCA subscription quota increase support ticket immediately.
  Ticket date recorded in `docs/subscription-topology.md` (ticket number
  tracked outside the repo).
- Vend `keystone-platform-management` (uses the 5th and final slot in
  the current quota).
- This unblocks `platform/00-bootstrap` → state migration → `platform/20-management`.

**Phase 2 — once the quota ticket is approved:**

- Vend the remaining four subs in this order:
  1. `keystone-platform-connectivity` (unblocks `platform/30-connectivity`)
  2. `keystone-platform-identity` (unblocks `platform/40-identity`)
  3. `keystone-reelhouse-dev` (unblocks workload work)
  4. `keystone-reelhouse-prod` (last to vend; protects prod from iteration churn)

All five subscriptions are written in `platform/05-subscriptions/` as
Terraform code from day 1; the phasing is achieved by **applying** in
two passes (Phase 1 applies the `keystone-platform-management` target,
Phase 2 applies the rest).

`prevent_destroy = true` is set on every `azurerm_subscription` resource
to guard against accidental cancellation.

## Consequences

**Positive:**

- Building can start immediately on `platform/00-bootstrap` and the
  Management subscription's downstream layers, rather than blocking on
  a 1–3 business-day support ticket.
- Subscription order matches the layer dependency order (Management → state →
  Connectivity / Identity → workloads), so Phase 2 enables natural
  forward progress.
- All five sub definitions exist as code from day 1. Targeted applies
  achieve the phasing without conditional/feature-flag complexity.

**Negative / trade-offs:**

- Tooling needs to handle a partial topology gracefully. For example:
  - `platform/10-management-groups` runs in Phase 1 with only Management
    associable; the other four `azurerm_management_group_subscription_association`
    resources are commented out / `count = 0`'d until Phase 2.
  - Cost dashboards built in Phase 1 cover only Management; they fan out
    as more subs land.
- The quota ticket is on the critical path for the workload tier. If
  it's denied, the fallback is collapsing Identity into Management
  (per CLAUDE.md §3), documented as a new ADR if it triggers.

## Alternatives considered

- **Vend all 5 immediately** — rejected. Exceeds current MCA quota by 4.
- **Wait for the ticket before vending anything** — rejected. Blocks
  1–3 business days of buildable work for no upside.
- **Cancel existing subs to free quota** — rejected. 90-day count-against
  rule means cancellation does not free quota in time.
- **Collapse Identity into Management upfront** — deferred. Held as the
  Phase-2 fallback if the quota ticket is denied. Skipped now because
  it sacrifices learning surface (custom RBAC + managed identity
  separation is part of why Identity exists as its own sub) for a
  problem that may not materialise.
