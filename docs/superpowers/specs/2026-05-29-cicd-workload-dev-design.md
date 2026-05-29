# Design: Terraform CI/CD — workload-dev vertical slice

- **Date**: 2026-05-29
- **Status**: Implemented 2026-05-29 (see ADR-0018). One deviation: the
  required-reviewer environment gate is unavailable on this private repo's
  plan, so the apply workflow uses a manual `workflow_dispatch` gate in the
  interim (restore push trigger + add the rule when the repo goes public).
- **Author**: Eyal + Claude
- **Implements**: CLAUDE.md §5 (GitHub Actions plan/apply gates, OIDC federation,
  GitHub Environments with required reviewers), one layer at a time
- **Builds on**: [ADR-0015](../../decisions/0015-cicd-acr-uami-oidc.md) (app
  build/deploy already uses UAMI + federated OIDC), [ADR-0007](../../decisions/0007-state-storage-in-platform-management.md)
  (state SA lives in platform-management)

## Problem

Every Terraform apply in this repo is currently a local laptop run. The app
container build/deploy is already automated (`reelhouse-build-deploy.yml`,
ADR-0015), but **infrastructure** changes — the `terraform plan`/`apply`
lifecycle — have no CI. CLAUDE.md §5 prescribes plan-on-PR, apply-on-merge
behind a GitHub Environment approval, authenticated via OIDC federation with a
least-privilege per-environment identity. None of that exists yet for Terraform.

## Scope

Build **one vertical slice** that proves the entire pattern end-to-end on a
single layer — `workloads/reelhouse/dev` — then stop. Fan-out to the other
environments and the platform layers is explicitly a later session. The dev
layer is chosen because it churns the most, has the lowest blast radius, and
already carries OIDC plumbing to build on.

### Out of scope (YAGNI)

- The other three environments (`workload-prod`, `platform-management`,
  `platform-connectivity`).
- Platform-layer Terraform pipelines (`00`–`40`).
- Drift-detection cron / scheduled `plan`.
- Any change to the existing `reelhouse-build-deploy.yml` app workflow.
- Fancy plan-diff rendering beyond a basic PR comment.

## Decisions (resolved during brainstorming)

| # | Fork | Decision |
|---|---|---|
| 1 | Which layer first | `workloads/reelhouse/dev` |
| 2 | Identity model | **Split**: read-only plan identity + read-write apply identity |
| 3 | How apply writes role assignments | `Contributor` + `Role Based Access Control Administrator`, the latter **constrained by an ABAC condition** to only the role GUIDs the layer grants |
| 4 | Where CI identities live | Inside the dev layer itself (`cicd.tf`); first apply is local (chicken-and-egg, like `00-bootstrap`) |

## Architecture

### Workflows

Two new workflow files, both path-filtered to `workloads/reelhouse/dev/**` and
their own file, so platform/app changes never trigger them.

| Workflow | Trigger | Identity | Gate |
|---|---|---|---|
| `reelhouse-dev-plan.yml` | `pull_request` touching the dev path | plan UAMI (read-only) | none |
| `reelhouse-dev-apply.yml` | `push` to `main` touching the dev path | apply UAMI (read-write) | GitHub Environment `workload-dev`, required reviewer = Eyal |

Flow: PR opens → `plan` runs fmt/lint/security checks then `terraform plan
-lock=false` → posts a plan summary as a PR comment. The PR review + merge is
the human review of that plan. On merge to `main`, `apply` is held at the
`workload-dev` environment gate until Eyal approves, then runs `terraform
apply`. The apply job prints its plan to the log before applying, for an audit
trail.

### Identities (defined in `workloads/reelhouse/dev/cicd.tf`)

The dev layer writes to **three scopes**, not one (confirmed by grep): the
workload RG (`rg-reelhouse-dev-workload-weu-001`) and the network RG
(`rg-reelhouse-dev-network-weu-001`), both in the workload sub; **and** two
resources in the platform connectivity sub via the existing `azurerm.connectivity`
alias — the hub-side peering (`azurerm_virtual_network_peering.hub_to_spoke`) and
the spoke's Private DNS zone link (`azurerm_private_dns_zone_virtual_network_link.spoke`),
both of which land in the hub RG. The CI identities are therefore scoped across
all three.

**`uami-reelhouse-dev-tfplan`** (read-only)
- `Reader` on the workload RG **and** the network RG (workload sub)
- `Reader` on the hub RG (connectivity sub — scoped via the `azurerm.connectivity`
  alias; hub RG name comes from `data.terraform_remote_state.connectivity.outputs.hub_resource_group_name`)
- `Storage Blob Data Reader` on the state container (`tfstate` in
  `rg-tfstate-plat-weu-001`, management sub — see management alias below)
- Federated credential subject: `repo:eyal050/keystone:pull_request`

**`uami-reelhouse-dev-tfapply`** (read-write)
- `Contributor` on the workload RG (workload sub)
- `Role Based Access Control Administrator` on the workload RG, **with an ABAC
  condition** (below)
