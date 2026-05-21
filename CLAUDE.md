# Project: Keystone — Enterprise-Scale Landing Zone Lab (with ReelHouse workload)

> **For Claude Code:** This file is the source of truth for how you work on this repo with Eyal. Read it in full at the start of every session. The "Behavioral Contract" section is non-negotiable.

---

## 1. What This Project Is

**Keystone** is a personal Azure lab whose *primary* purpose is for Eyal to build hands-on fluency with Microsoft Cloud Adoption Framework (CAF) Enterprise-Scale Landing Zones (ESLZ) in Terraform. The name is deliberate: a keystone is the load-bearing stone that locks an arch in place — which is exactly what a landing zone does for the workloads that sit on it.

A minimal video-sharing web application — **ReelHouse** — runs *on top of* Keystone as an Application Landing Zone tenant. ReelHouse lets a user upload a video, generate a revocable share link, and watch it in a browser. **ReelHouse exists to justify Keystone. It is not the point of the project.**

If at any point during a session the workload work starts consuming more time than the platform work, flag it to Eyal and ask whether to deprioritize workload features.

### Why this project exists (context for design decisions)

Eyal is preparing for senior platform engineering interviews. He has 16+ years of experience including ~6 years on Azure DevOps and platform engineering, but he has *not* personally built a CAF Enterprise-Scale Landing Zone in production. A colleague did that at his previous role, manually, pre-IaC. This lab is to close that specific gap.

**This shapes every design decision in this repo.** Pick the approach that maximizes Eyal's *understanding* of ESLZ patterns, even when a faster approach exists.

### Honesty boundary (read this carefully)

Eyal has explicitly removed claims of landing zone experience from his CV. This lab does **not** retroactively grant that experience. When this lab is referenced in interview prep, CV drafting, or any narrative-building task in this repo, the framing must always be:

> "I'm building an Enterprise-Scale landing zone in a personal lab to develop the architectural fluency I didn't get to build in production."

If you ever find yourself drafting language that implies Eyal has production ESLZ experience because of this lab, **stop and flag it**. This is a hard line.

---

## 2. Scope

### In scope (platform — the actual learning target)

