# Subscription Topology

Maps the five Keystone subscriptions to their MG placement, role, and
lifecycle status. Per [CLAUDE.md §3](../CLAUDE.md).

## Target topology

| Subscription | Role | MG placement | Lifecycle status |
|---|---|---|---|
| `keystone-platform-management` | Log Analytics, diagnostic settings, cost exports, Terraform state SA | `keystone-platform-management` | **Pending vending (first)** — within current MCA quota |
| `keystone-platform-connectivity` | Hub VNet, Firewall Basic, Private DNS zones | `keystone-platform-connectivity` | Pending — blocked on MCA quota increase |
| `keystone-platform-identity` | Custom RBAC, platform-scoped managed identities | `keystone-platform-identity` | Pending — blocked on MCA quota increase |
| `keystone-reelhouse-dev` | ReelHouse workload — dev | `keystone-landing-zones-corp` | Pending — blocked on MCA quota increase |
| `keystone-reelhouse-prod` | ReelHouse workload — prod | `keystone-landing-zones-corp` | Pending — blocked on MCA quota increase |

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

## Lifecycle rules

Per [CLAUDE.md §7](../CLAUDE.md):

- Subscription shells are long-lived. Do not cancel or recreate them.
- Cancelled MCA subs count against quota for **90 days** before they are fully purged.
- `prevent_destroy = true` on every `azurerm_subscription` resource in `platform/05-subscriptions`.
- `make destroy-platform` and `make destroy-workload` explicitly exclude the `05-subscriptions` layer.
- If a subscription genuinely needs to be retired, log it in `docs/subscription-graveyard.md` with the cancellation date so the 90-day clock is visible.
