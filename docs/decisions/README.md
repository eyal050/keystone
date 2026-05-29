# Architecture Decision Records

Each meaningful architectural choice in Keystone lives here as a numbered
ADR. Per [CLAUDE.md §9](../../CLAUDE.md), a session is not "done" until
any new decision made during the session has a corresponding ADR.

## Format

ADRs follow a trimmed [MADR](https://adr.github.io/madr/) shape:

- **Status** — Proposed / Accepted / Superseded
- **Context** — what forces the decision, what constraints apply
- **Decision** — what was chosen, in one or two sentences
- **Consequences** — positive and negative outcomes, and the trade-offs you must be ready to defend in an interview
- **Alternatives considered** — the other options and why each was rejected

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-directory-per-env.md) | Directory-per-environment, not branch-per-environment | Accepted |
| [0002](0002-region-westeurope.md) | Primary region: `westeurope` | Accepted |
| [0003](0003-naming-convention-caf.md) | CAF naming convention via `Azure/naming` module | Accepted |
| [0004](0004-mg-policy-hand-rolled-then-evaluate-module.md) | Hand-roll MG hierarchy and policy assignments; re-evaluate `Azure/caf-enterprise-scale` later | Accepted |
| [0005](0005-firewall-basic-with-deallocation.md) | Azure Firewall Basic with scheduled deallocation | Superseded in part by [0010](0010-firewall-on-demand-not-scheduled.md) |
| [0006](0006-workload-compute-aca.md) | ReelHouse compute: Azure Container Apps | Accepted |
| [0007](0007-state-storage-in-platform-management.md) | Terraform state SA in `keystone-platform-management` | Accepted |
| [0008](0008-tag-taxonomy.md) | Required-tag taxonomy with enumerated values | Accepted |
| [0009](0009-subscription-staging-management-first.md) | Stage subscription vending: Management first, others post-quota | Accepted |
| [0010](0010-firewall-on-demand-not-scheduled.md) | Firewall is on-demand (default off), not scheduled | Accepted |
| [0011](0011-identity-collapsed-into-management.md) | Identity layer collapses into Management subscription (MCA quota) | Accepted |
| [0012](0012-adopt-lab-foundation-as-workload-sub.md) | Adopt pre-existing `lab-foundation` sub as the workload host (brownfield) | Accepted |
| [0013](0013-workload-owns-spoke-network.md) | Workload layer owns the spoke VNet, both peerings, and spoke DNS zone links (via provider aliasing) | Accepted |
| [0014](0014-defer-apim-and-front-door.md) | Defer APIM + Front Door in workload (cost/learning trade; ACA external ingress as public entry) | Accepted |
| [0015](0015-cicd-acr-uami-oidc.md) | CI/CD via ACR (Basic) + UAMI + federated OIDC; CI owns image, Terraform ignores it | Accepted |
