# Subscription Topology

Maps the five Keystone subscriptions to their MG placement, role, and
lifecycle status. Per [CLAUDE.md §3](../CLAUDE.md).

## Target topology

| Subscription | Role | MG placement | Lifecycle status |
|---|---|---|---|
| `keystone-platform-management` | Log Analytics, diagnostic settings, cost exports, Terraform state SA | `keystone-platform-management` | **Vended 2026-05-21** (Phase 1) |
| `keystone-platform-connectivity` | Hub VNet, Firewall Basic, Private DNS zones | `keystone-platform-connectivity` | **Vended 2026-05-24** (Phase 2, targeted) |
| `keystone-platform-identity` | Custom RBAC, platform-scoped managed identities | `keystone-platform-identity` | Pending — MCA quota approved, ready to vend |
| `keystone-reelhouse-dev` | ReelHouse workload — dev | `keystone-landing-zones-corp` | Pending — MCA quota approved, ready to vend |
| `keystone-reelhouse-prod` | ReelHouse workload — prod | `keystone-landing-zones-corp` | Pending — MCA quota approved, ready to vend |

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

### Phase 2 — still pending

- `keystone-platform-identity` — vend before applying
  `platform/40-identity`.
- `keystone-reelhouse-dev` — vend before deploying the dev
  workload.
- `keystone-reelhouse-prod` — vend last, after dev workload runs
  end-to-end.

All three are quota-cleared; the gate now is "do we need it yet?"

## Lifecycle rules

Per [CLAUDE.md §7](../CLAUDE.md):

- Subscription shells are long-lived. Do not cancel or recreate them.
- Cancelled MCA subs count against quota for **90 days** before they are fully purged.
- `prevent_destroy = true` on every `azurerm_subscription` resource in `platform/05-subscriptions`.
- `make destroy-platform` and `make destroy-workload` explicitly exclude the `05-subscriptions` layer.
- If a subscription genuinely needs to be retired, log it in `docs/subscription-graveyard.md` with the cancellation date so the 90-day clock is visible.
