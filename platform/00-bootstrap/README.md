# `platform/00-bootstrap`

Creates the Terraform state storage account that every other Keystone
layer uses as its remote backend. See [ADR-0007](../../docs/decisions/0007-state-storage-in-platform-management.md).

## What this layer creates

- Resource group: `rg-tfstate-plat-weu-001` (location per ADR-0002)
- Storage account: `sttfstateplat<region><random>` (name globally unique)
- Blob container: `tfstate` — every layer's state file lives here under
  key `<layer>.tfstate`.

Storage account posture in this first pass:

- TLS 1.2 minimum, public blob access disabled.
- Blob versioning + 30-day soft-delete on blobs and containers.
- GRS replication.
- `network_rules.default_action = "Allow"` — public-network-accessible
  for now, because the connectivity layer that would provide a private
  endpoint does not yet exist. Tightening to `Deny` + private endpoint
  is a deliberate later step (see TODO in `main.tf`).

## Prerequisite: vend `keystone-platform-management` first

This layer cannot be applied until `platform/05-subscriptions` has
vended the Management subscription. Per [ADR-0009](../../docs/decisions/0009-subscription-staging-management-first.md),
that vend is Phase 1 of the staging plan.

After 05 vends the Management sub, capture its subscription ID into
`~/.keystone/secrets.env`:

```bash
# Append to ~/.keystone/secrets.env
export KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID="<sub-id-from-05-output>"
```

Then `source ~/.keystone/secrets.env` so the value is available.

## First apply — local backend

```bash
cd platform/00-bootstrap

source ~/.keystone/secrets.env
export TF_VAR_tenant_id="$KEYSTONE_TENANT_ID"
export TF_VAR_mgmt_subscription_id="$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID"

terraform init      # uses backend "local" — state in this directory
terraform plan
terraform apply
```

After this completes, the state SA + container exist and the local
`terraform.tfstate` file contains the layer's state.

## Second init — migrate state to remote

Edit `backend.tf`:

- Comment out the `backend "local"` block.
- Uncomment the `backend "azurerm"` block.

Then run:

```bash
terraform init -migrate-state \
  -backend-config="resource_group_name=$(terraform output -raw tfstate_resource_group_name)" \
  -backend-config="storage_account_name=$(terraform output -raw tfstate_storage_account_name)" \
  -backend-config="container_name=$(terraform output -raw tfstate_container_name)" \
  -backend-config="key=platform-00-bootstrap.tfstate"
```

Terraform will copy the local state into the new SA. Confirm with:

```bash
terraform state list
```

Same resources should appear. Then delete the local files:

```bash
rm terraform.tfstate terraform.tfstate.backup
```

Commit the `backend.tf` change to the repo.

## State-key convention

Every Keystone layer's state file lives in the `tfstate` container,
named `<layer>.tfstate`:

| Layer | State key |
|---|---|
| `platform/00-bootstrap` | `platform-00-bootstrap.tfstate` |
| `platform/05-subscriptions` | `platform-05-subscriptions.tfstate` |
| `platform/10-management-groups` | `platform-10-management-groups.tfstate` |
| `platform/20-management` | `platform-20-management.tfstate` |
| `platform/30-connectivity` | `platform-30-connectivity.tfstate` |
| `platform/40-identity` | `platform-40-identity.tfstate` |
| `workloads/reelhouse/dev` | `workloads-reelhouse-dev.tfstate` |
| `workloads/reelhouse/prod` | `workloads-reelhouse-prod.tfstate` |

## Lifecycle protection

`prevent_destroy = true` is set on:

- `azurerm_resource_group.tfstate`
- `azurerm_storage_account.tfstate`

`terraform destroy` against this layer will fail by design. To genuinely
retire the bootstrap layer (e.g. after migrating state to a new region),
remove the lifecycle blocks in a deliberate commit and document the
rationale in an ADR.
