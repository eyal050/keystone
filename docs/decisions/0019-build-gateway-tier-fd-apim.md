# ADR-0019: Build the gateway tier — Front Door Standard + APIM Developer (External VNet mode)

- **Status**: Accepted
- **Date**: 2026-06-01
- **Decider**: Eyal
- **Supersedes**: —
- **Revises**: [ADR-0014](0014-defer-apim-and-front-door.md) (partially supersedes its deferral of APIM + Front Door; see "Consequences" for what ADR-0014's always-reachable principle means in the new topology)

## Context

ADR-0014 deferred APIM and Front Door on a cost-and-learning-ratio argument: the hub-spoke private-endpoint pattern was already exercised by KV, Postgres, and Blob, so APIM + FD added resource types without new patterns. That reasoning was sound at the time.

The revisit trigger is **interview demonstrability**, not uptime and not a production need. Eyal is building this lab to close a specific gap — hands-on fluency with CAF Enterprise-Scale landing zones (CLAUDE.md §1). The lab's honesty boundary still holds:

> "I'm building an Enterprise-Scale landing zone in a personal lab to develop the architectural fluency I didn't get to build in production."

Demonstrating a WAF-gated, APIM-fronted workload is squarely within that framing. "I deferred the gateway tier until I had a reason to build it, then added Front Door + APIM when I wanted to show API management patterns" is the correct interview narrative — not "I have production APIM experience."

Two additional observations made the revisit timely:

1. **The ACA environment is already VNet-injected** (snet-aca-001, per ADR-0013). Flipping ACA to internal ingress is a one-field change. The spoke VNet and subnets are already shaped for APIM (snet-apim-001 reserved).
2. **The on-demand cost pattern is established** (ADR-0010 for firewall, ADR-0017 for data plane). The same `count = var.X_enabled ? 1 : 0` pattern makes the gateway tier free when not in use — cost objection from ADR-0014 drops from ~€70/mo to ~€0/mo idle.

## Decision

**Build Front Door Standard + WAF (Prevention mode) → APIM Developer in External VNet mode → ACA flipped to internal ingress.** All three changes land together as a single gateway-tier toggle.

### Topology

```
Internet
  └── Azure Front Door Standard (WAF, Prevention)
        └── APIM Developer (External VNet mode, public VIP, injected into snet-apim-001)
              └── ACA Container App (internal ingress, reachable only from the spoke VNet)
```

### On-demand gate

A new variable `var.gateway_enabled` (default `false`) gates Front Door and APIM via the standard `count` pattern:

```hcl
count = var.gateway_enabled ? 1 : 0
```

Same shape as ADR-0010 (firewall) and ADR-0017 (data plane). Operators learn one pattern; it composes.

### ACA ingress flip

`internal_load_balancer_enabled = true` on the ACA environment. This is a **permanent** change — not gated by `var.gateway_enabled`. ACA internal ingress is always correct for a workload that sits behind a gateway; exposing it externally when the gateway is off is a worse default security posture than "not reachable when the gateway is off." The consequence for idle state is documented below.

### WAF: custom rules on Standard (DRS deferred to Premium)

Front Door **Standard does not support Azure-managed rule sets** (the Microsoft Default Rule Set / DRS) — managed rules are a **Premium-tier** feature. Standard supports **custom WAF rules only**. So the WAF policy (Prevention mode) carries a custom rule that blocks common SQL-injection patterns in the query string — enough to *demonstrate* WAF blocking end-to-end (an obvious SQLi probe returns 403 from Front Door). Request rate-limiting is enforced at APIM (`rate-limit-by-key`), not duplicated at the WAF.

**DRS is documented here as a deliberate tier tradeoff:** the comprehensive managed rule set would require upgrading to Front Door Premium (~€300/mo while up vs. ~€30 Standard base), which would *also* unlock Private Link origins and thus a fully-private APIM (Internal VNet mode, no public VIP). That fuller topology was considered and rejected on cost (see Alternatives). For the demonstrability driver, Standard + a custom Prevention rule + the two-layer APIM lockdown below covers the learning surface at ~4× lower cost.

### FD-only lockdown — two layers

Traffic reaching APIM must come exclusively from **this** Front Door instance. Two complementary controls enforce this:

**Layer 1 — NSG on snet-apim-001:**

An inbound rule allows TCP 443 only from the `AzureFrontDoor.Backend` service tag. All other internet-sourced traffic is denied.

**Layer 2 — APIM inbound policy (header check):**

```xml
<check-header name="X-Azure-FDID" failed-check-httpcode="403"
              failed-check-error-message="Forbidden" ignore-case="true">
    <value>{{front-door-instance-id}}</value>
</check-header>
```

The `X-Azure-FDID` header carries this Front Door instance's resource ID. APIM rejects any request that does not carry the correct value.

**Why both are required:**

`AzureFrontDoor.Backend` is a **shared service tag** — it represents the IP ranges of all Azure Front Door instances across all tenants. An NSG rule permitting `AzureFrontDoor.Backend` means "any customer's Front Door can reach my APIM," not just mine. The NSG provides network-layer containment (blocks direct internet, raw IPs, other CDNs); the header check provides identity-layer pinning (proves the request came from my FD instance specifically).

NSG = network layer. Header check = identity layer. Both are necessary; neither is sufficient alone.

## Rejected alternative: `ip-filter` APIM policy as a third layer

An APIM `ip-filter` policy that allows only Azure Front Door's edge IP ranges was considered as an additional defense-in-depth measure.

**Rejected** because `ip-filter` requires explicit IP ranges — it cannot consume service tags. Azure's Front Door edge fleet changes over time as Microsoft expands or relocates capacity. Maintaining a static list of Front Door IP ranges creates a **manual-refresh hazard**: any missed update silently 403s legitimate Front Door traffic while the lab appears healthy from non-FD paths. The NSG (which auto-tracks the service tag without manual updates) combined with the header check already achieves the security goal without the maintenance fragility.

## Consequences

**Positive:**

- **Cost when off**: ~€0/mo for the gateway tier (FD + APIM resources absent from state when `gateway_enabled = false`).
- **Cost when on**: ~€70/mo (~€40 APIM Developer + ~€30 FD Standard base + usage). Same figure as ADR-0014's "full §2" estimate, now on-demand rather than always-on.
- **Interview surface**: demonstrates WAF configuration, APIM policy authoring, and the FD-only lockdown pattern — the kind of detail interviewers ask about when exploring API gateway experience.
- **Pattern reuse**: the on-demand gate composes identically with ADR-0010 and ADR-0017. One mental model covers all three.

**Negative / trade-offs:**

- **APIM provision latency**: ~45 minutes from `gateway-up` to APIM serving traffic. Every toggle-on eats this wait. Not a problem for a lab; would be unacceptable in a real deployment without a warm-standby or pre-provisioned instance.
- **Idle = workload NOT publicly reachable**: ACA's ingress flip to internal is permanent. When `gateway_enabled = false`, the workload has no public surface — not even the `*.azurecontainerapps.io` URL that ADR-0014 relied on. This **reverses ADR-0014's "workload always reachable, gateway optional" principle**. The reversal is deliberate: idle security posture (no public surface) is arguably better, and the demonstrability driver no longer requires the always-reachable shortcut.
- **ACA environment recreation is destructive (ForceNew)**: `internal_load_balancer_enabled` forces replacement of the ACA environment. This is a one-time destructive event. The CI workflow (`reelhouse-build-deploy`) must re-run after the flip to repopulate the Container App image, since the recreated environment will be empty.
- **No IP pinning on FD lockdown**: the NSG + header check approach does not hard-pin FD source IPs (by design, per the rejected-alternative reasoning above). Operators should be aware that the NSG service-tag rule is broad; the header check is what actually makes the lockdown tenant-specific.

### Apply-time watch-items (validate/plan pass; these are the apply risks)

The whole tier passes `terraform validate` and `terraform plan` cleanly. Two things are only resolvable at apply (the ~45-min APIM milestone), flagged here so a failure is diagnosed fast rather than mysterious:

1. **Wildcard operation `method = "*"`** on the catch-all API. The azurerm provider accepts it at validate/plan, and it is the semantically-correct "all verbs" intent. If Azure rejects `"*"` at apply, the fix is to replace the single wildcard operation with explicit per-verb operations (at minimum `GET` + `POST`, which is what the ReelHouse Flask app uses) sharing `url_template = "/*"`. This is a strong break/debug seed.
2. **APIM stv1 vs stv2 NSG rules.** The subnet NSG follows the stv2 rule set (443 + 3443 + 6390). Developer-tier instances provisioned in westeurope today land on stv2, so this is correct; if an instance ever lands on stv1, it additionally requires inbound 80 and APIM will fail to provision until the rule is added.

## Interview soundbite

> "A service-tag NSG isn't sufficient alone because `AzureFrontDoor.Backend` is shared across all tenants — anyone's Front Door satisfies it. You pin it to your own instance with the `X-Azure-FDID` header check. NSG is the network layer; the header check is the identity layer."

## Alternatives considered

- **Front Door Premium + DRS managed rules + Private Link origin → APIM Internal VNet mode** (fully private: no public APIM VIP, comprehensive managed WAF, no header-check needed). The cleanest security topology. Rejected on cost: FD Premium is ~€300/mo while up vs. ~€30 for Standard — ~4× the gateway cost for a lab toggled up only for demos. The demonstrability goal (show FD → APIM → private ACA, WAF blocking, the lockdown reasoning) is met by Standard + custom WAF rule + the two-layer lockdown. Revisit if a real need for managed WAF rules or a truly-private APIM emerges.
- **APIM in Internal VNet mode** (private VIP only, no public surface on APIM itself) **without** FD Premium. Would require an extra NVA or Azure Firewall hop for FD → APIM traffic, since a Standard FD backend must be publicly reachable. Adds ~€800/mo firewall cost or NVA complexity. External mode with FD-only lockdown achieves equivalent security for the lab at significantly lower cost and complexity.
- **Container Apps' built-in HTTP scaling rules + custom domains** instead of APIM. Skips the API management learning surface entirely. Rejected: the goal is to demonstrate the FD → APIM → ACA pattern, not just custom domains.
- **Always-on gateway (no `var.gateway_enabled` flag)**. Rejected: ~€70/mo always-on for a lab used infrequently. ADR-0010 and ADR-0017 established the on-demand pattern precisely for this reason.
- **Keep ADR-0014 deferral in place indefinitely**. Remains valid on pure cost grounds. Overridden by the interview-demonstrability trigger evaluated in this ADR.

## Future revisit triggers

- APIM provision latency becomes unacceptable → evaluate APIM v2 (faster provision, but different tier/pricing) or always-on for active sprints.
- Lab grows to serve external users → revisit the on-demand posture; gateway-always-on with cost budgets becomes appropriate.
- Azure Front Door service tag becomes scoped per-tenant (hypothetically) → `ip-filter` policy becomes viable and worth adding as a third layer.
