# ADR-0001: Directory-per-environment, not branch-per-environment

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

Every multi-environment Terraform repo eventually picks a strategy for
separating `dev`, `prod`, and similar. Two common choices:

1. **Branch-per-env** — one branch per environment, each branch has
   the same `main.tf` with environment-specific values inline.
   Promotion is `git merge dev → prod`.
2. **Directory-per-env** — sibling directories, identical `main.tf`,
   different `terraform.tfvars` and `backend.tf` per directory.

Eyal's prior GuardianLink lab uses branch-per-env and has accumulated
the pain points that come with it.

## Decision

Keystone uses **directory-per-env**:

```
workloads/reelhouse/
├── dev/
│   ├── main.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   └── backend.tf
└── prod/
    ├── main.tf          # identical to dev/main.tf
    ├── variables.tf     # identical to dev/variables.tf
    ├── terraform.tfvars # differs (environment-specific values)
    └── backend.tf       # differs (state file location)
```

The `main.tf` and `variables.tf` files in `dev` and `prod` are **byte-for-byte
identical**. Divergence between them is a failure mode this structure exists
to prevent — if `git diff dev prod -- main.tf` shows anything, that's a
P2 to reconcile.

## Consequences

**Positive:**

- Environment drift is visible. `git diff workloads/reelhouse/dev workloads/reelhouse/prod`
  surfaces accidental divergence immediately.
- Promotion semantics are right-way-up. "Promote dev to prod" means
  propagating the same code, not merging different code.
- Composes naturally with GitHub Environments + required-reviewer gates.
  Each environment has its own workflow run scoped to its directory.
- Each environment has its own state file, no `terraform workspace`
  gymnastics.

**Negative / trade-offs:**

- More directory boilerplate. Three identical-but-not-quite files per env.
- Adding a new environment is a copy operation, not a `git branch`.
  This is a feature: copying forces conscious intent.

## Alternatives considered

- **Branch-per-env** — rejected. Hides environment drift (a diff between
  branches that *should* be identical reads as legitimate code change).
  Inverts promotion semantics. Doesn't compose with GitHub Environments.
- **Terraform workspaces** — rejected. Single state backend, weak
  isolation, easy to apply against the wrong workspace by mistake.
  Microsoft's own guidance recommends against workspaces for environment
  separation.
- **Single module + per-env tfvars without sibling dirs** — rejected.
  No clean place to put per-env `backend.tf`.
