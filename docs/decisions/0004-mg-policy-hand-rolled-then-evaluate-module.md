# ADR-0004: Hand-roll the MG hierarchy and policy assignments; re-evaluate `Azure/caf-enterprise-scale` later

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

The management-group hierarchy and Azure Policy assignments are the
load-bearing part of Enterprise-Scale. There are two practical ways to
build them in Terraform:

1. **Hand-rolled.** Write `azurerm_management_group`,
   `azurerm_policy_definition`, `azurerm_policy_assignment`,
   `azurerm_role_assignment` resources directly. You author every
   policy assignment.
2. **`Azure/caf-enterprise-scale` module.** Microsoft-published
   Terraform module that implements the canonical ALZ archetypes
   (Decommissioned, Sandbox, Connectivity, Identity, Management,
   LandingZones-Corp, LandingZones-Online) with policy assignments
   pre-baked.

Keystone's primary purpose is for Eyal to build hands-on fluency with
ESLZ primitives. The module's archetypes hide a great deal of behaviour
behind opaque inputs — useful in production, anti-useful for learning.

## Decision

The first MG layer (`platform/10-management-groups`) is **hand-rolled**:
explicit `azurerm_management_group`, explicit `azurerm_policy_definition`
for the custom policies required by CLAUDE.md §2, explicit
`azurerm_policy_assignment` blocks at each MG scope.

The decision to adopt `Azure/caf-enterprise-scale` is **deferred** —
revisit once either (a) policy assignment count crosses ~30 and the
hand-rolled approach starts repeating itself, or (b) Eyal has
demonstrated he can write a policy assignment without referring to docs.

When the module is adopted (if it is), it replaces only the policy
assignment surface, not the MG hierarchy. The hierarchy is small enough
that hand-rolling it remains defensible.

## Consequences

**Positive:**

- Every line of MG / policy code in the repo is something Eyal authored
  and can defend in an interview.
- No hidden behaviour. What's in the `.tf` file is what's in Azure.
- Policy exemption mechanics and `DeployIfNotExists` remediation flows
  are exercised directly, not abstracted away.

**Negative / trade-offs:**

- Slower to "complete-looking" ESLZ. The module gives you 100+ policy
  assignments out of the box.
- Some policy assignments will be tedious by hand (e.g., the
  `Allowed locations` family applied at every MG). Repetition is part
  of the learning, but at a point it stops teaching.
- Re-platforming onto the module later is migration work, not a flag flip.

**Interview-defensibility weakness Eyal should pre-rehearse:**

> *"Most enterprises use the ALZ module — why didn't you?"*

The honest answer: in production, the module is right. In a lab whose
goal is *learning the primitives*, the module is wrong. Once primitives
are second nature, the module is the right next step.

## Alternatives considered

- **`Azure/caf-enterprise-scale` from day 1** — rejected. Faster to a
  working ESLZ, but skips the muscle memory that this lab exists to build.
- **Hand-rolled forever** — deferred. Viable for this lab's scope; at
  production policy volumes it becomes a maintenance burden.
- **Hand-rolled MG + module-driven policy only** — possible hybrid; revisit
  if the policy hand-rolling becomes the limiting factor before MG
  hierarchy work feels complete.
