# ADR-0018: Terraform CI/CD for workloads/reelhouse/dev

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Builds on**: CLAUDE.md §5, ADR-0007 (state in management sub),
  ADR-0013 (workload owns the spoke network seam; CI = both-sub federated
  identity), ADR-0015 (app build/deploy OIDC pattern)

## Context

Every Terraform apply was a local laptop run. CLAUDE.md §5 prescribes
plan-on-PR / apply-on-merge with OIDC and an environment approval gate.
This ADR records the first vertical slice: Terraform CI for the
`workloads/reelhouse/dev` layer only. Full design:
`docs/superpowers/specs/2026-05-29-cicd-workload-dev-design.md`.

## Decisions

1. **First slice = `workloads/reelhouse/dev`.** Highest churn, lowest blast
   radius, already carries OIDC plumbing (ADR-0015). Other environments and
   platform layers are deferred.
2. **Split identities.** A read-only `tfplan` UAMI runs plan on PRs; a
   read-write `tfapply` UAMI runs apply. A malicious/buggy PR cannot mutate
   Azure because its OIDC subject only maps to Reader.
3. **Constrained RBAC-admin.** `Contributor` cannot write role assignments,
   so `tfapply` also holds `Role Based Access Control Administrator` —
   constrained by an ABAC condition to the five app-plane role GUIDs
   (AcrPull, AcrPush, Contributor, Key Vault Secrets User, Storage Blob Data
   Contributor). RBAC-admin / Owner / Key Vault Administrator are NOT
   allow-listed → no privilege escalation, and CI cannot modify operator
   grants or its own grants.
4. **CI identities live in the layer; first apply is local.** Same
   chicken-and-egg as 00-bootstrap. Documented in the spec; executed
   2026-05-29 (14 resources added).

## Cross-sub handling (per ADR-0013)

The layer writes to three scopes: workload + network RGs (workload sub) and
the hub RG (connectivity sub, via the connectivity provider alias, for
hub-side peering + DNS link). `tfapply` gets narrow `Network Contributor` +
`Private DNS Zone Contributor` scoped to the hub RG only — the least-priv
expression of the "both-sub federated identity" ADR-0013 pre-planned.
Re-homing those resources to a platform layer was considered and rejected:
it reverses ADR-0013 and reintroduces the dependency inversion that ADR
avoids. State access (management sub) uses a third provider alias +
`Storage Blob Data Reader/Contributor` on the state container, consumed by
the azurerm backend via `use_azuread_auth=true`.

## Gate deviation: workflow_dispatch, not required-reviewer

The design called for the apply to run on push-to-main, held by a GitHub
Environment **required-reviewer** rule — making the env-scoped OIDC token
cryptographically unmintable without human approval.

**This repo is private on a plan that does not support environment
protection rules** (required reviewers / wait timers return HTTP 422). So:

- The `workload-dev` environment exists (bare), which is enough for the
  env-scoped secret `AZURE_TF_APPLY_CLIENT_ID` and the env-scoped OIDC
  subject `repo:eyal050/keystone:environment:workload-dev`.
- The apply workflow triggers on **`workflow_dispatch` only** — a deliberate
  manual action is the interim human gate. Apply never runs automatically on
  merge.
- **Go-public follow-up**: once the CLAUDE.md §6 audit passes and the repo is
  public, environment protection rules become free — add the required-reviewer
  rule on `workload-dev` and restore the `push: branches: [main]` trigger.
  One API call + one workflow edit; no identity or RBAC change.

Interview-relevant: GitHub plan constraints shape your deployment-gate
design. The env-scoped OIDC subject is the cryptographic half of the control;
the protection rule is the human half. On private-free, the human half is
substituted by an explicit manual trigger.

## Making the layer CI-applyable (what apply actually required)

The layer was authored for a single human operator (subscription Owner). Running
it under a least-privilege CI identity surfaced gaps that needed targeted fixes
(full cascade in `docs/break-debug-log.md`, 2026-05-29):

- **Pinned operator grants.** `operator_kv_admin` + `operator_blob_contributor`
  use `data.azurerm_client_config.current.object_id`, which under CI resolves to
  the apply UAMI. Added `ignore_changes = [principal_id]` so they stay
  operator-owned (re-pointing Key Vault Administrator is also correctly blocked
  by the ABAC allow-list).
- **KV data plane for apply.** KV is RBAC-mode; Contributor grants no data-plane
  access. Added `Key Vault Secrets Officer` for the apply identity (KV is
  public-reachable, RBAC-gated).
- **Mgmt-plane Reader on the state container** for both identities — the
  data-plane Storage Blob Data roles don't include `roleAssignments/read`, which
  refresh needs for the state-grant role-assignment resources.
- **`ignore_changes` on the ACA env `log_analytics_workspace_id`** — a
  set-once-can't-read-back field whose perpetual diff made CI reach LAW keys in
  the platform-management sub. Freezing it kills the churn and the cross-sub
  dependency.
- **Terraform OIDC, not CLI.** `ARM_USE_OIDC=true` + `ARM_CLIENT_ID/...` so the
  backend and providers authenticate via OIDC (the azurerm backend can't use the
  `azure/login` CLI session for a service principal).
- **Read-only plan stays minimal.** `terraform plan -refresh=false` so the
  PR-assumable plan identity never reads data-plane secrets; state-container ID
  is constructed, not read via a data source (avoids needing mgmt-plane read).

Verified end-to-end 2026-05-29: plan-on-PR green (PR #1, plan posted as comment);
`workflow_dispatch` apply green and idempotent (`0 added, 0 changed, 0 destroyed`).

## Consequences

- Local applies still work (the `scripts/_tf-cmd.sh` wrapper is unchanged); CI
  is additive.
- New resources are free (UAMIs + federated creds + role assignments); idle
  cost unchanged.
- Fan-out to other environments / platform layers is a later session and may
  centralize CI-identity vending and relocate the state-container grants to
  the management layer.
