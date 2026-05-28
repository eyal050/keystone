# Subscription Topology

Maps the five Keystone subscriptions to their MG placement, role, and
lifecycle status. Per [CLAUDE.md §3](../CLAUDE.md).

## Target topology

| Subscription | Role | MG placement | Lifecycle status |
|---|---|---|---|
| `keystone-platform-management` | Log Analytics, diagnostic settings, cost exports, Terraform state SA | `keystone-platform-management` | **Vended 2026-05-21** (Phase 1) |
| `keystone-platform-connectivity` | Hub VNet, Firewall Basic, Private DNS zones | `keystone-platform-connectivity` | **Vended 2026-05-24** (Phase 2, targeted) |
| `keystone-platform-identity` | Custom RBAC, platform-scoped managed identities | `keystone-platform-identity` (MG) | **Blocked at MCA quota 2026-05-25** — Identity collapsed into Management per [ADR-0011](decisions/0011-identity-collapsed-into-management.md). MG remains for future adoption. |
| `keystone-reelhouse-dev` | ReelHouse workload — dev | `keystone-landing-zones-corp` | Blocked at MCA quota. **2026-05-28: workaround chosen — adopt existing `lab-foundation` MCA sub into `keystone-landing-zones-corp` instead of vending a new sub.** |
| `keystone-reelhouse-prod` | ReelHouse workload — prod | `keystone-landing-zones-corp` | Blocked at MCA quota. May share the adopted `lab-foundation` sub with dev to start; promote to a dedicated sub if/when quota raise is approved. |
| `lab-foundation` *(pre-existing, not Terraform-vended)* | Workload host (adopted) | `keystone-landing-zones-corp` (target) | **Adoption planned 2026-05-28.** Pre-existed in Eyal's MCA before Keystone. Currently outside the MG hierarchy; to be moved under `keystone-landing-zones-corp` via the brownfield adoption pattern (forthcoming ADR). |

## MG hierarchy

```
Tenant Root
└── keystone (top-level MG)
    ├── keystone-platform
    │   ├── keystone-platform-connectivity   → keystone-platform-connectivity
    │   ├── keystone-platform-management     → keystone-platform-management
    │   └── keystone-platform-identity       → keystone-platform-identity
    ├── keystone-landing-zones
    │   └── keystone-landing-zones-corp      → keystone-reelhouse-dev, keystone-reelhouse-prod
    ├── keystone-decommissioned              (empty initially)
    └── keystone-sandbox                     (empty initially)
```

## MCA quota status

- Pre-Keystone subs in Eyal's MCA: 4.
- MCA soft cap: 5 active subscriptions per billing profile.
- Keystone needs: 5 new subscriptions (total active would be 9).
- Quota increase support ticket: raised 2026-05-21 (number tracked outside the repo).
- Staging plan: vend `keystone-platform-management` immediately
  (5/5 slot, within current cap); vend the remaining four once the
  quota ticket is approved.

### Phase 1 — applied 2026-05-21

`platform/05-subscriptions` applied with `vend_phase = "phase-1"`.
`keystone-platform-management` is now active and at 5/5 of the
then-current MCA quota. Sub ID captured into `~/.keystone/secrets.env`
as `KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID`.

### Phase 2 — partially applied 2026-05-24

MCA quota increase ticket landed (raised 2026-05-21, approved within
72 hours). Targeted vend of `keystone-platform-connectivity` only:

```bash
terraform apply -var="vend_phase=phase-2" \
  -target='azurerm_subscription.this["platform-connectivity"]'
```

`-target` was used so the remaining three subs (identity + two
workload subs) stay pending until each is genuinely needed —
vending speculatively burns realised cost as soon as resources
land inside, and the connectivity sub is the only one
`platform/30-connectivity` requires for now.

After apply, the connectivity sub ID was captured into
`~/.keystone/secrets.env` as
`KEYSTONE_PLATFORM_CONNECTIVITY_SUBSCRIPTION_ID`.

### Phase 2 continuation — blocked 2026-05-25

Attempted `make vend-sub ALIAS=platform-identity` and hit the MCA
`SubscriptionCountReachedLimit` API error. The previous quota raise
landed only 1 additional slot (used by `platform-connectivity`); the
account is back at the cap with no more slots free.

Reactions:

- **`platform/40-identity` no longer waits.** Per
  [ADR-0011](decisions/0011-identity-collapsed-into-management.md), the
  identity layer operates from `keystone-platform-management` at MG
  scope. Custom role definitions don't need a home sub. The
  `keystone-platform-identity` MG stays empty for now, available for
  future adoption if quota is later raised.
- **Workload track unblocked via adoption (2026-05-28).** Rather than
  wait for the quota ticket, ReelHouse will adopt the pre-existing
  `lab-foundation` sub into `keystone-landing-zones-corp`. This
  exercises the canonical CAF brownfield onboarding pattern — arguably
  more useful for interview prep than another fresh vend.
- **Quota raise ticket open with Microsoft;** ETA "slow." If/when
  approved, the dedicated identity + reelhouse subs can still be
  vended — they're orthogonal to the adoption path.

## Lifecycle rules

Per [CLAUDE.md §7](../CLAUDE.md):

- Subscription shells are long-lived. Do not cancel or recreate them.
- Cancelled MCA subs count against quota for **90 days** before they are fully purged.
- `prevent_destroy = true` on every `azurerm_subscription` resource in `platform/05-subscriptions`.
- `make destroy-platform` and `make destroy-workload` explicitly exclude the `05-subscriptions` layer.
- If a subscription genuinely needs to be retired, log it in `docs/subscription-graveyard.md` with the cancellation date so the 90-day clock is visible.
