# `platform/10-management-groups`

Keystone's CAF-aligned management-group hierarchy plus subscription-to-MG
associations. Hand-rolled per [ADR-0004](../../docs/decisions/0004-mg-policy-hand-rolled-then-evaluate-module.md).

This layer does **not** create policy definitions or assignments — those
land in subsequent chunks. The hierarchy must exist first so policy can
target it.

## What this layer creates

**9 management groups:**

```
Tenant Root
└── keystone                                      (Top-Level)
    ├── keystone-platform                         (Platform)
    │   ├── keystone-platform-connectivity        (Platform — Connectivity)
    │   ├── keystone-platform-management          (Platform — Management)
    │   └── keystone-platform-identity            (Platform — Identity)
    ├── keystone-landing-zones                    (Landing Zones)
    │   └── keystone-landing-zones-corp           (Landing Zones — Corp)
    ├── keystone-decommissioned                   (Decommissioned)
    └── keystone-sandbox                          (Sandbox)
```

**N subscription-to-MG associations**, where N depends on how many subs
`platform/05-subscriptions` has currently vended:

- Phase 1 → 1 association (`keystone-platform-management` → `keystone-platform-management` MG)
- Phase 2 → 5 associations (the four post-quota subs join the dev/prod workload MG and their respective platform MGs)

Associations are driven by reading `platform/05-subscriptions`'
`subscriptions` output via `terraform_remote_state`, so this layer
automatically picks up new subs as they are vended — no code edit
needed between phases.

## Required permissions

The identity running `terraform apply` here needs **Management Group
Contributor** at Tenant Root (or higher: Global Admin via Privileged
Identity Management). Creating the top-level `keystone` MG under Tenant
Root requires explicit elevation if you do not have it by default:

```bash
az role assignment create \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --role "Management Group Contributor" \
  --scope "/"
```

(Run as Global Admin once; it persists.)

## Run procedure

```bash
cd ~/repos/keystone/platform/10-management-groups

source ~/.keystone/secrets.env
export TF_VAR_tenant_id="$KEYSTONE_TENANT_ID"
export TF_VAR_mgmt_subscription_id="$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID"
export TF_VAR_state_storage_account_name="$KEYSTONE_STATE_STORAGE_ACCOUNT_NAME"

terraform init \
  -backend-config="subscription_id=$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID" \
  -backend-config="tenant_id=$KEYSTONE_TENANT_ID" \
  -backend-config="resource_group_name=rg-tfstate-plat-weu-001" \
  -backend-config="storage_account_name=$KEYSTONE_STATE_STORAGE_ACCOUNT_NAME" \
  -backend-config="container_name=tfstate" \
  -backend-config="key=platform-10-management-groups.tfstate"

terraform plan
terraform apply
```

## Hardening worth knowing

Three guards against the 2026-05-21 wrong-sub incident class:

1. **GUID format validation** on `tenant_id` and `mgmt_subscription_id` —
   fails plan if either is empty or malformed.
2. **`data.azurerm_subscription.mgmt` precondition** on the top-level MG
   — fails plan if the auth-context sub does not resolve to
   `keystone-platform-management`.
3. **`sub_alias_to_mg` precondition** on each subscription association
   — fails plan if a new alias appears in `05-subscriptions` outputs
   without a matching entry here. Better than silently associating a
   workload sub to whichever MG happens to come first in the map.

## What this layer deliberately does not do

- **No policy.** `platform/10-management-groups` only builds the
  structure. Policy definitions and assignments land in subsequent
  chunks (likely numbered `15-policy-definitions` and `16-policy-assignments`).
- **No RBAC.** Custom role definitions and role assignments live in
  `platform/40-identity`. Built-in role assignments at MG scope (e.g.,
  Contributor on `keystone-platform` for the platform team identity)
  also belong there once Identity is up.
- **No move of pre-existing subs.** Subscriptions Eyal had before
  Keystone (e.g. `guardianlink-prod`) stay where they are — Keystone
  manages only its own vended subs. If a pre-existing sub needs to be
  brought under Keystone governance, it is a deliberate decision
  documented as an ADR.

## Drift to watch for

Per CLAUDE.md §3, a sub silently reverting to Tenant Root scope (e.g.,
because someone moved it via the portal) is a P1 — that is the exact
governance failure ESLZ exists to prevent.

After every apply, run:

```bash
terraform plan
```

If it proposes recreating an association you did not change, look at
Azure Activity Log for `Microsoft.Management/managementGroups/subscriptions/delete`
events.
