# ADR-0011: Identity layer collapses into Management subscription

- **Status**: Accepted
- **Date**: 2026-05-25
- **Decider**: Eyal
- **Supersedes**: —
- **Revises**: the topology described in [CLAUDE.md §3](../../CLAUDE.md) and the staging plan in [ADR-0009](0009-subscription-staging-management-first.md), to the extent that they assume a separate `keystone-platform-identity` subscription

## Context

CLAUDE.md §3 defines the target subscription topology with five subs,
including `keystone-platform-identity` for custom RBAC role definitions
and platform-scoped managed identities. CLAUDE.md §3 also explicitly
anticipates this exact failure mode:

> *"MCA tenants have soft quotas, typically around 5 active subscriptions
> per billing profile by default. (and Eyal already has 4 subscriptions
> in his MCA account)"*

> *"If MCA quota becomes a real constraint mid-lab, collapse Identity
> into Management as the first compromise."*

On 2026-05-25, while opening `platform/40-identity`, `make vend-sub
ALIAS=platform-identity` failed at the Azure API with:

```
Error: creating new Subscription (Alias "platform-identity"):
  Code="NotAllowed" Message="Couldn't create subscription. Your
  account has reached its subscription limit."
  Code="SubscriptionCountReachedLimit"
```

The vend never reached Terraform state — the failure was at the
upstream API. No cleanup was needed.

## Decision

`platform/40-identity` operates **from `keystone-platform-management`**,
at management-group scope. There is **no `keystone-platform-identity`
subscription**.

Concretely:

- `platform/40-identity/providers.tf` uses
  `subscription_id = var.mgmt_subscription_id`.
- The layer's state file (`platform-40-identity.tfstate`) is stored
  in the same SA in `keystone-platform-management` as every other
  layer's state.
- Custom RBAC role definitions are scoped at management-group level
  (e.g. `keystone-landing-zones` for spoke-network roles) — they
  don't *need* a home subscription, the role definition resource
  lives in the MG hierarchy regardless of which sub the Terraform
  provider is authenticated to.
- The `keystone-platform-identity` **management group still exists**
  (created by `platform/10-management-groups`). It's currently empty.
  If/when an identity-specific sub becomes available, the MG is
  ready to receive it without code changes elsewhere.

## Consequences

**Positive:**

- Unblocks `platform/40-identity` today without waiting for an Azure
  support ticket. MCA quota raise is a multi-day process at best.
- Saves 1 MCA sub slot for the actual workload subs
  (`keystone-reelhouse-dev`, `keystone-reelhouse-prod`), which is
  where the lab's learning value lives.
- The custom role definition pattern is **identical** under collapse:
  same `azurerm_role_definition` resources, same MG-scoped
  `assignable_scopes`, same Terraform muscle exercised.
- Reversible — if quota is raised later, vend the identity sub and
  move the layer's state with a `terraform state mv` step. The
  custom roles don't need to move (they're at MG scope, not
  sub scope).

**Negative / trade-offs:**

- Lab topology diverges from the CAF Enterprise-Scale reference
  architecture, which expects identity to live in its own sub.
  **Pre-rehearse for interviews:** be ready to articulate this as
  *"the reference topology has a dedicated identity sub for blast-radius
  isolation; in my personal lab I collapsed it into Management due to
  MCA quota, but the role definitions themselves are MG-scoped and
  identical to what they'd be in a dedicated sub."*
- A *future* RBAC scenario that needs sub-scoped identity resources
  (e.g. a centralized identity-team-only Key Vault) would need to be
  either deferred or hosted in Management with explicit access
  separation. None of the planned lab roles need this.
- The `keystone-platform-identity` MG is empty — a real ESLZ would
  not have an empty MG. Acceptable as scaffolding for the eventual
  vend.

**What this does NOT change:**

- The MG hierarchy from CLAUDE.md §2 is intact; the identity MG
  still exists.
- ADR-0009's "vend Management first, others as needed" principle is
  preserved. This is just one of those "others" being declined for
  now.
- Custom role definitions are still the substance of 40-identity —
  same code regardless of sub layout.

## Alternatives considered

- **Wait for MCA quota raise via Azure support ticket.** Rejected:
  multi-day delay with no guarantee of approval, and the lab has
  productive work to do today that doesn't depend on the identity
  sub existing.
- **Cancel a vended sub to free a slot.** Rejected hard: CLAUDE.md
  §3 prohibits — cancelled MCA subs lock the slot for 90 days, and
  there is no sub safe to cancel. Every currently-vended sub
  (`platform-management`, `platform-connectivity`) is load-bearing.
- **Defer 40-identity entirely until quota is raised.** Rejected:
  custom RBAC definitions are part of the CAF baseline (CLAUDE.md
  §2) and don't need a separate sub. Deferring would leave the
  ESLZ baseline incomplete for no learning gain.

## Future revisit triggers

Revisit this ADR when:

- MCA quota is raised and ≥1 sub slot is available.
- A specific identity workload (e.g. a centralized PIM
  configuration, an identity-team-only Key Vault) needs the
  blast-radius separation a dedicated sub provides.
- Workload subs (`reelhouse-dev`, `reelhouse-prod`) get vended and
  it becomes operationally awkward to share Management with both
  platform-management functions and identity-management functions.

Until any of those fires, the collapsed topology stands.
