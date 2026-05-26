# ADR-0005: Azure Firewall Basic with scheduled deallocation

- **Status**: Superseded in part by [ADR-0010](0010-firewall-on-demand-not-scheduled.md) on 2026-05-25 — the *availability model* (scheduled deallocation) was replaced by on-demand provisioning; the *tier choice* (Basic) is retained
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

Azure Firewall is the centre of gravity of a hub-spoke ESLZ — central
egress, UDR-driven traffic forcing, DNAT for inbound flows.
Three tiers exist:

| Tier | Sticker price | What you learn |
|---|---|---|
| Standard | ~€800/mo always-on | Full ESLZ surface: TLS inspection, IDPS, threat-intel feeds |
| Basic    | ~€275/mo always-on | Core hub-spoke + UDR + central egress + rule collection groups |
| (None — NSG only) | €0 | NSGs + Service Tags, but skips the *central egress* pattern |

Lab budget is real and the Firewall is by far the most expensive single
component of the platform. The point of the lab is to learn the
patterns interviewers ask about; that does not require Standard's
premium features.

## Decision

**Azure Firewall Basic in the hub VNet**, with **scheduled deallocation**
via a GitHub Action that stops the firewall during nights and weekends
and restarts it during active dev sprints.

Concretely:

- Tier: `Basic`, SKU `AZFW_VNet`.
- Schedule: deallocated Mon–Fri 21:00 → 08:00 local, full weekends off,
  managed by a workflow in `.github/workflows/firewall-schedule.yml`
  (to be written when `platform/30-connectivity` lands).
- Realised cost target: ~€80–120/mo at typical lab utilisation.

## Consequences

**Positive:**

- Exercises every part of the hub-spoke pattern that matters for ESLZ
  fluency: hub VNet, firewall subnet, UDR forcing traffic through the
  firewall, rule collection groups, DNAT, network rules, application
  rules.
- ~€100/mo realised cost is defensible for a personal lab.
- Deallocation/reallocation cycle teaches operational discipline —
  drift between "deployed" and "running" state shows up in resource
  provider events.

**Negative / trade-offs:**

- No TLS inspection. Cannot demonstrate inspect-then-allow flows for
  HTTPS traffic.
- No IDPS, no threat intel feeds. These are Standard-tier features
  that would be valuable in a real enterprise but do not shape the
  Terraform learning surface.
- Cold-start time on restart is ~5–10 minutes. Workload smoke tests
  scheduled during the off-window will fail.

**Interview-defensibility weakness Eyal should pre-rehearse:**

> *"Why Basic, not Standard?"*

The honest answer: cost. Standard's premium features (TLS inspection,
IDPS) are real enterprise differentiators but the *Terraform* surface
for them is small. Basic exercises the same `azurerm_firewall`,
`azurerm_route_table`, rule collection group, and DNAT primitives as
Standard. The chosen trade-off is to spend the saved budget on
exercising more *breadth* (cost exports, custom RBAC, break/debug
scenarios) rather than firewall *depth*.

## Alternatives considered

- **Firewall Standard with the same deallocation pattern** — rejected.
  Even at ¼ uptime, Standard runs ~€200/mo. The marginal learning over
  Basic does not justify the marginal cost in a personal lab.
- **NSG-only, no firewall** — rejected. Skips the entire central-egress
  pattern. Hard to defend in an ESLZ-focused interview because the hub
  VNet stops being load-bearing.
- **Always-on Basic, no deallocation** — rejected. ~€275/mo realised
  is harder to justify than ~€100/mo, with no learning upside.
