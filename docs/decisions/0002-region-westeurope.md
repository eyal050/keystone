# ADR-0002: Primary region — `westeurope`

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

The lab is single-region by scope decision (multi-region is explicitly
out of scope per CLAUDE.md §2). One primary region must be chosen and
locked early — every resource, every policy "allowed locations"
assignment, every diagnostic setting depends on it.

The candidates were `westeurope`, `northeurope`, and `swedencentral`.

## Decision

`westeurope` is the primary region for all Keystone resources.

The region is parameterised as a Terraform input variable in every layer
so it can be overridden, but the lab is operated single-region in
practice.

## Consequences

**Positive:**

- Closest of the three options for Eyal's location.
- Full breadth of services this lab needs: API Management Developer,
  Front Door Standard, Azure Firewall Basic + Standard, PostgreSQL
  Flexible Server, Container Apps — all GA.
- Largest pool of Microsoft-published reference architectures and
  pricing data points to compare against.

**Negative / trade-offs:**

- Marginally more expensive than `northeurope` on some services. At lab
  volumes the absolute delta is under €5/mo, so this does not justify
  the latency hit of running from Ireland.
- Carbon profile is mid-pack, not best-in-class.

## Alternatives considered

- **`northeurope` (Ireland)** — rejected. Cheaper by single-digit
  percentages on storage and compute, but adds ~15ms latency from a
  Western-European operator and offers no learning gap closure.
- **`swedencentral`** — rejected. Lowest carbon profile of the three,
  good service availability, but no specific learning rationale.
  Worth reconsidering if a future workload requires the carbon profile.
