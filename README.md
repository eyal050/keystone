# Keystone — an Enterprise-Scale Landing Zone lab (with the ReelHouse workload)

Keystone is a personal Azure lab that builds a **Cloud Adoption Framework (CAF)
Enterprise-Scale Landing Zone** from scratch in Terraform — management groups,
Azure Policy, hub-spoke networking, centralized logging, custom RBAC, MCA
subscription vending, and OIDC-federated CI/CD. A small video-sharing app,
**ReelHouse**, runs on top of it as an Application Landing Zone tenant to prove
the platform carries a real workload.

A keystone is the load-bearing stone that locks an arch in place — which is
exactly what a landing zone does for the workloads that sit on it.

---

## Honest framing (please read this first)

I have 16+ years in software/platform engineering, including ~6 years on Azure
DevOps and platform work — but I have **not** personally built a CAF
Enterprise-Scale Landing Zone in production. This lab exists to close that
specific gap:

> *I'm building an Enterprise-Scale landing zone in a personal lab to develop
> the architectural fluency I didn't get to build in production.*

So: every design decision here is mine to defend, and the ADRs in
[`docs/decisions/`](docs/decisions/) record why each was made — but this lab is
**not** a claim of production ESLZ experience. It's how I'm earning the fluency.

---

## What this demonstrates

Platform-engineering skills, each built deliberately rather than via a
turnkey module (the goal is understanding, not speed):

- **Management-group hierarchy** following CAF (Tenant Root → `keystone` →
  platform / landing-zones / sandbox / decommissioned), hand-rolled first to
  learn the seams.
- **Azure Policy at scale** — allowed locations, required tags (a *custom*
  definition, not just built-ins), deny-public-storage, HTTPS/secure-transfer,
  diagnostic settings — assigned at MG scope with inheritance, plus a real
  **policy exemption**.
- **MCA subscription vending** — Terraform creates subscriptions against a
  Microsoft Customer Agreement billing scope and places every one under a
  management group. This "subscription vending machine" is the muscle most home
  labs skip.
- **Hub-spoke networking** — hub VNet + Azure Firewall (on-demand to control
  cost), cross-subscription peering via provider aliases, centrally-managed
  Private DNS zones.
- **Centralized logging** — a Log Analytics workspace in the management
  subscription, with the workload wired to it.
- **CI/CD the way it's actually done** — GitHub Actions with **OIDC federation**
  (no stored credentials), **split least-privilege identities** (read-only on
  PRs, read-write on apply), and an **ABAC-constrained RBAC-admin** grant so the
  pipeline can manage role assignments *without* being able to escalate its own
  privilege. See [ADR-0018](docs/decisions/0018-terraform-ci-workload-dev.md).
- **Cost discipline** — expensive resources (firewall, the workload data plane)
  are default-off and brought up on demand; the lab idles at roughly €7/month.
- **A break/debug practice** — I deliberately break things and diagnose them;
  [`docs/break-debug-log.md`](docs/break-debug-log.md) is a running log of real
  symptom → hypothesis → root-cause → fix war stories (e.g. the full cascade of
  making a single-operator layer safely CI-applyable).
- **Public-repo security hygiene** — `gitleaks` (pre-commit + the
  [pre-publication audit](docs/pre-publication-audit.md)) and a strict
  no-secrets-in-git contract. The audit caught and scrubbed a real leak that
  `gitleaks` alone missed.

ReelHouse (the workload) is intentionally minimal — Container Apps + Blob +
Key Vault + (on-demand) PostgreSQL behind private endpoints. It exists to give
the platform a real tenant, not to be a product.

---

## Architecture at a glance

```
Tenant Root
└── keystone  (top-level MG)
    ├── keystone-platform
    │   ├── keystone-platform-connectivity   → hub VNet, Azure Firewall, Private DNS
    │   ├── keystone-platform-management      → Log Analytics, cost exports, TF state
    │   └── keystone-platform-identity        → custom RBAC (collapsed into mgmt, ADR-0011)
    ├── keystone-landing-zones
    │   └── keystone-landing-zones-corp        → ReelHouse (dev) workload
    ├── keystone-sandbox
    └── keystone-decommissioned
```

Terraform is **directory-per-environment, not branch-per-environment** (the
reasoning is [ADR-0001](docs/decisions/0001-directory-per-env.md)). Platform
layers apply in numeric order, each with its own state:

```
platform/  00-bootstrap → 05-subscriptions → 10-management-groups
           → 20-management → 30-connectivity → 40-identity
workloads/ reelhouse/dev   (sibling prod awaits an MCA subscription-quota raise)
```

The decisions worth skimming: [the full ADR index](docs/decisions/README.md) —
notably directory-per-env (0001), hand-rolled-then-evaluate-module (0004),
firewall-on-demand (0010), the workload owning its network seam (0013), and the
CI/CD slice (0018).

---

## Running it

This is a real Azure lab; running it needs your own Azure tenant + an MCA
billing scope. Full, reproducible setup lives in two places:

- **[`docs/secrets-inventory.md`](docs/secrets-inventory.md)** — every value you
  must supply, what it's for, and the exact command to obtain it. This is the
  single source of truth for bootstrapping a fresh machine.
- **[`CLAUDE.md`](CLAUDE.md)** — the authoritative operating contract for the
  whole repo (structure, secrets policy, cost rules, the destroy safety rules).

Quick start (local):

```bash
# 1. Set up the local secrets file (never committed — see the secrets policy)
mkdir -p ~/.keystone && chmod 700 ~/.keystone
cp secrets.example.env ~/.keystone/secrets.env
chmod 600 ~/.keystone/secrets.env
#    Fill in real values per docs/secrets-inventory.md, then:
source ~/.keystone/secrets.env

# 2. Plan/apply a platform layer (numeric order; each has its own state)
make plan-30-connectivity
make apply-30-connectivity

# 3. Cost check (month-to-date across the MCA billing profile)
./scripts/cost-snapshot.sh
```

CI/CD: pull requests run `terraform plan` (read-only identity, posted as a PR
comment); applies run through a gated GitHub Actions workflow authenticated via
OIDC. See [ADR-0018](docs/decisions/0018-terraform-ci-workload-dev.md).

### Secrets policy (why there are no GUIDs in this repo)

Nothing sensitive is ever committed — no tenant/subscription IDs, billing scope,
keys, IPs, or personal infrastructure details. Local secrets live only in
`~/.keystone/secrets.env`; CI uses GitHub Actions secrets. The contract and the
pre-publication audit process are in [`CLAUDE.md` §6](CLAUDE.md) and
[`docs/pre-publication-audit.md`](docs/pre-publication-audit.md).

---

## Repo map

| Path | What |
|---|---|
| [`platform/`](platform/) | The landing zone, layer by layer (each has its own README) |
| [`workloads/reelhouse/`](workloads/reelhouse/) | The ReelHouse application landing zone |
| [`app/`](app/) | ReelHouse application code (minimal API + static frontend) |
| [`docs/decisions/`](docs/decisions/) | ADRs — one file per decision |
| [`docs/architecture.md`](docs/architecture.md) | As-built architecture + what's pending |
| [`docs/break-debug-log.md`](docs/break-debug-log.md) | The break/debug practice log |
| [`docs/secrets-inventory.md`](docs/secrets-inventory.md) | Everything you must supply to run it |
| [`CLAUDE.md`](CLAUDE.md) | The operating contract (read first if you're contributing) |

---

*Built with deliberate, defensible decisions — feedback and questions welcome.*
