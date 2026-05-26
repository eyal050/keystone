# ADR-0010: Firewall is on-demand (default off), not scheduled

- **Status**: Accepted
- **Date**: 2026-05-25
- **Decider**: Eyal
- **Supersedes**: [ADR-0005](0005-firewall-basic-with-deallocation.md) (in part — keeps the tier choice, replaces the availability model)

## Context

[ADR-0005](0005-firewall-basic-with-deallocation.md) chose Azure Firewall
Basic with a *scheduled deallocation* pattern (Mon–Fri 21:00–08:00 local
+ weekends off), targeting ~€100/mo realised cost.

After E1 of `platform/30-connectivity` landed and the cost shape became
concrete, two things changed the calculus:

1. **Lab session pattern doesn't match the schedule.** ADR-0005 assumed
   "active dev sprints during weekday business hours." In practice, lab
   sessions are 2–4 hours at a time, often days apart — somewhere
   between 4 and 10 hours of active firewall use per week. The
   scheduled model still bills for the unused weekday business hours.
   At ~6h/week actual use vs. ~65h/week scheduled uptime, ~90% of the
   scheduled cost is wasted.

2. **A better pattern exists for this usage profile.** Feature-flagged
   infrastructure — `count = var.enabled ? 1 : 0` on cost-bearing
   resources — is at least as common in real ESLZ implementations as
   scheduled deallocation, and produces a strictly better cost outcome
   for unpredictable, low-frequency usage.

## Decision

The firewall is **off by default** and **created on-demand** for
sessions that need it.

Concretely:

- `var.firewall_enabled` (bool, default `false`) in `platform/30-connectivity`
  gates the cost-bearing resources via `count`:
  - `azurerm_firewall.this`
  - `azurerm_public_ip.fw_data`
  - `azurerm_public_ip.fw_mgmt`
- The firewall policy (`azurerm_firewall_policy.this`) stays always-on.
  It is free and standalone — keeping rules in state across cycles
  avoids re-deriving them every session.
- `make firewall-up` and `make firewall-down` wrap
  `terraform apply -var=firewall_enabled=true|false` in
  `platform/30-connectivity`.
- **No cron, no GitHub Actions workflow for firewall lifecycle.**
  Lifecycle is a deliberate operator action.

## Consequences

**Positive:**

- **Idle cost is €0.** The firewall policy has no compute charge, and
  no public IPs exist when the firewall is off.
- Exercises a different but equally valid ESLZ pattern: feature-flagged
  conditional infrastructure with graceful absence in downstream
  consumers.
- No DST handling, no out-of-band cron, no Terraform-vs-cron drift mode,
  no `lifecycle.ignore_changes` lifecycle hacks.
- Single source of truth — Terraform owns reality, no GH Actions workflow
  competing for control.
- Operator-aware lifecycle is interview-defensible: "I made the cost
  trade explicit in a variable, rather than hiding it behind a schedule."

**Negative / trade-offs:**

- ~10–15 minute provisioning time per session (vs. 0 min in the
  scheduled model, where the firewall would already be running during
  business hours). The first 15 minutes of any session that needs the
  firewall is spent waiting.
- Each `firewall-up` cycle allocates new public IPs. **The firewall's
  egress IP changes between sessions.** Downstream consumers (workload
  allow-lists, DNS records pointing at the firewall IP) must be
  tolerant of this or refresh on bring-up. This is a real ergonomic
  cost once the workload depends on the firewall.
- The ESLZ pattern of "scheduled deallocation of a fixed resource" is
  no longer exercised. **Pre-rehearse for interviews:** be ready to
  articulate the trade-off explicitly — *"I optimised for cost in a
  personal lab; in production I'd choose between scheduled deallocation
  and always-on based on the SLO and traffic profile."*

**What this does NOT change from ADR-0005:**

- Tier remains **Basic**.
- Hub-spoke topology, central-egress pattern, UDR forcing — all intact
  when the firewall is up.
- When running, the firewall exercises the same Terraform surface as
  ADR-0005 intended: `azurerm_firewall`, `azurerm_firewall_policy`,
  `azurerm_route_table`, rule collection groups, DNAT, network rules,
  application rules.

## Alternatives considered

- **ADR-0005 unchanged (scheduled deallocation).** Rejected: the lab
  usage profile doesn't match the assumption that made the scheduled
  pattern cheap. At realistic session frequency, scheduled deallocation
  still bills ~10× more than on-demand for the same hours of actual
  use.
- **Stop/start same firewall via `az` CLI with `ignore_changes`
  lifecycle.** Rejected: public IPs continue to bill (~€6.40/mo for two
  Standard Static PIPs) even when the firewall is stopped, so "0-cost
  when off" is not achievable. Also adds `lifecycle.ignore_changes`
  plumbing the conditional-count pattern doesn't need.
- **Always-on Basic.** Rejected: ~€275/mo for a personal lab is hard to
  justify when session frequency is low and unpredictable.

## Migration from ADR-0005

ADR-0005 was Accepted on 2026-05-21 but no firewall has yet been
provisioned — `platform/30-connectivity` E1 landed the hub VNet and
subnets but blocked on the firewall sub-chunk for cost reasons. The
GitHub Actions workflow that ADR-0005 contemplated
(`.github/workflows/firewall-schedule.yml`) was never written.

This ADR therefore costs no rework. It changes the design of work
not yet done.
