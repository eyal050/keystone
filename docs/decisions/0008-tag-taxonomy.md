# ADR-0008: Required-tag taxonomy with enumerated values

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

CLAUDE.md §2 calls for *"required tags enforced by policy"* and §10
narrows the minimum set to `Environment`, `CostCenter`, `Owner`,
`DataClassification`. Decisions on **which values are allowed** must be
made before the policy assignments that enforce them are written —
otherwise the policy assignments either accept anything (defeats the
purpose) or reject everything (blocks deployment).

## Decision

Four required tags. Each is enforced by an Azure Policy assignment at
the top-level `keystone` MG (so policy inherits to every sub, RG, and
resource). The policy effect is **Deny** on create/update if the tag is
missing or holds a value outside the allowed enum.

### Tag schema

| Tag | Allowed values | Default at MG inheritance | Notes |
|---|---|---|---|
| `Environment` | `platform`, `dev`, `prod`, `sandbox` | — | Maps loosely to MG branch: anything under `keystone-platform-*` uses `platform`; workload subs use `dev`/`prod`; the `keystone-sandbox` MG uses `sandbox`. |
| `CostCenter` | `keystone-lab` | `keystone-lab` | Single-valued by design. Required-and-restricted exercises the "require + restrict" pattern even when only one valid value exists. |
| `Owner` | `eyal050` | `eyal050` | GitHub handle. **Do not use email** — per CLAUDE.md §6, personal email addresses are sensitive and must not appear in committed files or tag values. |
| `DataClassification` | `public`, `internal`, `confidential`, `restricted` | — | Standard 4-tier. Applied at resource level, not at MG/sub. |

### Resource-level guidance for `DataClassification`

| Resource shape | Classification |
|---|---|
| Static frontend HTML / JS, public Front Door endpoints | `public` |
| Metadata DB (PostgreSQL, app metadata), Log Analytics tables | `internal` |
| Uploaded video blobs (user content) | `confidential` |
| Key Vault secrets, SAS signing keys, OIDC federated credentials | `restricted` |

## Consequences

**Positive:**

- Enumerated values mean policy assignments are deterministic. A
  resource is either compliant or not — no ambiguity.
- The "require-and-restrict" mechanic is exercised on every tag, so the
  policy authoring muscle gets full practice.
- `Owner` using a GitHub handle keeps Section-6 secrets discipline
  intact — the tag value is already-public and safe to surface in
  Cost Management exports.
- Resource-level `DataClassification` guidance creates a natural
  conversation about which resources should sit behind which controls
  (Key Vault private endpoints, Storage SAS lifetimes, etc.).

**Negative / trade-offs:**

- Adding a new environment or owner is a policy-edit + assignment-redeploy,
  not a free-form tag write. This is the intended friction.
- Single-valued `CostCenter` looks contrived. In a real org it would be
  drawn from a chargeback system. Here it is a placeholder mechanic.

## Alternatives considered

- **Free-form tag values, presence-only enforcement** — rejected.
  Defeats the purpose of policy enforcement; first typo poisons the
  taxonomy.
- **Audit effect instead of Deny** — rejected for non-compliance gets
  catalogued but not blocked, which is the wrong default for a lab whose
  point is to exercise enforcement. Audit-only assignments can be added
  later for "advisory" tags (e.g., `Component`, `BackupTier`).
- **Larger required tag set (e.g., `Component`, `LifecycleStage`)** —
  deferred. Start narrow; add tags when a concrete policy needs them.