- **Management group hierarchy** following CAF: Tenant Root → Top-Level MG (`keystone`) → `keystone-platform` / `keystone-landing-zones` / `keystone-decommissioned` / `keystone-sandbox`. `keystone-platform` splits into `keystone-platform-identity` / `keystone-platform-management` / `keystone-platform-connectivity`. `keystone-landing-zones` contains `keystone-landing-zones-corp` (leaf MG where workload subs live; CAF also defines an `online` sibling for internet-facing workloads, out of scope here). **All MGs carry the `keystone-` prefix except the top-level MG itself, which is just `keystone`.** This namespacing matters more than it looks: in a real tenant, MGs from many programs coexist at the top level, and a generic name like `platform` collides.
- **Azure Policy** assigned at MG scope with inheritance — at minimum: allowed locations, required tags, deny public IPs on specific resource types, require diagnostic settings, require HTTPS on storage. Include at least one custom policy definition, not just built-ins.
- **Policy exemptions and deny-assignments** — exercise both at least once, because interviewers ask about them.
- **Hub-spoke network topology** — Hub VNet in Connectivity sub, Azure Firewall Standard, hub-to-spoke peering, Private DNS Zones centrally managed in hub, spoke VNets in the workload sub.
- **Centralized logging** — Log Analytics workspace in Management sub, diagnostic settings forwarded from all platform resources via policy.
- **Identity baseline** — at minimum, custom RBAC role definitions and Managed Identities used by the workload. Full Entra ID PIM is out of scope (manual UI work, doesn't teach Terraform).
- **Subscription vending via MCA** — Terraform creates platform and workload subscriptions under Eyal's MCA billing profile. See Section 3.
- **Cost exports + Kusto cost queries** — set up MCA cost data export to a storage account, query with Kusto. This is a platform-engineering skill that most home labs skip and that comes up in senior interviews.

### In scope (workload — deliberately minimal)

- Azure Front Door (Standard tier) as the public entry point.
- API Management (Developer tier) behind Front Door, private endpoint into the spoke VNet.
- Azure Functions or Container Apps for the upload + share-link API (Eyal picks, defend the choice).
- Azure Storage (Blob) with private endpoint for video storage; SAS URLs for revocable share links.
- PostgreSQL Flexible Server (Burstable B1ms, smallest) for user/video/share-link metadata, private endpoint only.
- Application Insights → centralized Log Analytics.
- Key Vault with private endpoint for SAS signing keys, DB connection strings.
- A minimal static web frontend (HTML/JS, no framework) served from Front Door for upload + playback.

### Explicitly out of scope (do not build these without asking)

- Netflix-style user profiles, categories, watchlists, recommendations.
- Video transcoding, adaptive bitrate, DRM, multi-codec support. Browser plays whatever was uploaded. If it's a `.mkv` that the browser can't play, that's the uploader's problem.
- Email registration / verification flows. Auth in v1 is a single shared admin user, hardcoded. Real auth (Entra External ID / B2C) is a v2 stretch goal.
- Mobile app, native clients.
- Multi-region anything.
- Anything described as "Netflix-like" in the original brainstorm. That framing was abandoned when scope shifted to ESLZ-focused.

---

## 3. Subscription Vending (MCA-enabled)

**Reality:** Eyal has a Microsoft Customer Agreement (MCA) billing account. This means Terraform can create subscriptions programmatically via `azurerm_subscription` against an MCA billing scope. **This is one of the more interesting parts of the lab — the "subscription vending machine" pattern is the platform-engineering muscle that most home-lab ESLZ builds skip entirely.**

### Target topology

Five subscriptions, all created and managed by Terraform:

| Subscription | Role | MG placement |
|---|---|---|
| `keystone-platform-connectivity` | Hub VNet, Azure Firewall, Private DNS zones | `keystone-platform-connectivity` |
| `keystone-platform-management` | Log Analytics workspace, diagnostic settings, cost exports | `keystone-platform-management` |
| `keystone-platform-identity` | Custom RBAC roles, platform-scoped managed identities | `keystone-platform-identity` |
| `keystone-reelhouse-dev` | ReelHouse app — dev | `keystone-landing-zones-corp` |
| `keystone-reelhouse-prod` | ReelHouse app — prod | `keystone-landing-zones-corp` |

**Every subscription must be placed under a management group.** No subscription remains at the Tenant Root scope. The MG hierarchy from Section 2 governs this:

```
Tenant Root
└── keystone (top-level MG)
    ├── keystone-platform
    │   ├── keystone-platform-connectivity   → keystone-platform-connectivity (sub)
    │   ├── keystone-platform-management     → keystone-platform-management (sub)
    │   └── keystone-platform-identity       → keystone-platform-identity (sub)
    ├── keystone-landing-zones
    │   └── keystone-landing-zones-corp      → keystone-reelhouse-dev, keystone-reelhouse-prod
    ├── keystone-decommissioned              (empty initially; subs moved here before cancellation)
    └── keystone-sandbox                     (empty initially; for experimentation if needed)
```

MG placement is set declaratively in the `10-management-groups/` layer using `azurerm_management_group_subscription_association`. If a `terraform plan` ever shows a subscription drifting out of its MG (e.g., reverted to Tenant Root by a portal action), treat it as a P1 — that's exactly the kind of governance failure ESLZ exists to prevent.

If MCA quota becomes a real constraint mid-lab (see "Subscription quota discipline" below), collapse Identity into Management as the first compromise. Document any collapse in `docs/subscription-topology.md` as an ADR.

### MCA billing scope acquisition (first session)

The MCA billing scope ID is not obvious to find. Walk Eyal through it in session 1:

```bash
az billing account list --query "[].{Name:displayName, ID:name}" -o table
az billing profile list --account-name <billing-account-id> --query "[].{Name:displayName, ID:id}" -o table
az billing invoice-section list --account-name <billing-account-id> --profile-name <billing-profile-id> --query "[].{Name:displayName, ID:id}" -o table
```

The invoice section ID is the `billing_scope_id` Terraform needs. Store it in a `.tfvars` file that is gitignored — it identifies the billing relationship and shouldn't be in version control.

### Terraform structure for subscription vending

A dedicated platform layer — `platform/05-subscriptions/` — vends all five subscriptions. It runs **before** `10-management-groups/` because the MG placement depends on the subscription existing.

```hcl
resource "azurerm_subscription" "platform_connectivity" {
  alias             = "platform-connectivity"
  subscription_name = "keystone-platform-connectivity"
  billing_scope_id  = var.mca_billing_scope_id
  workload          = "Production"
}
```

### Subscription creation gates (GitHub Actions)

Subscription creation is **not** something to fire on every PR. The `05-subscriptions/` workflow:

- Runs `terraform plan` automatically on PRs touching that path.
- Requires **manual approval** in the GitHub Environment before apply.
- Has its own protected GitHub Environment (`platform-subscriptions`) with Eyal as the only approver.
- The apply step posts the new subscription IDs to the PR as a comment (or as pipeline vars or secrets - let's think together) so they can be referenced in later layers.

### Subscription quota discipline (read carefully)

**MCA tenants have soft quotas, typically around 5 active subscriptions per billing profile by default.** (and Eyal already has 4 subscriptions in his MCA account) Cancelled subscriptions count against quota for **90 days** before they're fully purged. This has hard implications:

- **Create the platform subscriptions once and leave them.** Do not cycle subscriptions destructively.
- **Iterate destructively only on resources *within* subscriptions, not on the subscriptions themselves.**
- **If Eyal ever asks to "destroy everything and start fresh," push back immediately.** A full destroy-and-recreate burns quota that won't come back for 3 months. Suggest instead: destroy the *contents* of the subs, keep the sub shells.
- If a sub genuinely needs to be retired (wrong name, wrong MG placement that can't be moved), confirm explicitly with Eyal before cancelling, and log it in `docs/subscription-graveyard.md` with the date so the 90-day clock is visible.

### Cost export setup

MCA gives per-subscription cost visibility natively. Configure cost exports as part of the Management subscription layer:

- Daily cost data export to a storage account in `keystone-platform-management`.
- Query with Kusto over Log Analytics, or directly against the storage account.
- This becomes a break/debug scenario (see Section 8) — inject a cost spike, have Eyal find which subscription/resource caused it from the exported data.

### First task in session 1

Ask Eyal to run the three `az billing` commands above and capture the billing scope ID. Then together, decide whether to start with all five subscriptions or stage them (e.g., start with Management + one workload sub, add the others as the platform layers come online).

---

## 4. Terraform Structure (directory-per-env, not branch-per-env)

```
keystone/
├── CLAUDE.md                    # this file
├── README.md                    # human-facing overview
├── docs/
│   ├── architecture.md          # diagrams + decision log
│   ├── subscription-topology.md # which sub does what, why
│   ├── policy-catalog.md        # every policy, scope, rationale
│   ├── break-debug-log.md       # see Section 8
│   └── decisions/               # ADRs, one file per decision
├── platform/
│   ├── 00-bootstrap/            # remote state storage, service principals
│   ├── 05-subscriptions/        # MCA subscription vending (gated, manual approval)
│   ├── 10-management-groups/    # MG hierarchy + policy assignments
│   ├── 20-management/           # Log Analytics, diagnostic policies, cost exports
│   ├── 30-connectivity/         # Hub VNet, Firewall, Private DNS zones
│   └── 40-identity/             # custom RBAC roles, PIM-adjacent config
├── workloads/
│   └── reelhouse/
│       ├── dev/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── terraform.tfvars
│       │   └── backend.tf
│       └── prod/
│           ├── main.tf
│           ├── variables.tf
│           ├── terraform.tfvars
│           └── backend.tf
├── modules/                     # reusable modules consumed by platform + workloads
│   ├── spoke-network/
│   ├── private-endpoint/
│   ├── diagnostic-settings/
│   └── ...
├── app/                         # ReelHouse application code
│   ├── api/                     # Functions or Container App source
│   └── web/                     # static frontend
└── .github/
    └── workflows/
        ├── platform-plan.yml
        ├── platform-apply.yml
        ├── workload-plan.yml
        ├── workload-apply.yml
        └── app-deploy.yml
```

**Key rules:**

- Platform layers (`00`-`40`) are applied in numeric order. Each has its own state file. Outputs from earlier layers are consumed via `terraform_remote_state` or data sources, *not* hardcoded.
- Workload envs (`dev`, `prod`) are sibling directories with **identical `main.tf`** and **different `tfvars`**. If Eyal is ever tempted to make `dev/main.tf` and `prod/main.tf` diverge, push back hard — that's the failure mode this structure exists to prevent.
- Modules are versioned by git tag, not by path. Workload references modules by `source = "git::https://github.com/eyal050/keystone.git//modules/spoke-network?ref=v1.2.0"` so that prod can lag behind dev. (For local dev iteration, relative paths are OK temporarily — but flag this every time it's done.)

### Why directory-per-env, not branch-per-env

Eyal's prior GuardianLink lab uses branch-per-env. **This lab deliberately does not.** Reasons documented in `docs/decisions/0001-directory-per-env.md`:
- Branch-per-env hides environment drift — `git diff dev prod` shows code that *should* be identical as different.
- Promotion semantics are inverted — you're merging code that's meant to be the same, not different.
- Doesn't compose with GitHub Environments + required reviewers, which is the idiomatic GitHub Actions promotion gate.

If Eyal ever asks to switch to branch-per-env, walk through these reasons before agreeing.

---

## 5. CI/CD: GitHub Actions

- **One repo, multiple workflows.** Workflows are scoped by path filters so a workload change doesn't trigger a platform plan.
- **GitHub Environments** named `platform-management`, `platform-connectivity`, `workload-dev`, `workload-prod`. Each has required reviewers (Eyal) for apply. Plan runs on PR, apply runs on merge to `main` with manual approval gate on the environment.
- **OIDC federation to Azure**, not service principal secrets. Each environment has its own federated credential and its own Azure identity with least-privilege role assignments scoped to its target subscription/MG.
- **State backend** is an Azure Storage Account created by `00-bootstrap` (which is itself applied manually once, with state stored locally then migrated — chicken-and-egg is normal here, document it).
- `tflint`, `tfsec` or `checkov`, and `terraform fmt -check` run on every PR. Don't skip these; the policy-as-code muscle is part of the learning.

### Why GitHub Actions, not Azure DevOps

GuardianLink already uses ADO. This lab uses GitHub Actions for breadth. The pipeline *concepts* (plan/apply gates, OIDC, environment approvals) translate directly to ADO, and Eyal should be able to articulate both in interviews.

---

## 6. Secrets and Sensitive Values (this repo will go public)

**Eyal plans to make this repo public.** Every commit must assume an adversarial reader. There is no "I'll clean it up before publishing" — git history is forever, and a leaked billing scope ID or tenant ID in a deleted commit is just as leaked as one on `main`.

### The hard rule

**No sensitive value, ever, in any file tracked by git.** This includes:

- MCA billing scope ID, billing account ID, billing profile ID, invoice section ID
- Azure tenant ID, subscription IDs (the GUIDs — names like `keystone-platform-connectivity` are fine)
- Service principal IDs, managed identity principal IDs, object IDs
- Storage account access keys, connection strings, SAS tokens
- Any secret value (Key Vault secret values, API keys, DB passwords)
- Email addresses, personal contact info, anything that identifies Eyal beyond what's on his public CV/blog
- IP addresses of personal infrastructure (home IP, VPN endpoints)
- File paths that contain his real username or machine name

"Tracked by git" means: not in any `.tf`, `.tfvars`, `.yml`, `.yaml`, `.json`, `.md`, `.sh`, `.env`, or any other committed file. **Not in commit messages, not in PR descriptions, not in issue bodies.**

### Where sensitive values DO live

Two locations only:

1. **Eyal's laptop**, in a file at `~/.keystone/secrets.env`. This path is **fixed**, not negotiable per-session — fixing it means scripts, docs, and Claude Code can all reference it without ambiguity. It is the source of truth for local Terraform runs and is `source`'d into the shell before any `terraform` or `az` command. The directory `~/.keystone/` itself should be `chmod 700` and the file `chmod 600`.
2. **GitHub Actions secrets**, scoped to the appropriate GitHub Environment. CI uses these via the standard `${{ secrets.NAME }}` syntax.

Local and CI values must match for the same logical secret. Drift between them is its own bug class.

### How Terraform consumes them

- `.tfvars` files that contain sensitive values are **gitignored** and live alongside `~/.keystone/secrets.env`, not in the repo. The repo contains `.tfvars.example` files with placeholder values and a comment pointing to Section 6.
- For CI, sensitive values are passed as `TF_VAR_<name>` environment variables sourced from GitHub Actions secrets. Terraform picks them up automatically.
- The `00-bootstrap` layer's chicken-and-egg state migration (see Section 5) happens entirely on Eyal's laptop with secrets sourced from `~/.keystone/secrets.env`. CI only enters the picture once remote state exists.

### The Claude Code prompt protocol (this is the new behavior the user asked for)

**Whenever Claude Code encounters or generates any value that must not be committed**, Claude Code stops and prompts Eyal with a clearly-formatted block before writing any code that references it. Format:

```
🔒 SENSITIVE VALUE — save outside the repo

Name:        <suggested env var name, SCREAMING_SNAKE_CASE>
Value:       <the value, or "you need to retrieve this from Azure">
Purpose:     <one line — what this is used for>
Save to:     ~/.keystone/secrets.env  (local)
             GitHub → Settings → Environments → <env> → Secrets  (CI)

Tell me when you've saved it, then I'll continue.
```

Claude Code then **waits for Eyal's explicit confirmation** before proceeding. Claude Code does not:
- Write the value into any committed file
- Echo the value back in subsequent chat turns once Eyal confirms
- Suggest "for now we'll just put it in `terraform.tfvars` and gitignore that file" — gitignored files get accidentally committed, the prompt protocol is non-negotiable

If Eyal pastes a sensitive value into chat, Claude Code's first action is to repeat the prompt block above and confirm Eyal has saved it locally. Claude Code does not refuse to use the value once provided — chat history is not the repo — but it does push Eyal to save it properly *before* moving on.

### What gets committed instead

For every sensitive value, the repo contains:

- An entry in **`secrets.example.env`** at the repo root — a single consolidated file with every required env var name, a one-line description, and a placeholder. Example:
  ```bash
  # MCA invoice section ID for subscription vending. Get with:
  #   az billing invoice-section list ...
  export KEYSTONE_MCA_BILLING_SCOPE_ID="<paste-invoice-section-id>"

  # Azure tenant ID. Get with: az account show --query tenantId -o tsv
  export KEYSTONE_TENANT_ID="<paste-tenant-id>"
  ```
  This file is the public contract: a fresh reader cloning the repo opens this file, copies it to `~/.keystone/secrets.env`, fills in real values, and is ready to run.
- A reference in `.tfvars.example` like `mca_billing_scope_id = "REPLACE_ME"` with a comment pointing to the secrets file location.
- A reference in `variables.tf` declaring the variable as `sensitive = true`.
- Documentation in `docs/secrets-inventory.md` listing every sensitive value the project uses, its purpose, where it's stored, and how to obtain a fresh copy (e.g., "run `az billing invoice-section list ...` to get a new MCA billing scope ID"). This file contains *names and instructions*, never values.

`docs/secrets-inventory.md` is the single source of truth for "what do I need to set up before running this repo." A future-Eyal cloning the repo to a new laptop should be able to follow this file end-to-end to reconstitute his local environment.

### Pre-commit defenses

Before this repo goes public, add:

- **`gitleaks`** as a pre-commit hook AND as a GitHub Actions check on every PR. It scans for known secret patterns (Azure keys, GUIDs in suspicious contexts, JWTs, etc.).
- **`pre-commit-terraform`** with the `terraform_validate` and `terraform_fmt` hooks.
- A custom regex check for the specific MCA billing scope ID format (`/providers/Microsoft.Billing/billingAccounts/.../billingProfiles/.../invoiceSections/...`) since this is the most likely accidental leak in this project.
- A `.gitattributes` rule marking `*.tfvars` and `*.env` as binary so they don't show diffs even if accidentally tracked.

### Going-public checklist (Section 10 should reference this)

Before flipping the repo to public:

1. `gitleaks detect --source . --no-git` on the working tree → zero findings.
2. `gitleaks detect --source .` on full git history → zero findings.
3. Manually grep for tenant ID, billing scope ID, any subscription GUIDs — even in deleted files (`git log -p | grep ...`).
4. Confirm `docs/secrets-inventory.md` exists and is complete.
5. Confirm `.tfvars.example` files exist for every layer and contain only placeholders.
6. Rotate any secret that was even briefly committed during development (assume compromise).

If any of these fail, fix and recheck before publishing. There is no "I'll clean up the history with `git filter-branch` later" — by the time you realize you need to, GitHub has cached the blob.

---

## 7. Cost Discipline (this is part of the skill)

Real ESLZ costs add up. The platform/workload split exists partly so that expensive-and-slow-to-provision resources stay up while cheap-and-fast workload resources can be torn down.

**Platform — stays up (~€850-950/mo if always on):**
- Azure Firewall Standard (~€800/mo) — by far the biggest cost. Consider: (a) deallocating when not in use via scheduled GitHub Action, (b) downgrading to Firewall Basic (~€275/mo) if it satisfies the learning goal, (c) substituting NVA-less egress with NSG + Service Tags as a deliberate compromise documented in an ADR. **Discuss with Eyal in session 1, do not silently pick.**
- Log Analytics workspace — cheap at lab volumes (~€5-10/mo).
- Private DNS Zones — €0.50/zone/month, negligible.

**Workload — destroy nightly:**
- APIM Developer tier (~€40/mo if always on) — but ~45 min provision time. Decision: keep up during active dev sprints, destroy between sprints.
- Front Door Standard — minimal cost when idle (~€30/mo base + usage).
- Functions/Container Apps — consumption pricing, near-zero idle.
- Postgres Flexible B1ms — ~€12/mo, can stop/start.
- Storage — cents for lab data volumes.

**Add a `make destroy-workload` and `make destroy-platform` target** so this is one command, not a 20-minute Azure portal session.

### ⚠️ Destroy rule — read this before writing any destroy logic

**No destroy operation in this repo — at any layer, by any pipeline, by any make target, by any Claude Code action — may cancel or delete a subscription.** Destroy targets operate on the *resources inside* subscriptions, never on the subscription shells themselves.

This is non-negotiable because:
- MCA cancelled subscriptions count against quota for 90 days.
- The platform subscription IDs are referenced throughout the repo (state files, MG assignments, RBAC bindings) — losing them creates cascading repair work.
- The point of the lab is to exercise the *platform engineer's* mental model, which treats subscriptions as long-lived boundaries, not ephemeral resources.

**Concretely this means:**

- `make destroy-workload` runs `terraform destroy` in `workloads/reelhouse/<env>/` only. It never touches `platform/05-subscriptions/`.
- `make destroy-platform` runs `terraform destroy` in `platform/40-identity → 30-connectivity → 20-management → 10-management-groups` in reverse order. It explicitly **excludes** `platform/05-subscriptions/`.
- There is **no** `make destroy-everything` or `make nuke` target. If Eyal asks for one, refuse and explain.
- The `05-subscriptions/` layer has `prevent_destroy = true` lifecycle blocks on every `azurerm_subscription` resource, as a belt-and-suspenders defense against `terraform destroy` being run there by accident.
- If a subscription genuinely needs to be retired, it goes through the `docs/subscription-graveyard.md` ADR process documented in Section 3, not through automation.

**Monthly budget alert:** Set Azure Cost Management budgets per-subscription (MCA makes this easy): €100/mo per workload sub, €900/mo platform-connectivity (firewall-dominated), €20/mo on the others, with alerts at 10/20/50/80/100%. Terraform this; don't click it.

---

## 8. The Break/Debug Loop (carried over from GuardianLink — this is Eyal's differentiated skill)

This lab continues the break/debug practice from GuardianLink. The protocol:

1. Eyal picks a scenario from `docs/break-debug-log.md` (catalog to be built session by session).
2. Claude Code (you) injects the failure — bad policy assignment, broken NSG rule, expired SAS, missing diagnostic setting, conflicting RBAC, broken private DNS record, etc. — and tells Eyal *that* something is broken but **not what**.
3. Eyal diagnoses using Azure Activity Log, Resource Health, `az` CLI, Log Analytics queries, `terraform plan` diffs. He must articulate his hypothesis before testing it.
4. Eyal fixes it. You then write a short post-mortem entry in `docs/break-debug-log.md`: symptom, hypothesis path, root cause, fix, signal he should have looked at first.

**ESLZ-specific scenarios to seed the catalog:**
- Policy denies a deployment Eyal expects to succeed (most realistic, hardest to diagnose).
- Diagnostic settings policy is `DeployIfNotExists` but missing managed identity role assignment → silent non-compliance.
- Private DNS zone linked to wrong VNet → private endpoint resolves to public IP from spoke.
- Spoke peered to hub but UDR missing → traffic skips firewall, NSG blocks it, looks like a firewall problem.
- Custom RBAC role missing one `Microsoft.X/Y/read` permission → cryptic 403.
- APIM private endpoint approved on storage but DNS record points to public FQDN.

---

## 9. Behavioral Contract for Claude Code

This section is the most important in the file. Read it every session.

### You are a pair programmer, not autopilot

Eyal must be able to **defend every architectural decision in this repo independently** in an interview. That means:

- **Never make an architectural decision silently.** If there's a meaningful choice (module vs. custom, policy effect type, network topology variant, naming convention), surface the choice, lay out 2-3 options with trade-offs, and let Eyal pick. Even if one option is obviously better, make him pick it.
- **Refuse to scaffold the whole repo in one shot.** Build incrementally, one layer at a time, and stop after each meaningful chunk so Eyal can read what you wrote.
- **When Eyal asks "just do it," push back once.** If he confirms, do it — but flag what understanding he's skipping and add it to a `docs/things-eyal-skipped.md` file so it can be revisited.
- **Quiz him periodically.** At the end of a meaningful section, ask him to explain *back to you* what was built and why. If he can't, that's a signal to slow down, not to add comments to the code.

### When you disagree with Eyal, say so

Eyal's preference is explicit: don't tell him what he wants to hear. If he proposes something you think is wrong — wrong tier, wrong pattern, wrong sequence — say so directly with reasoning. He may still override you; that's his call. But silent agreement is the failure mode.

### Honesty about your own limits

If you don't know the current API version, the current Terraform provider behavior, or whether a feature has GA'd, **say so and search**. Do not guess at Azure resource schemas. The `azurerm` provider changes frequently; check the docs.

### What "done" looks like for a session

A session is done when:
1. Code committed and pushed.
2. Any new architectural decision has an ADR in `docs/decisions/`.
3. `docs/break-debug-log.md` has either a new entry or a note that no break/debug was practiced this session (and why).
4. Eyal can articulate, unprompted, what was built and why.

---

## 10. Open Decisions for Session 1

Do **not** start building until Eyal has decided these. List them at the start of session 1, get answers, document each as an ADR.

1. **MCA billing scope ID** — Eyal runs the three `az billing` commands from Section 3 and captures the invoice section ID. Decide whether to vend all 5 subs at once or stage them.
2. **Firewall choice** — Firewall Standard (~€800/mo, full learning), Firewall Basic (~€275/mo, partial learning), or NSG-only with documented compromise (~€0, weakest learning). Pick one.
3. **ALZ module vs. hand-rolled** — use `Azure/caf-enterprise-scale` or build MG/policy from scratch? Recommendation: hand-rolled for the *first* MG layer (you learn more), then evaluate the module for policy assignment volume.
4. **Workload compute** — Azure Functions (consumption, cheaper, more Azure-native) vs. Container Apps (more portable, more Kubernetes-adjacent, slightly more expensive). Defend the choice.
5. **Naming convention** — CAF naming convention (`<resource>-<workload>-<env>-<region>-<instance>`) or custom? Recommendation: CAF. Easy win.
6. **Tag taxonomy** — minimum required tags enforced by policy. At least `Environment`, `CostCenter`, `Owner`, `DataClassification`. Decide values now, before policy is written.
7. **Region** — single region for the lab. Recommendation: `westeurope` for Eyal's location, but `northeurope` is cheaper for some services. Check both.
8. **State storage location** — which sub hosts the Terraform state storage account? Recommendation: Management sub. Note the bootstrap chicken-and-egg: `00-bootstrap` runs before `05-subscriptions` creates the Management sub, so bootstrap initially uses a temporary local backend, then migrates state once Management sub exists.
9. **`~/.keystone/secrets.env` initialized** — Eyal creates the file with `mkdir -p ~/.keystone && touch ~/.keystone/secrets.env && chmod 700 ~/.keystone && chmod 600 ~/.keystone/secrets.env`. Confirms `.gitignore` and `secrets.example.env` are in place before any other layer is written.

### Reminder: Going-Public Checklist

When (not if) this repo is flipped to public, the checklist in Section 6 ("Going-public checklist") must be run end-to-end and its results captured in `docs/pre-publication-audit.md`. Do not flip the repo to public without that audit on file. Specifically the `gitleaks` full-history scan is mandatory — accidental secrets in deleted commits remain leaked.

---

## 11. What This File Is Not

This file is the *operating contract* for Claude Code on this repo. It is not:
- A CV bullet. Don't paraphrase from it for CV/LinkedIn content. The honesty boundary in Section 1 governs all narrative output.
- A finished design. Sections 3, 6, and 9 contain open decisions. They get resolved in session 1, documented as ADRs, and then this file gets updated to reflect the resolutions.
- A substitute for Eyal reading Microsoft's CAF Enterprise-Scale docs. Read the source: https://learn.microsoft.com/azure/cloud-adoption-framework/ready/enterprise-scale/

---

*Last updated: session 0 + MCA + rename + public-repo hygiene + MG/sub prefix rename. Changes: project renamed Streamline → **Keystone** (platform) with **ReelHouse** as workload tenant; subscription names use `keystone-` prefix (not `sub-`); MG names use `keystone-` prefix (top-level MG is just `keystone`); every sub is explicitly assigned to an MG, no Tenant Root floaters; new Section 6 codifies the public-repo secrets contract — fixed `~/.keystone/secrets.env` path, in-repo `secrets.example.env` companion, gitleaks pre-commit + CI, mandatory full-history audit before publication; renumbered subsequent sections (Cost → 7, Break/Debug → 8, Behavioral Contract → 9, Open Decisions → 10, What This File Is Not → 11). Update this line every time the file changes.*
