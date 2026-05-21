# ADR-0007: Terraform state storage account lives in `keystone-platform-management`

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

Every Terraform layer needs a state backend. For a multi-layer ESLZ
build, three placement options were considered:

1. State SA in `keystone-platform-management`.
2. State SA in a dedicated bootstrap subscription outside the MG
   hierarchy.
3. State SA in `keystone-platform-connectivity`.

There is also a chicken-and-egg constraint: the very first Terraform
layer (`platform/00-bootstrap`) creates the state SA, but it needs
*somewhere* to keep its own state until the SA exists.

## Decision

**State SA lives in `keystone-platform-management`**, alongside the
Log Analytics workspace, cost exports, and the rest of the management
plane.

The bootstrap chicken-and-egg is resolved by:

1. `platform/00-bootstrap` initially uses a **local** backend (state file
   on Eyal's laptop). This run vends nothing in Azure that depends on
   remote state.
2. `platform/05-subscriptions` then vends `keystone-platform-management`.
3. `platform/00-bootstrap` is re-run with a remote backend pointed at
   the new SA, and the local state is migrated via `terraform init -migrate-state`.
4. Local state file is deleted from Eyal's laptop after migration is
   confirmed.

The migration is a one-time operational step, documented in
`platform/00-bootstrap/README.md` (to be written in Chunk C).

## Consequences

**Positive:**

- State lives with the rest of the management plane (Log Analytics,
  diagnostic settings, cost exports). Conceptually consistent: state
  is platform metadata, the Management sub holds platform metadata.
- No quota slot burned on a "bootstrap-only" subscription.
- The chicken-and-egg migration is itself a learning moment — it
  forces a deliberate understanding of where state lives and why.

**Negative / trade-offs:**

- One-time complexity: the bootstrap layer is run twice (local then
  remote-migrated). Documentation must spell out the sequence so a
  fresh reader can reconstruct the project.
- Deleting `keystone-platform-management` would destroy state for every
  other layer. Mitigated by `prevent_destroy = true` on the sub and on
  the state SA + container, and by the lifecycle rules in CLAUDE.md §7.

## Alternatives considered

- **Dedicated bootstrap subscription** — rejected. Burns 1 of the 5 MCA
  quota slots on something that does not exercise an ESLZ pattern. The
  conceptual cleanliness is not worth the quota cost.
- **State SA in `keystone-platform-connectivity`** — rejected. State has
  no architectural relationship to the firewall/VNet plane; placing it
  there is arbitrary.
- **State on a workload sub** — rejected. State outliving any one
  workload means it must live in the platform plane, not in the workload.