- `Contributor` on the network RG (workload sub)
- **Narrow connectivity grant**: `Network Contributor` + `Private DNS Zone
  Contributor` scoped *only* to the hub RG (connectivity sub) — the least-priv
  expression of the cross-sub "both-sub identity" that ADR-0013 explicitly
  pre-planned (see note below). Network Contributor covers the hub-side peering;
  Private DNS Zone Contributor covers the zone link.
- `Storage Blob Data Contributor` on the state container (management sub)
- Federated credential subject: `repo:eyal050/keystone:environment:workload-dev`

> **ADR-0013 alignment.** ADR-0013 deliberately kept hub-side peering + DNS links
> in the *workload* layer (created via the connectivity provider alias) to keep
> the layer dependency one-directional, and it explicitly anticipated CI: *"in CI
> later, a platform-team federated identity with both-sub access"* creates the
> peerings. This slice realizes that sentence. The apply identity holding a narrow,
> hub-RG-scoped grant in the platform sub is not a boundary violation — it is the
> sanctioned delegation model, and "why does a workload CI identity hold a scoped
> grant in the platform sub?" is a deliberate interview talking point. Re-homing
> these resources to a platform layer was considered and rejected: it reverses
> ADR-0013 and reintroduces the dependency inversion that ADR avoids.

The apply identity's subject is **environment-scoped, not branch-scoped**. GitHub
only mints an OIDC token bearing `environment:workload-dev` *after* the
environment approval passes, so the apply credential is physically unobtainable
without Eyal's approval. The gate is cryptographic, not merely procedural. (This
deliberately differs from the app-deploy UAMI in ADR-0015, whose subject is
branch-based `ref:refs/heads/main` — that workflow had no environment gate.)

### Constrained RBAC-admin (decision #3)

`Contributor` deliberately excludes `Microsoft.Authorization/roleAssignments/write`,
so an apply identity with only Contributor would fail on the first
`azurerm_role_assignment` in the layer. Granting bare `Role Based Access Control
Administrator` fixes that but lets the identity grant *any* role to *any*
principal — including granting itself `Owner` (privilege escalation).

Mitigation: the `Role Based Access Control Administrator` assignment carries an
ABAC `condition` restricting `roleAssignments/write` to exactly the role
definitions the dev layer grants to **application/workload principals** (the
app-deploy UAMI and the ACA managed identity):

- `AcrPull`
- `AcrPush`
- `Contributor`
- `Key Vault Secrets User`
- `Storage Blob Data Contributor`

The layer's role assignments fall into three buckets, and only the first is
allow-listed:

1. **App-plane grants** (above) — allow-listed; CI reconciles these freely.
2. **Operator grants** — `operator_kv_admin` (`Key Vault Administrator` in
   `keyvault.tf`). **Excluded.**
3. **The CI identities' own grants** — everything `cicd.tf` assigns to the two CI
   UAMIs (`Reader`, `Contributor`, **`Role Based Access Control Administrator`**,
   `Storage Blob Data Reader/Contributor`, and the connectivity-sub grants).
   **Excluded.**

**Why these exclusions are the security story.** `Role Based Access Control
Administrator`, `Owner`, and `User Access Administrator` are *never* allow-listed,
so the apply identity can never grant a role-granting role — no privilege
escalation path exists. And because the CI identities' own grants (bucket 3) are
excluded, **CI cannot modify its own privileges**: the `cicd.tf` assignments are
local-apply-owned, exactly like `operator_kv_admin`. In steady state all
exclusions are no-ops (Terraform only calls the write API on create/change, and
these assignments already exist from the local apply). If an excluded assignment
ever drifts or needs recreating, CI apply 403s on exactly that resource — by
design, a signal to reconcile it with a local operator apply rather than widening
CI's reach.

> Note on `Contributor` in the allow-list: the app-deploy UAMI legitimately needs
> `Contributor` (on the Container App + ACA env, per ADR-0015), so CI must be able
> to reconcile it. `Contributor` cannot grant roles, so allow-listing it creates
> no escalation path; a malicious PR adding a `Contributor` grant to an attacker
> principal is caught by the plan-on-PR + merge + environment-approval gates.

Condition shape (role GUIDs resolved via `data.azurerm_role_definition`, not
hardcoded):

```
(
  (
   !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
  )
  OR
  (
   @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId]
     ForAnyOfAnyValues:GuidEquals {<guid1>, <guid2>, ...}
  )
)
```

A symmetric delete condition (`roleAssignments/delete`) is included so the
identity can also remove only those same roles.

### State access wrinkle (decision #4 consequence)

The state SA lives in **platform-management**, a different subscription from the
workload. The two `Storage Blob Data *` role assignments therefore target a
resource in another sub. To keep the slice self-contained, the dev layer gains a
third `azurerm` provider alias — `management` — pointed at
`var.mgmt_subscription_id` (the var already exists), used solely for those two
assignments. This mirrors the existing `connectivity` alias pattern.

CI `terraform init` must pass `-backend-config="use_azuread_auth=true"` so the
azurerm backend authenticates to the state blob with the workflow's OIDC token
(this is *why* the CI identities need the Storage Blob Data roles). Plan runs
`terraform plan -lock=false` — the Reader identity can't write the lock blob,
and a PR plan should not lock shared state.

