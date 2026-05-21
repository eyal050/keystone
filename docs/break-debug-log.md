# Break/Debug Log

Per [CLAUDE.md §8](../CLAUDE.md), each Keystone session ends with either:

1. A new entry below describing a failure that was injected, diagnosed, and fixed, **or**
2. A note that no break/debug was practiced this session, and why.

## Catalog of seeded scenarios

Starting material from CLAUDE.md §8 — usable once the platform has enough
surface to break:

- Policy denies a deployment that should succeed.
- `DeployIfNotExists` policy is missing its managed identity role assignment → silent non-compliance.
- Private DNS zone linked to wrong VNet → private endpoint resolves to a public IP from the spoke.
- Spoke peered to hub but UDR missing → traffic skips the firewall, NSG blocks it, looks like a firewall problem.
- Custom RBAC role missing one `Microsoft.X/Y/read` permission → cryptic 403.
- APIM private endpoint approved on storage, but DNS record still points to the public FQDN.

## Entry template

> **Date**:
> **Scenario**:
> **Symptom (what Eyal saw first)**:
> **Hypothesis path**:
> **Root cause**:
> **Fix**:
> **Signal Eyal should have looked at first**:

## Entries

### Session 0 — repo bootstrap, no infrastructure

No break/debug practiced — there is nothing deployed to break. The
catalog above is seeded; the first real entry will land once at least
`platform/00-bootstrap` and the Management subscription are up.

### 2026-05-21 — Bootstrap RG landed in the wrong subscription

**Scenario** (unintentional — not a planned exercise): the first
`platform/00-bootstrap` apply created `rg-tfstate-plat-weu-001` and
its storage account inside Eyal's existing `guardianlink-prod`
subscription instead of the freshly-vended
`keystone-platform-management`.

**Symptom (what Eyal saw first)**: opening the Azure portal to spot-check
the new SA and finding it under the wrong subscription.

**Hypothesis path**:

1. `KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID` in `~/.keystone/secrets.env`
   pointed to the wrong sub. **Falsified**: env / 05-subscriptions
   output / `az` lookup all agreed on the correct GUID at investigation time.
2. There was a duplicate `export KEYSTONE_PLATFORM_MANAGEMENT_SUBSCRIPTION_ID`
   line later in `secrets.env` that overrode the correct one. **Falsified**:
   `grep -c` returned 1.
3. `TF_VAR_mgmt_subscription_id` was unset or empty in the apply shell, so
   the azurerm provider fell back to the `az` CLI default subscription —
   which was `guardianlink-prod`. **Confirmed**: `az account show` revealed
   `guardianlink-prod` as the current default; the state file's RG resource
   id contains guardianlink-prod's subscription GUID.

**Root cause**: the variable `mgmt_subscription_id` had no validation. An
empty `TF_VAR_mgmt_subscription_id` made `var.mgmt_subscription_id = ""`,
passed through `provider "azurerm" { subscription_id = "" }`, and the
provider's documented fallback chain landed on the `az` CLI current
subscription. Failure was silent.

**Fix**:
- Removed `prevent_destroy` on the wrongly-placed RG + SA, set
  `TF_VAR_mgmt_subscription_id` to guardianlink-prod's GUID, ran
  `terraform destroy`. Cleaned 4 resources.
- Restored `prevent_destroy`.
- Added two layers of hardening to `platform/00-bootstrap/variables.tf`
  and `platform/05-subscriptions/variables.tf`:
  - **GUID format validation** on `tenant_id`, `mgmt_subscription_id`,
    `vending_subscription_id` — fails plan with an actionable error
    naming the missing env var.
  - **Display-name precondition** in `platform/00-bootstrap/main.tf`
    via `data "azurerm_subscription" "mgmt"` — fails plan if the
    (otherwise valid) sub GUID does not resolve to
    `keystone-platform-management`.
- Re-applied. Resources now in the correct sub.

**Signal Eyal should have looked at first**: `az account show --query name`
before any `terraform apply`. The provider silently uses the `az` default
when the var is empty; having the default set to a different project's
prod sub was the actual exposure.

**Generalisable lesson**: any Terraform variable that controls *where*
resources land (subscription, resource group, location) should have a
loud-failing validation, not just type-checking. If the value can be
"empty string", the provider's fallback chain might silently make
"empty string" mean "any other context", which is the worst-of-both
between "fail" and "do what I expect".
