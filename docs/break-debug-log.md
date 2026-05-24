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

### 2026-05-24 — Sub vended at Tenant Root instead of its target MG

**Scenario** (unintentional — caught by Eyal eyeballing the portal):
after the targeted Phase-2 apply that vended
`keystone-platform-connectivity`, the sub appeared in the Azure portal
under **Tenant Root**, not under the `keystone-platform-connectivity`
management group it was supposed to live in.

**Symptom (what Eyal saw first)**: portal MG hierarchy view showed
`keystone-platform-connectivity` sub directly at Tenant Root scope.

**Hypothesis path**:

1. The `azurerm_subscription` resource forgot to set the target MG
   somehow. **Falsified**: that resource doesn't manage MG placement
   in the first place — placement is owned by
   `azurerm_management_group_subscription_association` in
   `platform/10-management-groups`.
2. Drift: someone moved the sub via the portal. **Falsified**: nobody
   touched the portal — the sub had never been placed at all.
3. `platform/10-management-groups` hadn't been re-applied since the
   new sub was vended. **Confirmed**: 10's `for_each` over
   `data.terraform_remote_state.subscriptions.outputs.subscriptions`
   only iterated the subs that existed in 05's state **at the time 10
   was last applied**. When 05 added connectivity, 10's state still
   had the Phase-1 association set; the new sub had no association
   resource managing it, so it sat unparented at Tenant Root.

**Root cause**: layer-dependency oversight. 10-management-groups
consumes 05-subscriptions' outputs at apply time, not at plan time of
downstream layers. Vending a sub in 05 does *not* automatically
re-run 10. The two layers have an implicit ordering dependency that
must be triggered manually after a sub vend.

**Fix**: re-applied `platform/10-management-groups`. Plan proposed
exactly 1 new resource:
`azurerm_management_group_subscription_association.this["platform-connectivity"]`.
Apply added it. `az account management-group show --name
keystone-platform-connectivity --expand` now lists the sub under
the MG.

**Signal Eyal should have looked at first**: after any Phase-2-style
sub vend, the next command should be
`cd ../10-management-groups && terraform plan` — if it shows
"1 to add", that's the dance reconciling 05 → 10.

**Generalisable lesson**: when a downstream layer reads upstream
state via `terraform_remote_state`, **vending in the upstream layer
is not the full story**. The downstream layer also needs an apply to
materialise the consequences. A future polish would be a Makefile
target like `make vend-sub ALIAS=platform-identity` that runs
`05-subscriptions` apply then `10-management-groups` apply in
sequence, codifying the dependency. CLAUDE.md §3 names exactly this
class as a P1 — and that prediction has now been validated against
reality.
