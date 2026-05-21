# `platform/05-subscriptions`

Vends the five Keystone subscriptions against the MCA billing scope.
See [ADR-0009](../../docs/decisions/0009-subscription-staging-management-first.md)
for the staging plan and [CLAUDE.md §3](../../CLAUDE.md) for the MCA
context.

## Subscriptions vended

| Alias | Subscription name | Workload | Phase |
|---|---|---|---|
| `platform-management` | `keystone-platform-management` | `Production` | 1 |
| `platform-connectivity` | `keystone-platform-connectivity` | `Production` | 2 |
| `platform-identity` | `keystone-platform-identity` | `Production` | 2 |
| `reelhouse-dev` | `keystone-reelhouse-dev` | `DevTest` | 2 |
| `reelhouse-prod` | `keystone-reelhouse-prod` | `Production` | 2 |

All five live in `locals.tf` as one map. The phasing is achieved by
`var.vend_phase` selecting which entries appear in the `for_each` map
on `azurerm_subscription.this`; the code itself is identical between
phases.

## Lifecycle protections

Every `azurerm_subscription` carries:

- `prevent_destroy = true` — `terraform destroy` against this layer
  fails by design. Belt-and-suspenders for CLAUDE.md §7's "never cancel
  a subscription" rule.
- `ignore_changes = [billing_scope_id]` — once vended, a sub's billing
  scope is not edited via this resource. Re-pointing to a different
  invoice section requires explicit code action.

## Phase 1: vend Management (run now)

```bash
cd platform/05-subscriptions

source ~/.keystone/secrets.env
export TF_VAR_tenant_id="$KEYSTONE_TENANT_ID"
export TF_VAR_vending_subscription_id="$KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID"
export TF_VAR_billing_scope_id="$KEYSTONE_MCA_BILLING_SCOPE_ID"

terraform init     # local backend
terraform plan     # should propose 1 sub: keystone-platform-management
terraform apply
```

After apply completes, capture the new sub's ID into
`~/.keystone/secrets.env`:

```bash
MGMT_SUB_ID="$(terraform output -raw mgmt_subscription_id)"
echo "export KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID=\"$MGMT_SUB_ID\"" \
  >> ~/.keystone/secrets.env
unset MGMT_SUB_ID
source ~/.keystone/secrets.env
```

`platform/00-bootstrap` can now be applied against the new sub.

## State migration (after `platform/00-bootstrap` is applied + migrated)

Once `00-bootstrap` has migrated its own state to the remote SA, do the
same for this layer:

1. Edit `backend.tf`: comment out the `local` block, uncomment the
   `azurerm` block.
2. Run:
   ```bash
   terraform init -migrate-state \
     -backend-config="resource_group_name=$(cd ../00-bootstrap && terraform output -raw tfstate_resource_group_name)" \
     -backend-config="storage_account_name=$(cd ../00-bootstrap && terraform output -raw tfstate_storage_account_name)" \
     -backend-config="container_name=tfstate" \
     -backend-config="key=platform-05-subscriptions.tfstate"
   ```
3. Confirm via `terraform state list`; delete local `terraform.tfstate*`.

## Phase 2: vend remaining four (after MCA quota ticket approved)

```bash
source ~/.keystone/secrets.env
export TF_VAR_tenant_id="$KEYSTONE_TENANT_ID"
export TF_VAR_vending_subscription_id="$KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID"
export TF_VAR_billing_scope_id="$KEYSTONE_MCA_BILLING_SCOPE_ID"

terraform plan  -var="vend_phase=phase-2"   # should propose +4 subs
terraform apply -var="vend_phase=phase-2"
```

After apply, capture the new sub IDs and append them to
`~/.keystone/secrets.env` (variable names per `docs/secrets-inventory.md`):

```bash
terraform output -json subscriptions
```

The output is a map keyed by alias; pull the `id` field for each.

## What this layer deliberately does not do

- It does **not** associate subscriptions to management groups. That
  belongs to `platform/10-management-groups` and is set declaratively
  there via `azurerm_management_group_subscription_association`.
- It does **not** configure RBAC, policy, or diagnostic settings on the
  vended subs. Each later layer handles its own scope.

## Failure modes worth pre-rehearsing for an interview

- **MCA quota exceeded.** Phase 2 apply will fail at the third or fourth
  sub if the quota ticket has not been approved. Symptoms: the first
  sub or two apply successfully, then a `quota exceeded` error. Recovery
  is to wait for the ticket or remove already-applied subs from the
  state (without cancelling them) — they are kept, the partial apply
  is just not surfaced.
- **Drift: sub manually moved to Tenant Root.** Caught on next plan as
  a no-op against this layer (it does not manage MG placement) but
  surfaces as drift in `platform/10-management-groups`. CLAUDE.md §3
  treats this as a P1.
