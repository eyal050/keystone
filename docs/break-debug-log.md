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

### 2026-05-24 — Same drift pattern in 20-management

**Scenario** (caught by `make plan-20-management` immediately after
the Makefile landed): 20-management showed `2 to add` after the
connectivity sub vended.

**Symptom**: budget + cost-export resources for `platform-connectivity`
missing from state.

**Hypothesis path**:

1. Different bug class than the 10-management-groups Tenant-Root
   miss. **Falsified**: same class — `for_each` over
   `terraform_remote_state.subscriptions.outputs.subscriptions`.
2. The 20-management layer's `cost-exports.tf` and `budgets.tf` both
   `for_each` over the same upstream output. New subs in 05 trigger
   the same "needs a downstream apply" dance. **Confirmed.**

**Root cause**: identical to the 10-management-groups case. Any
layer with `for_each` over upstream remote state has the same
implicit cross-layer-apply dependency. Today's bug just affects a
*second* layer.

**Fix**:
- `make apply-20-management` (or the helper directly with
  `-auto-approve` for non-interactive). The budget for connectivity
  applied immediately.
- Cost-export for connectivity **failed with a transient Microsoft
  API error**: "Cost management data is not supported for
  subscription(s) … in the provided api-version. Please use
  api-version 2019-10-01 or later." The error message blames the
  API version but the real cause is freshly-vended MCA subs taking
  up to 24h before cost-data services accept exports for them.
  Retry tomorrow.
- Microsoft.CostManagementExports RP registered on the connectivity
  sub (same one-time prereq as platform-management) — necessary but
  not sufficient.

**Updated remediation**: extended the `make vend-sub` target to
chain **three** applies, not two: 05 → 10 → 20. That covers every
layer currently using `for_each` over the subscriptions remote
state output. Future layers with the same pattern (40-identity is
the next candidate) need to be added here when they land.

**Signal Eyal should have looked at first** (carried forward from
the 10-management-groups entry): after any sub vend, `make
plan-LAYER` for every layer that `for_each`-es over
subscriptions. The Makefile inventory now grows by ~1 layer per
new platform layer that does cross-layer state reads — keep the
list in `vend-sub` aligned.

**Generalisable lesson (sharpened)**: the bug class isn't "10
needs re-applying after 05 vends" — it's "**every layer with
`for_each` over upstream remote state needs re-applying after the
upstream changes.**" There's no magic in Terraform that propagates
this; the workflow tooling (Makefile / Terragrunt / CI) is what
catches it. Worth pre-rehearsing for an interview: a question about
"multi-layer terraform pitfalls" answers itself with this exact
example.

### 2026-05-25 — Time-sensitive literal in cost-export rots after first vend

**Scenario** (caught on the cost-export retry from 2026-05-24): the
`platform-connectivity` cost-export apply failed again, but with a
*different* error than yesterday. Yesterday's API-version error was
gone (MCA back-end had warmed up overnight as predicted), revealing
a second bug hiding underneath.

**Symptom**:
```
Error: creating Scoped Export: 400 Bad Request:
Request properties validation failed:
Invalid schedule recurrencePeriod; 'from' value cannot be in the past.
```

**Hypothesis path**:

1. Same as yesterday — MCA back-end still cold for the new sub.
   **Falsified**: yesterday's error string was specific ("Cost
   management data is not supported … api-version"); today's is
   different ("recurrence period 'from' in the past"). Two distinct
   bugs, today's was hidden behind yesterday's.
2. Microsoft tightened API validation between yesterday and today.
   **Implausible but checked**: the literal start date
   `2026-05-22T00:00:00Z` in `cost-exports.tf:42` is **3 days in
   the past** today. The earlier `platform-management` export
   succeeded on 2026-05-22 (when the literal was current).
   **Confirmed**: bug is in the hardcoded literal, not in the API.

**Root cause**: the resource's `recurrence_period_start_date` is a
literal date string. The Microsoft cost-export API requires the
start date to be **current or future** at the moment of CREATE.
That makes the literal time-bombed: any new sub vended after the
literal's date hits the same wall. Existing exports are unaffected
because the API only enforces the rule at create time, not on
ongoing reconciliation.

This is the same shape of bug as TLS certs expiring in test
fixtures: "works the day you wrote it, breaks on a future calendar
boundary you didn't plan for." Easy to write, easy to ship, hard
to spot in review.

**Fix**:
- Replace the literal with
  `formatdate("YYYY-MM-DD'T'00:00:00'Z'", timeadd(timestamp(), "24h"))`
  → always tomorrow midnight UTC, unambiguously in the future no
  matter what time apply runs.
- Pair with `lifecycle { ignore_changes = [recurrence_period_start_date] }`.
  `timestamp()` is impure and otherwise produces a fresh value every
  plan, which would create permadrift on existing exports. The
  start date is only meaningful at create time, so ignoring it
  post-create is correct semantically as well as practically.
- `make plan-20-management` after the change showed `1 to add,
  0 to change, 0 to destroy` — confirming the existing
  `platform-management` export is immune to the impure expression.
- Apply succeeded immediately.

**Signal Eyal should have looked at first**: not the API error
message — it lied about the trigger ("api-version" was a red
herring yesterday; "in the past" was the real signal hidden
underneath). The signal that would have caught this at code-review
time: **any literal date string in a Terraform file is suspicious**.
A date that's correct today is incorrect on every other day. If a
field accepts only current-or-future values, the literal pattern
is doomed; if it accepts any value, the literal is just stale
docs at best.

**Generalisable lesson**: "this worked yesterday" is not the same
as "this works." Time-sensitive literals fail on a delay that's
larger than typical PR review cycles, so reviewers never see the
failure mode. The defensive pattern is **`timestamp()` +
`ignore_changes`** for any field where the API requires
not-in-the-past values. Other candidates in this repo to audit
for the same shape: certificate `not_before` / `not_after`,
RBAC `eligible_assignment` schedules, scheduled-action start
times, and anything in `00-bootstrap` or `05-subscriptions` that
hardcodes a date. *None* of these have landed yet, but the audit
hook is worth keeping when they do.
