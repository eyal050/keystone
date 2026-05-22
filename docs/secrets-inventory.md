# Secrets Inventory

This file is the source of truth for **what sensitive values Keystone needs**
and how to obtain each one. Per [CLAUDE.md §6](../CLAUDE.md), no actual values
appear here — only names and retrieval instructions.

If you are cloning this repo onto a new laptop, this file is your setup
checklist. Walk through each entry in order; once `~/.keystone/secrets.env`
is populated, the local Terraform commands are ready to run.

## Where secrets live

Two locations only:

1. **Your laptop**, at `~/.keystone/secrets.env` (file `600`, directory `700`).
   Source it before any `terraform` or `az` command:
   ```bash
   source ~/.keystone/secrets.env
   ```
2. **GitHub Actions secrets**, scoped to the appropriate GitHub Environment.

The local file and the CI secret must hold the **same value** for each
variable. Drift between them is its own bug class.

## Inventory

### `KEYSTONE_TENANT_ID`

Microsoft Entra ID tenant ID for the Azure tenant this lab runs in.

- **Purpose**: identifies the tenant the `azurerm` provider authenticates against.
- **Retrieve**:
  ```bash
  az account show --query tenantId -o tsv
  ```
- **Format**: GUID (`00000000-0000-0000-0000-000000000000`).
- **CI scope**: every GitHub Environment uses this. Promote to repo-level secret once CI lands.

### `KEYSTONE_MCA_BILLING_ACCOUNT_ID`

Microsoft Customer Agreement billing account ID.

- **Purpose**: parent of the billing profile; needed when looking up profiles and invoice sections.
- **Retrieve**:
  ```bash
  az billing account list --query "[].{Name:displayName, ID:name}" -o table
  ```
- **Format**: `<guid>:<guid>_<date>`.
- **CI scope**: `platform-subscriptions` environment only (consumed by `platform/05-subscriptions`).

### `KEYSTONE_MCA_BILLING_PROFILE_ID`

Full ARM path of the MCA billing profile.

- **Purpose**: parent of the invoice section; needed to list invoice sections.
- **Retrieve** (uses `KEYSTONE_MCA_BILLING_ACCOUNT_ID`):
  ```bash
  az billing profile list \
    --account-name "$KEYSTONE_MCA_BILLING_ACCOUNT_ID" \
    --query "[].{Name:displayName, ID:id}" -o table
  ```
- **Format**: `/providers/Microsoft.Billing/billingAccounts/.../billingProfiles/...`
- **CI scope**: `platform-subscriptions` environment only.

### `KEYSTONE_MCA_BILLING_SCOPE_ID`

Full ARM path of the MCA invoice section. **This is the `billing_scope_id`
that Terraform passes to `azurerm_subscription` to vend a new sub.**

CLAUDE.md §6 calls this out as the most likely accidental leak in the project — handle with care.

- **Purpose**: declares where new subscriptions are billed.
- **Retrieve** (uses `KEYSTONE_MCA_BILLING_PROFILE_ID`; the `invoice-section`
  subcommand is missing from current `az` CLI builds, so use `az rest`):
  ```bash
  az rest --method get \
    --url "https://management.azure.com${KEYSTONE_MCA_BILLING_PROFILE_ID}/invoiceSections?api-version=2020-05-01" \
    --query "value[].{Name:properties.displayName, ID:id}" -o table
  ```
- **Format**: `/providers/Microsoft.Billing/billingAccounts/.../billingProfiles/.../invoiceSections/...`
- **CI scope**: `platform-subscriptions` environment only.

### `KEYSTONE_VENDING_CONTEXT_SUBSCRIPTION_ID`

Subscription ID (GUID) of an existing subscription in this tenant that
Eyal already has access to — used purely as the `azurerm` provider's
auth context when vending new subscriptions. Subscription vending
operates at MCA billing scope, not at this sub.

- **Purpose**: gives `platform/05-subscriptions` a sub to authenticate
  against. Any sub Eyal has rights to is acceptable; the choice has no
  side effect on the resources being created.
- **Retrieve**:
  ```bash
  az account list --query "[?state=='Enabled'].{Name:name, ID:id}" -o table
  ```
- **Format**: GUID.
- **CI scope**: `platform-subscriptions` environment only (consumed by `platform/05-subscriptions`).

### `KEYSTONE_BUDGET_ALERT_EMAIL`

Email address that receives Azure Cost Management budget threshold
alerts from the per-subscription budgets in `platform/20-management`
(F4).

Section 6 explicitly lists email addresses as sensitive
("anything that identifies Eyal beyond what's on his public CV/blog").

- **Purpose**: `contact_emails` field on every per-sub budget's
  notification blocks (10/20/50/80/100% of monthly threshold).
- **Format**: any valid email address.
- **CI scope**: `platform-management` environment (the only one that
  applies `platform/20-management`).

### `KEYSTONE_STATE_STORAGE_ACCOUNT_NAME`

Name of the Terraform state storage account created by `platform/00-bootstrap`
in `keystone-platform-management`.

Not strictly a credential — SA names alone grant no access — but kept out of
the repo for the same reason tenant IDs are: it identifies a specific
Azure tenancy and would link the public repo back to its operator.

- **Purpose**: every layer beyond `00-bootstrap` references this as the
  `storage_account_name` in `backend "azurerm"` or in `data "terraform_remote_state"` blocks.
- **Retrieve** (after `platform/00-bootstrap` has been applied):
  ```bash
  az storage account list \
    -g rg-tfstate-plat-weu-001 \
    --subscription "$KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID" \
    --query "[0].name" -o tsv
  ```
- **Format**: lowercase alphanumeric, 24 chars max (e.g. `sttfstateplatweu<6-hex>`).
- **CI scope**: every GitHub Environment that runs `terraform`.

### `KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID`

Subscription ID (GUID) of the `keystone-platform-management` subscription
vended by `platform/05-subscriptions`.

This variable is **empty until Phase 1 of [ADR-0009](decisions/0009-subscription-staging-management-first.md)
completes** — i.e., until 05-subscriptions has been applied and vended
the Management sub. Once populated, `platform/00-bootstrap` can run and
create the state storage account in this subscription.

- **Purpose**: tells `platform/00-bootstrap` (and every subsequent layer
  that reads the state SA) which subscription holds the management plane.
- **Retrieve** (after 05-subscriptions apply):
  ```bash
  cd platform/05-subscriptions
  terraform output -raw mgmt_subscription_id
  ```
- **Format**: GUID (`00000000-0000-0000-0000-000000000000`).
- **CI scope**: `platform-management`, `platform-connectivity`,
  `platform-identity`, and every workload Environment — every CI job that
  needs to read remote state needs the Management sub ID.

## Adding a new secret

When a new sensitive value enters the project:

1. Add an `export VAR_NAME="<placeholder>"` line to `secrets.example.env` with a comment explaining what it is and how to obtain it.
2. Add a section in this file with purpose, retrieval, format, and CI scope.
3. Declare the corresponding variable in the consuming Terraform layer's `variables.tf` with `sensitive = true`.
4. Stop and prompt yourself (or Claude) with the CLAUDE.md §6 protocol block before committing any code that references the variable.

## What is NOT a credential but still belongs in this file

Some values aren't secrets-in-the-API-key sense but still identify a
specific Azure tenancy and must not appear in a public repo:

- Tenant ID, billing account / profile / scope IDs (above)
- Subscription IDs (GUIDs) — tracked here once subs are vended
- Personal email, home IP, real machine hostname — never in committed files
