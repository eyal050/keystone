# Pre-Publication Security Audit

> Required by CLAUDE.md §6 ("Going-public checklist") and §10 before the repo
> is ever flipped to public. This file records the audit results. Re-run and
> update it immediately before actually changing repo visibility.

- **Audit date**: 2026-05-29
- **Auditor**: Eyal + Claude
- **Repo state at audit**: private; latest work = Terraform CI slice (ADR-0018)
- **Outcome**: working tree clean; **one real leak found and remediated** (home
  IP, scrubbed from history); one metadata item consciously deferred.

## Checklist results (CLAUDE.md §6)

| # | Check | Result |
|---|---|---|
| 1 | `gitleaks` working tree (`--no-git`) | ✅ zero findings |
| 2 | `gitleaks` full git history | ✅ zero findings (46 commits) |
| 3 | Manual grep of **all history** for every sensitive value in `~/.keystone/secrets.env` | ⚠️ 2 findings (below); IP remediated |
| 4 | `docs/secrets-inventory.md` exists and is complete | ✅ updated with the 5 new CI/CD secrets |
| 5 | `.tfvars.example` for every layer, placeholders only | ✅ all 6 platform layers + `workloads/reelhouse/dev` |
| 6 | Rotate anything briefly committed | ✅ N/A — the only leak was a home IP (not a rotatable credential); see Finding 1 |
| — | Broad sweep: other literal public IPv4 / real GUIDs in tracked files | ✅ none (inventory GUIDs are the all-zeros placeholder; policy GUIDs are public built-ins) |

Tooling note: `gitleaks` has **no bare-IP rule**, so it did **not** catch the
home IP — the manual grep (check 3) did. This is exactly why §6 mandates both.

## Finding 1 — 🔴 Home IP in `docs/decisions/0016-…md` (REMEDIATED)

- **What**: the operator's literal public IP (`KEYSTONE_OPERATOR_IP`) was written
  into ADR-0016 (`> the operator's public IP (…)`), present in HEAD and in
  history (introduced by commit `d9f9435`).
- **Severity**: §6 violation — "IP addresses of personal infrastructure (home
  IP)" must never be in a tracked file.
- **Remediation**:
  1. Redacted in HEAD (commit `f74c93e`): the literal replaced with a pointer to
     `KEYSTONE_OPERATOR_IP` in `~/.keystone/secrets.env`.
  2. Scrubbed from **all history** with `git filter-repo --replace-text`
     (literal → `***REDACTED-IP-SEE-SECRETS-ENV***`), force-pushed
     (`f74c93e` → `4d5c7e3`). Verified: `git log -p --all | grep <ip>` = **0**;
     `gitleaks` full history re-run = no leaks.
- **Residual risk**: GitHub may retain the old unreachable commit objects for a
  period and the repo was private (operator-only access) throughout, so exposure
  was effectively nil. A home IP is not a rotatable credential. Acceptable.

## Finding 2 — 🟢 Git author email in commit metadata (ACCEPTED)

- **What**: the commit author email appears in every commit's `Author:` metadata
  (not in any file). Visible on a public repo.
- **Decision (2026-05-29)**: **accepted as public** — Eyal chose to leave the
  commit-author email. A commit email is commonly public and is not a credential.
  No history rewrite required for this item.

## Final go-public verification (2026-05-29)

Re-ran the entire §6 checklist immediately before flipping visibility:

- `gitleaks` working tree: **no leaks**.
- `gitleaks` full history: **no leaks** (47 commits).
- Manual grep of all history for every secret value (tenant ID, all five
  subscription IDs, billing account/profile/scope IDs, operator IP):
  **0 matches each**.
- `secrets-inventory.md`: complete (incl. CI/CD secrets). `.tfvars.example`:
  full coverage.
- Finding 1 (home IP): scrubbed from history; Finding 2 (author email): accepted.

**Result: PASS.** Repo flipped to public on 2026-05-29.

## Post-publication hardening (now that env protection rules are available)

- **Required-reviewer gate**: added on the `workload-dev` GitHub Environment;
  the `reelhouse-dev-apply.yml` `push: branches:[main]` trigger restored so the
  apply gate is now a real human approval (ADR-0018), not just manual dispatch.

## On every future visibility-affecting change

Re-run this entire checklist — it only covers history up to the date above.

## Security review (code) — 2026-05-29

A focused security review of the CI slice (`/security-review`, scope
`d329529..HEAD`: the two CI workflows + `cicd.tf`) found **no HIGH/MEDIUM
exploitable vulnerabilities**. Verified controls: no hardcoded secrets (all
`${{ secrets.* }}`); no GitHub Actions script injection (plan comment reads a
file, no untrusted `${{ }}` interpolation in `run:`/`script:`); `pull_request`
(not `pull_request_target`) so fork PRs get no OIDC token/secrets; minimal
`permissions:`; and the ABAC-constrained RBAC-admin prevents privilege
escalation by construction. Forward-looking note: keep the `pull_request`
trigger — never expose secrets to untrusted fork PRs running `terraform plan`.
