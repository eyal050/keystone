# `platform/20-management`

The Keystone management plane: centralised logging, diagnostic-settings
enforcement, MCA cost data export, per-subscription budget alerts. All
hosted in the `keystone-platform-management` subscription.

Per [CLAUDE.md §2 / §3](../../CLAUDE.md), this is where every Keystone
resource's diagnostic settings forward to and where MCA cost data lands
as a daily blob export.

## Layer is built in sub-chunks

| Sub-chunk | Status | Contents |
|---|---|---|
| **F1** | ✅ landed | Log Analytics workspace + its RG |
| **F2** | pending | `DeployIfNotExists` diagnostic-settings policy + managed identity role assignment — the [CLAUDE.md §8](../../docs/break-debug-log.md) break/debug scenario |
| **F3** | pending | MCA cost data → daily blob export → state SA |
| **F4** | pending | Per-subscription budget alerts (€100 workload, €900 connectivity, €20 other) per CLAUDE.md §7 |

## What F1 created

- **Resource group** `rg-platmgmt-weu-001` in westeurope.
- **Log Analytics workspace** `log-platmgmt-weu-001`, SKU `PerGB2018`,
  90-day retention, 1 GB/day daily quota (lab-safety circuit-breaker).

Cost shape: **consumption-only**. ~€2.50/GB ingested in westeurope.
Retention beyond 30 days adds ~€0.10/GB/mo for the retained data. Lab
volumes are expected to be <1 GB/mo once F2 lights up diagnostic
settings, so realised cost ≈ a few euro/month.

## Run procedure

```bash
cd ~/repos/keystone/platform/20-management

source ~/.keystone/secrets.env
export TF_VAR_tenant_id="$KEYSTONE_TENANT_ID"
export TF_VAR_mgmt_subscription_id="$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID"

terraform init \
  -backend-config="subscription_id=$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID" \
  -backend-config="tenant_id=$KEYSTONE_TENANT_ID" \
  -backend-config="resource_group_name=rg-tfstate-plat-weu-001" \
  -backend-config="storage_account_name=$KEYSTONE_STATE_STORAGE_ACCOUNT_NAME" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=platform-20-management.tfstate"

terraform plan
terraform apply
```

## Lifecycle protections

- `prevent_destroy = true` on the RG and the LAW. Destroying the LAW
  would orphan every diagnostic setting pointing at it across the
  hierarchy.
- `permanently_delete_on_destroy = true` in the provider's
  `log_analytics_workspace` features block. Soft-deleted workspaces
  hold their name for 30 days; permanent delete avoids the recovery
  block at the cost of giving up the recovery window — acceptable for
  a lab.

## Why daily_quota_gb = 1?

`PerGB2018` charges per byte ingested. Without a cap, a misconfigured
diagnostic setting can produce hundreds of GB/day of low-value logs.
The lab budget would not survive €200+/day surprises.

The cap is a circuit-breaker, not a target. At expected lab volumes
(<1 GB/mo total), we're three orders of magnitude under the daily cap.
If the cap ever fires (workspace stops accepting new data for the rest
of the UTC day), that itself is a signal that something is generating
more logs than expected — break/debug territory.