> Note for fan-out: when the other environments land, these state-container
> grants may relocate to the management layer to avoid every workload layer
> carrying a management provider alias. Deferred deliberately.

### Pre-merge checks

Per CLAUDE.md §5, the `plan` workflow runs before the plan step and gates the PR:
- `terraform fmt -check`
- `tflint`
- `tfsec`

### Secrets (CLAUDE.md §6)

After the first local apply creates the identities, their client IDs are
sensitive and must never be committed. Eyal has delegated the secret-setting to
Claude: Claude runs the first local apply and pipes
`terraform output -raw <id> | gh secret set <NAME>` so the values never render
in chat or land in a tracked file.

Because `workloads/reelhouse/dev/terraform.tfvars` is **gitignored**, CI cannot
read the layer's no-default variables from disk — they must be injected as
`TF_VAR_*` env vars. The no-default variables are `tenant_id`, the three
subscription IDs, `state_storage_account_name`, and `operator_ip`. Per §6 the
subscription GUIDs and the operator IP are sensitive → secrets; resource *names*
(state RG / SA / container / key) are committed as workflow `env:`, matching the
existing `reelhouse-build-deploy.yml` precedent (which commits `ACR_NAME`, RG
names, etc.). Variables that have defaults (`location`, `spoke_address_space`,
`postgres_enabled=false`, `workload_pe_enabled=false`, `required_tags`, …) are
left at their defaults in CI.

| Secret | Scope | New? | Used by |
|---|---|---|---|
| `AZURE_TF_PLAN_CLIENT_ID` | repo-level (plan runs on PRs) | new | `reelhouse-dev-plan.yml` |
| `AZURE_TF_APPLY_CLIENT_ID` | `workload-dev` environment (only the gated job can read it) | new | `reelhouse-dev-apply.yml` |
| `AZURE_CONNECTIVITY_SUBSCRIPTION_ID` | repo-level | new | both (`TF_VAR_connectivity_subscription_id`) |
| `AZURE_MGMT_SUBSCRIPTION_ID` | repo-level | new | both (backend-config + `TF_VAR_mgmt_subscription_id`) |
| `OPERATOR_IP` | repo-level | new | both (`TF_VAR_operator_ip`) |
| `AZURE_TENANT_ID` | repo-level | exists | both (OIDC + `TF_VAR_tenant_id`) |
| `AZURE_SUBSCRIPTION_ID` (workload sub) | repo-level | exists | both (OIDC context + `TF_VAR_workload_subscription_id`) |

Committed (non-sensitive) workflow `env:`: `STATE_RG=rg-tfstate-plat-weu-001`,
`STATE_CONTAINER=tfstate`, `STATE_KEY=workloads-reelhouse-dev.tfstate`, and the
state SA name (already a public output, not a §6-forbidden value). The azurerm
backend authenticates to state via `use_azuread_auth=true` (OIDC token), which is
why the CI identities carry `Storage Blob Data *` on the state container.

## Chicken-and-egg bootstrap

CI cannot create the identity it logs in as. So the first `terraform apply` that
creates `cicd.tf`'s two UAMIs + federated creds + role assignments is run
**locally by Claude** (via the existing `scripts/_tf-cmd.sh` flow), exactly as
`00-bootstrap` documents its own bootstrap. After that apply, Claude sets all the
GitHub secrets in the table above (client IDs via `terraform output -raw … | gh
secret set …`; the sub-ID and operator-IP values sourced from
`~/.keystone/secrets.env`), and CI owns the layer from then on.

## Verification

1. **Plan path**: open a trivial PR touching the dev layer → `plan` workflow
   runs green, posts a plan comment.
2. **Apply path**: merge → `workload-dev` environment prompts Eyal → approve →
   `apply` runs and is idempotent (no unexpected changes).
3. **Least-priv boundary**: *asserted, not built* — the plan identity holds only
   `Reader`, so an apply with it would 403. Documented as the security property;
   no negative-test job is added.

## Open questions for the plan

- **O1 (resolved)**: The ABAC allow-list covers the *app-plane* roles the dev
  layer grants to application principals — `AcrPull`, `AcrPush`, `Contributor`,
  `Key Vault Secrets User`, `Storage Blob Data Contributor` — and excludes the
  operator grant (`Key Vault Administrator`) and the CI identities' own grants
  (`Role Based Access Control Administrator`, etc.) — see Constrained RBAC-admin
  above. The plan step must still grep the layer authoritatively to confirm no
  *other* app-plane role grant was missed; a missing allow-listed role would 403
  in CI. (Good break/debug seed.)
- **O2 (resolved)**: Reuse the existing repo-level `AZURE_TENANT_ID` /
  `AZURE_SUBSCRIPTION_ID` secrets as-is; only the two new per-identity client-ID
  secrets are added.

## Documentation deliverables

- A new ADR (`docs/decisions/0018-terraform-ci-workload-dev.md`) capturing
  decisions 1–4.
- A `docs/break-debug-log.md` entry (or note) for the session.
- Per-layer / workflow README touch as needed.
