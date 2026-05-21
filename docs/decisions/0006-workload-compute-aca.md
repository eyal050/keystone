# ADR-0006: ReelHouse compute — Azure Container Apps

- **Status**: Accepted
- **Date**: 2026-05-21
- **Decider**: Eyal
- **Supersedes**: —

## Context

ReelHouse needs a place to host the upload + share-link API. CLAUDE.md
§4 frames the choice as **Azure Functions vs Azure Container Apps** and
adds: *"Eyal picks, defend the choice."*

The two have meaningfully different shapes:

| | Azure Functions (Flex Consumption) | Azure Container Apps |
|---|---|---|
| Unit of deploy | Function code + bindings, packaged as zip | OCI container image |
| Idle cost | Truly €0 at zero traffic | ~€5–15/mo for the environment, even at zero replicas |
| Cold start | Fast (Flex Consumption tier) | Comparable on consumption profile |
| Long-running / stateful processes | Awkward (timeout caps, no listening sockets) | Native — multi-port containers, sidecars, Dapr |
| Migration path to AKS | Containerise + rewrite triggers | Same image, swap control plane |
| Idiomatic for | Short-lived event-driven handlers | Microservices + APIs |

## Decision

**Azure Container Apps** on the consumption profile, deployed to a
Container Apps Environment in the workload spoke VNet (internal-only;
ingress fronted by API Management).

## Eyal's defense (the part the ADR exists to capture)

> *"I chose ACA over Functions because future versions of ReelHouse
> may be more complex than an event-driven API — multi-process, stateful,
> longer-lived — and ACA is the better runtime for that shape. And if I
> eventually move all of ReelHouse to AKS, the migration from ACA is more
> straightforward than from Functions, because the unit of deploy
> (a container image) is already correct."*

Two threads:

1. **Complexity headroom.** ReelHouse's v1 surface is small (upload, list,
   share-link, playback) and Functions would suffice today. ACA is chosen
   for the v2+ surface — playlists, share-link analytics, transcoding
   workers — where Functions becomes awkward and ACA stays comfortable.
2. **AKS migration optionality.** ACA runs OCI containers on a managed
   K8s control plane (KEDA + Dapr + Envoy). Migrating to AKS is taking
   the same image and rewriting the deployment manifest. From Functions
   you would containerise first, which is a larger rewrite.

## Consequences

**Positive:**

- Container image is the deploy unit from day 1 — same artefact runs on
  a developer laptop (`docker run`), in ACA, and (later) on AKS.
- ACA's K8s primitives are exposed (KEDA scaling rules, Dapr building
  blocks, container probes) without the operational burden of AKS
  (no node pools, no cluster upgrades).
- Private VNet integration without the "premium plan" surcharge that
  Functions imposes for the same.

**Negative / trade-offs:**

- Non-zero idle cost. The ACA Environment runs €5–15/mo even at zero
  replicas — Functions Flex Consumption is truly €0 idle.
- Container build + registry push pipeline becomes part of the
  deployment surface. Functions zip deploy is simpler.

**Interview-defensibility weakness Eyal should pre-rehearse:**

> *"If AKS is the destination, why not start with AKS?"*

The honest answer: ACA gives the same K8s primitives (KEDA, Dapr, sidecars,
container probes) at a fraction of the operational burden — no node
pools to manage, no Helm to vet, no cluster upgrade cadence to track.
For a workload at ReelHouse's current scale, the AKS operational tax
would dwarf the workload itself; ACA is the right *granularity* for now
and remains a clean stepping-stone for later.

A secondary weakness to be ready for: the complexity-headroom argument
is speculative. If ReelHouse v2 features never land, ACA's idle cost
versus Functions Flex Consumption was paid for nothing. The defense is
that the AKS migration argument stands on its own even if v2 stays minimal.

## Alternatives considered

- **Azure Functions (Flex Consumption)** — rejected per Eyal's defense
  above. Idiomatic for event-driven APIs, €0 idle, but the migration
  path to a more complex runtime is heavier.
- **App Service Plan (Basic / Standard)** — rejected. Always-on cost,
  no scale-to-zero, weakest "modern Azure" story.
- **AKS from day 1** — rejected. Operational burden disproportionate to
  workload size. Worth reconsidering once ReelHouse outgrows ACA's
  consumption profile.
