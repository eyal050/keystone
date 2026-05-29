# ADR-0014: Defer APIM + Front Door in the workload (cost/learning trade)

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Supersedes**: —
- **Revises**: [CLAUDE.md §2 workload scope](../../CLAUDE.md), which lists Azure Front Door (Standard) and API Management (Developer) as in-scope workload components

## Context

CLAUDE.md §2 enumerates 7 workload components for ReelHouse:

| # | Component | Purpose |
|---|---|---|
| 1 | Azure Front Door (Standard) | Public entry point |
| 2 | API Management (Developer) | Gateway behind FD, PE into spoke |
| 3 | Azure Functions or Container Apps | API compute (ADR-0006 picked ACA) |
| 4 | Azure Storage (Blob) + PE | Video storage, SAS URLs |
| 5 | PostgreSQL Flexible B1ms + PE | Metadata |
| 6 | Key Vault + PE | SAS signing keys, DB conn strings |
| 7 | Minimal static frontend | Upload + playback |

By 2026-05-29 the platform layer is substantively complete (00 → 40 + workload spoke). The remaining decision is the *workload scope*: how much of §2 to actually build.

Two of the seven components are disproportionately expensive for the learning surface they add:

- **APIM Developer**: ~€40/mo always-on. Primary learning surface = API gateway routing + OAuth-style policy attachment. The hub-spoke + private-endpoint pattern that APIM would also exercise is already covered by KV, Postgres, Blob, and ACA private endpoints.
- **Front Door Standard**: ~€30/mo base + usage. Primary learning surface = global routing, WAF, CDN. None of these have a meaningful use case in a single-region personal lab.

Combined: ~€70/mo extra always-on, ~50% extra build time today, and the marginal learning is mostly "more resource types in the same patterns we already exercise."

## Decision

**Skip APIM (A1) and Front Door (F1) for the ReelHouse v1 workload.**

The workload's public entry point becomes **Azure Container Apps' own external ingress** — a public FQDN of the form `<app>.<env>.azurecontainerapps.io` with TLS terminated by ACA. Traffic flows directly to the Container App from the internet; no upstream gateway.

Concrete shape:

- **In scope** (built today): D1 (Postgres + PE), K1 (Key Vault + PE), S1 (Blob + PE), C1 (ACA env + Container App with external ingress + managed identity), W1 (minimal static frontend served by the Container App itself).
- **Out of scope** (deferred): A1 (APIM), F1 (Front Door).
- **Future revisit**: if a real reason emerges (multi-region, WAF requirement, OAuth-style API protection for external clients), land A1 + F1 in a later session. Container App's ingress is configured for `external = true` and serves directly; switching to "internal only behind APIM" later requires changing one field and adding the gateway.

## Consequences

**Positive:**

- **Cost saved**: ~€70/mo always-on, ~€15-30/mo even with an ADR-0010-style on-demand pattern. For a personal lab this is significant.
- **Build time saved today**: ~30-50% of the workload's runway. Lets the substance (private endpoints, ACA managed-identity → KV/Blob/Postgres, working video upload/share flow) land properly rather than rushed.
- **No learning loss on platform patterns**: KV+Postgres+Blob private endpoints fully exercise the central-DNS / spoke-PE pattern. ACA managed-identity exercises the workload-MI → platform-resource pattern. APIM and Front Door would add resource types, not new patterns.
- **Deferral is interview-defensible**: same shape as ADR-0010 (firewall on-demand) and ADR-0011 (identity collapsed). Cost-conscious, deliberately documented, reversible.

**Negative / trade-offs:**

- **No WAF, no global CDN, no rate limiting** in front of the workload. For a personal lab serving Eyal alone this is fine; for an interview-presentable lab that someone might poke at, exposing ACA directly is a real attack surface. Mitigation: don't share the URL publicly. The Container App's FQDN is unguessable enough for a lab.
- **TLS cert is ACA's auto-managed cert on the `*.azurecontainerapps.io` domain.** No custom domain. Production would terminate on Front Door with a custom domain.
- **No staged rollout / canary / traffic-splitting** at the gateway layer. ACA itself supports revision-based traffic splitting, so that pattern is still exercisable — just at the ACA layer, not the Front Door layer.
- **`privatelink.azure-api.net` and (eventually) Front Door-related DNS zones** sit unused in the hub. They were created in E3 anticipating workload use; the workload doesn't use them today. Cost: ~€0.50/mo for the APIM zone. Worth keeping (zone deletion + future re-creation is more painful than €0.50/mo).

**Interview pre-rehearse:**

> *"My personal lab doesn't run APIM or Front Door. In a production workload I'd terminate TLS on Front Door with WAF rules, route through APIM for OAuth-style policy and rate limiting, then hit ACA via private endpoint. For the lab I exposed ACA directly because the cost-to-learning ratio of APIM and Front Door didn't justify them — the platform patterns I cared about (private endpoints, managed identity, hub-spoke, central DNS) are exercised end-to-end by KV, Postgres, and Blob. ADR-0014 captures that trade."*

## Alternatives considered

- **Full §2 coverage with APIM + Front Door always-on.** Rejected: ~€70/mo extra, ~50% extra build time, marginal learning.
- **Full §2 coverage with APIM + Front Door on-demand (ADR-0010 shape).** Considered. Would save ~€50/mo of the gross cost. Still adds the build complexity of the on-demand toggle, and the gateway when off means the workload's public surface vanishes (the inverse of what's wanted — workload should be reachable, the gateway is the optional layer). Rejected as poor ergonomic fit.
- **Skip even more (no Postgres, in-memory metadata).** Rejected: Postgres is €12/mo and exercises the private-endpoint + KV-stored-credential pattern that's central to the workload's learning value.

## Future revisit triggers

Revisit this ADR when:

- A real use case emerges for WAF, custom domains, or global routing (the lab grows to serve external users).
- Eyal wants to demonstrate OAuth-style API protection (which APIM does well) for interview prep.
- The lab grows multi-region — Front Door becomes necessary.
- A future workload sub-chunk produces a `*.azurecontainerapps.io` URL that's too embarrassing to share for demo purposes — custom domain via Front Door becomes the easy fix.

Until any of those fires, the no-gateway topology stands.
