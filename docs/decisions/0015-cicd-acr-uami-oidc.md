# ADR-0015: CI/CD via ACR + UAMI + federated OIDC

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Supersedes**: —
- **Builds on**: [CLAUDE.md §5](../../CLAUDE.md), which prescribed OIDC federation as the auth pattern; this ADR fills in the specifics

## Context

The workload's container image needs to be built and deployed
automatically when application code changes. Eyal requested CI/CD via
GitHub Actions → Azure Container Registry → Azure Container Apps, with
verification at every step.

Multiple specific design choices land here at once. None of them
warrants its own ADR, but together they shape the workload's
operational posture meaningfully, so they live in one consolidated
record.

## Decisions

### Registry: Azure Container Registry, Basic SKU

- **ACR over GHCR / Docker Hub / others.** Azure-native, single-tenant,
  IAM via Entra/RBAC (no GitHub PAT secret to rotate, no Docker Hub
  account to manage). Pull is Entra-token-based; the ACA Container
  App's managed identity authenticates with `AcrPull`.
- **Basic SKU** (~€4.30/mo). Cheapest tier with full RBAC support.
  Standard and Premium add capacity (10/100/500 GB) + replication +
  private endpoints — none of which the lab needs.
- **No private endpoint.** Private endpoints on ACR require **Premium**
  SKU (~€170/mo). Basic ACR is public, but RBAC is the access control
  (no anonymous pull, no admin user). Trade documented; production
  would use Premium for full network isolation.

### Auth: User-Assigned Managed Identity + federated OIDC

- **UAMI over service principal.** UAMI is the modern recommendation;
  no client secret to issue / rotate / leak. Federated identity
  credentials bind the UAMI to a specific GitHub repo+branch and the
  workflow exchanges its OIDC token for an Azure access token at
  runtime.
- **Federated subject = `repo:eyal050/keystone:ref:refs/heads/main`.**
  Branch-based, not environment-based. Environments (per CLAUDE.md §5)
  add deployment-gate reviewers + per-env secrets, both of which are
  premature here. Environments land when there's a real prod / dev
  promotion gate to enforce.
- **3 RBAC role assignments** on the UAMI:
  - `AcrPush` on the workload ACR (build + push images)
  - `Contributor` on the Container App (update image, restart, query
    revisions). Tighter custom role possible later if interview
    practice values least-privilege exercise.
  - No need for Reader anywhere broader — the workflow only touches
    the ACR and the Container App.

### Image lifecycle: CI-managed, Terraform-ignored

- The Container App's `image` field is **owned by CI**, not by
  Terraform. After Terraform's initial apply seeds the placeholder
  image, `lifecycle.ignore_changes = [template[0].container[0].image]`
  prevents Terraform from fighting the GH Actions image updates.
- **Two tags per build**:
  - `:latest` — moving, useful for one-off `docker pull` / local dev
  - `:<git-sha>` — immutable, used by `az containerapp update --image`
    to force a new ACA revision
- ACA's revision-creation behavior fires on any image-field change.
  Using the SHA tag guarantees a revision is created on every build,
  even if the underlying bytes didn't change.

### Verification: per-step gates + final HTTP check

The workflow exits with failure if **any** of:

1. Azure OIDC login fails
2. ACR login fails
3. Image build fails
4. Image push fails (verified via `az acr repository show-tags`)
5. Container App update fails
6. New revision doesn't reach `Provisioning State: Succeeded` within
   timeout
7. `curl /healthz` doesn't return HTTP 200 with body `ok`
8. `curl /` doesn't return HTTP 200 with HTML containing `ReelHouse`

The verification chain is the actual deliverable, not the build itself —
Eyal asked for verification at every step, and step 7-8 ensures the
new app is genuinely running, not just "the deploy command returned
0".

## Consequences

**Positive:**

- **No secrets to rotate.** UAMI + federated OIDC = the workflow's
  Azure auth has no static credential. GitHub gets a 5-minute OIDC
  token at runtime; Azure trusts it via the federated credential
  binding.
- **Least-privilege scoped to one workload sub.** UAMI's RBAC scope
  is narrow: AcrPush on one ACR, Contributor on one Container App.
  Compromise of the UAMI doesn't compromise the platform layers.
- **Verification chain catches subtle failures.** Steps 6-8 mean a
  successful deploy isn't just "the update API returned 200"; it's
  "the new container actually serves traffic and returns the right
  response." This is where most CI pipelines stop short.

**Negative / trade-offs:**

- **ACR is public** (no PE). Anyone who knows the registry FQDN can
  attempt to pull; RBAC denies unauthenticated requests. Production
  Premium ACR + PE would close that surface entirely.
- **CI owns image, Terraform ignores it.** Drift between
  `var.workload_image` and the actual running image is silent.
  Eyal-the-operator must remember that image updates go through the
  workflow, not through Terraform.
- **No deployment-gate review.** Branch-based federated cred means
  any push to main builds + deploys. For a personal lab, this is the
  point (fast iteration). For prod, it's wrong — an environment-based
  federated cred with required reviewers is the right call.

## Alternatives considered

- **GHCR instead of ACR.** Rejected: GHCR auth is PAT-based, requires
  a manual UI step to make packages public, and is GitHub-specific.
  ACR keeps everything inside Azure's RBAC plane.
- **Service principal + client secret instead of UAMI + OIDC.**
  Rejected: requires a static secret in GitHub Actions, which then
  needs rotation. OIDC is the modern, more secure pattern.
- **Premium ACR with private endpoint.** Rejected: ~€166/mo extra
  for network isolation that the lab doesn't need. RBAC is sufficient
  access control.
- **GitHub Environments with required reviewers.** Deferred. Worth
  doing for a real prod env; v1 lab doesn't need the gate.
- **Custom Azure role narrower than Contributor.** Considered.
  Built-in Contributor on a specific Container App is acceptable
  least-privilege for a lab. A future ADR could narrow to
  `Microsoft.App/containerApps/write` only.

## Future revisit triggers

Revisit when:

- A real prod env exists and needs human approval gates → switch
  federated cred subject to `environment:workload-prod` and configure
  required reviewers.
- ACR becomes a meaningful security surface (multi-tenant lab,
  external collaborators) → bump to Premium + private endpoint.
- The workflow grows beyond one workload → factor common steps into
  a reusable workflow or composite action.
