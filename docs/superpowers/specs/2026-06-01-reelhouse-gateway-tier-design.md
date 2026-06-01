# Design: ReelHouse Gateway Tier (Front Door + APIM)

- **Date**: 2026-06-01
- **Status**: Approved (brainstorming) — pending implementation plan
- **Layer**: `workloads/reelhouse/dev/`
- **Supersedes (partially)**: ADR-0014 (deferral of APIM + Front Door)
- **New ADR to write**: ADR-0019

## 1. Why now (the driver)

ADR-0014 deferred APIM + Front Door until a revisit trigger fired. The trigger
here is **interview demonstrability**: Eyal wants to have hand-built — and be
able to articulate end-to-end — the gateway tier (Front Door → APIM → private
backend, WAF, gateway policy, FD-only lockdown). The driver is *learning and
articulation*, **not** uptime, **not** a production requirement.

Consequence of that driver: **correctness of the pattern matters more than the
tier being continuously reachable.** This justifies an on-demand, default-off
lifecycle.

### Honesty boundary (CLAUDE.md §1)

This lab does not grant production ESLZ experience. The interview framing
remains: *"I built this gateway tier in a personal lab to develop the
architectural fluency I didn't get in production."*

## 2. Topology

```
internet
   │
   ▼
Front Door Standard  ──(+ WAF Prevention, custom rules only — DRS needs Premium)
   │   origin = APIM gateway public hostname (*.azure-api.net)
   ▼
APIM Developer  (External VNet mode, public VIP, injected into snet-apim-001)
   │   inbound policy: check-header (X-Azure-FDID) + rate-limit-by-key
   │   single wildcard API → ACA internal backend URL
   ▼  (VNet-internal hop, same spoke VNet)
ACA environment  (INTERNAL ingress / internal load balancer, private IP in
   │              snet-aca-001)
   ▼
Container App (ReelHouse API)
```

Key facts that shape this (verified against Microsoft Learn 2026-06):

- **FD Standard cannot use a private origin.** Private Link origins are a Front
  Door **Premium** feature. So APIM's gateway must be publicly reachable →
  APIM **External** VNet mode (public VIP).
- **"External" vs "Internal" VNet mode** describes only which way APIM's *gateway
  endpoint* faces. In **both** modes APIM is VNet-injected and can reach private
  backends. So the ACA backend hop is private regardless; only APIM's ingress is
  public.
- **The ACA env is already VNet-injected** (`infrastructure_subnet_id` set,
  `snet-aca-001` delegated to `Microsoft.App/environments`). Today it runs
  `internal_load_balancer_enabled = false` (external). We flip it to `true`.

## 3. Lifecycle: on-demand, default-off

Follows the established pattern of ADR-0010 (firewall) and ADR-0017 (workload
data plane).

- **`var.gateway_enabled` (default `false`)** gates Front Door + APIM via
  `count = var.gateway_enabled ? 1 : 0`.
- The toggle governs **only Front Door + APIM**. It does **not** flip ACA
  ingress (see §4 — that would recreate the env on every toggle).
- **Idle state (gateway off, the default):** ReelHouse is **not reachable from
  the internet at all.** ACA is internal; with no FD/APIM there is no public
  path. ACA still runs (scale-to-zero, ~€0 idle).
- This is a **deliberate reversal** of ADR-0014's "workload should always be
  reachable, the gateway is the optional layer" principle. Under the
  demonstrability driver, idle = zero public surface is acceptable and arguably
  a *better* security posture than today's always-public ACA. ADR-0019 states
  this reversal explicitly.

## 4. ACA goes permanently internal (one-time recreation)

`internal_load_balancer_enabled` is a **ForceNew** field on
`azurerm_container_app_environment`. Flipping it from `false` to `true`
**destroys and recreates** the environment (and the Container App with it).

Decisions:

- ACA env becomes **permanently internal**. The flip happens **once**; the env
  then stays internal. The `gateway_enabled` toggle never touches it.
- **CI ripple:** after the env is recreated, the Container App has no image (the
  `template[0].container[0].image` field is `ignore_changes`-owned by CI per
  ADR-0015). The `reelhouse-build-deploy` workflow must be re-run after the
  gateway apply to repopulate the image. This ordering is documented in ADR-0019
  and the layer README.
- New FQDN: the internal env exposes a private static IP + a default domain of
  the form `<name>.<region>.azurecontainerapps.io`, resolvable only inside the
  VNet via a private DNS zone (see §5).

## 5. ACA internal DNS

An internal ACA environment is reachable only via a private DNS zone for its
default domain. Build items:

- Read `default_domain` and `static_ip_address` from the recreated env.
- Create a private DNS zone named for the env default domain.
- Wildcard `A` record (`*`) → the env static IP.
- Link the zone to the spoke VNet (APIM, in the same VNet, then resolves the
  ACA backend FQDN to its internal IP).

This is a **per-environment private zone**, distinct from the central
`privatelink.*` zones in the hub (those are for private endpoints; the ACA
internal env uses internal-LB ingress, not a PE).

## 6. Locking APIM to *your* Front Door only

External-VNet APIM has a public VIP, so the private backend does not protect
APIM's own ingress. **Two layers** (defense in depth):

1. **NSG on `snet-apim-001` — inbound 443 only from `AzureFrontDoor.Backend`
   service tag.** External-VNet APIM *requires* an NSG regardless (its internal
   LB is secure-by-default and rejects all inbound until explicitly allowed), so
   this is a mandatory control pointed at Front Door. The NSG also carries the
   mandatory APIM management rules (e.g. `ApiManagement` service tag inbound on
   3443 for the control plane, plus required load-balancer / storage / sql
   outbound rules) or APIM will not provision.

2. **APIM inbound `check-header` policy: require `X-Azure-FDID` == this Front
   Door's ID.** Closes the gap the NSG cannot: `AzureFrontDoor.Backend` is a
   **shared** service tag covering *every* Azure tenant's Front Door. The NSG
   alone means "any Azure Front Door can reach me." The header check pins it to
   *this* FD instance (FD stamps `X-Azure-FDID`; APIM rejects missing/mismatched
   values). The FD ID is **not a secret** (it's an instance GUID), but it is an
   Azure resource identifier — handle per CLAUDE.md §6 (do not commit GUIDs).
   Source via `TF_VAR` / outputs, not hardcoded.

Microsoft's own "Front Door in front of APIM" guidance recommends exactly this
NSG + header-check combination.

**Interview soundbite:** *"A service-tag NSG isn't sufficient alone because
`AzureFrontDoor.Backend` is shared across all tenants — anyone's Front Door
satisfies it. You pin it to your own instance with the `X-Azure-FDID` header
check. NSG is the network layer; the header check is the identity layer."*

### Rejected third layer: `ip-filter` policy

An APIM inbound `ip-filter` policy mirroring the NSG was **considered and
rejected**. `ip-filter` takes **explicit IP ranges, not service tags**, so it
requires owning a static list of Front Door backend ranges that **drifts**
whenever Azure changes its edge fleet — a manual refresh obligation that, if
missed, silently 403s legitimate Front Door traffic. The NSG (auto-tracks the
service tag) + header check already deliver the security goal without that
maintenance hazard. Recorded as a rejected alternative in ADR-0019.

## 7. WAF + demonstrable gateway policy

- **WAF:** Prevention mode (not Detection), with **custom rules only** —
  Front Door **Standard does not support managed rule sets (DRS); those require
  Premium**. A custom rule blocks common SQL-injection patterns in the query
  string, enough to demonstrate WAF blocking (SQLi probe → 403). DRS is a
  documented Premium tradeoff (see ADR-0019 alternatives). Prevention because
  the story is "it blocks," and a lab false-positive is a debugging opportunity.
- **APIM gateway policy beyond lockdown:** one `rate-limit-by-key` inbound
  policy — the canonical "the gateway does real work" artifact. Full OAuth/JWT
  validation is a documented future extension, not v1.

## 8. APIM API definition

A single **wildcard pass-through API** proxying all paths to the ACA internal
backend URL. ReelHouse's Flask app has a handful of routes; a catch-all avoids
per-route APIM maintenance.

## 9. Build inventory

All in `workloads/reelhouse/dev/`, all gated on `var.gateway_enabled` except the
ACA flip and the ACA DNS (which are permanent):

| Item | File |
|---|---|
| `internal_load_balancer_enabled = true` (ACA env recreate, permanent) | `aca.tf` |
| ACA internal default-domain private DNS zone + wildcard A + spoke link (permanent) | new `aca-dns.tf` |
| NSG on `snet-apim-001` (FD service tag + mandatory APIM mgmt rules) | `network.tf` |
| APIM Developer, External VNet, in `snet-apim-001` | new `apim.tf` |
| APIM wildcard API → ACA internal; inbound policy (check-header + rate-limit) | `apim.tf` |
| Front Door Standard profile + endpoint + origin(APIM) + route + WAF policy | new `frontdoor.tf` |
| `gateway_enabled` var; `fd_frontdoor_id` plumbing; FD endpoint hostname output | `variables.tf`, `outputs.tf` |
| Revise stale comment in `network.tf` ("APIM internal mode" → External VNet) | `network.tf` |
| ADR-0019 (supersedes ADR-0014 in part) | `docs/decisions/` |

## 10. Cost

- **Gateway up (`gateway_enabled = true`):** ~€40/mo APIM Developer + ~€30/mo FD
  Standard base ≈ **€70/mo while up.**
- **Gateway off (default):** **€0 added.**
- **ACA internal env:** same as today (~€0 idle, scale-to-zero).
- **Provisioning:** APIM Developer takes ~45 min on every toggle-on. Budget for
  it.

## 11. Out of scope (v1)

- Custom domain + cert management (default `*.azurefd.net` / `*.azure-api.net`).
- OAuth / JWT validation at APIM.
- `prod` env (dev only for now).
- ACA private endpoint (we use internal-LB ingress; APIM shares the VNet, so a
  PE adds nothing).
- `ip-filter` APIM policy (rejected, §6).

## 12. Secrets / public-repo hygiene (CLAUDE.md §6)

- Front Door ID (`X-Azure-FDID` value) is a resource GUID — not committed.
  Sourced via output / `TF_VAR`.
- No subscription GUIDs, tenant IDs, or IPs in any committed file.
- `terraform.tfvars.example` updated with `gateway_enabled` placeholder only.

## 13. Verification (what "works" means — CLAUDE.md, memory: verify actual outcome)

Not "terraform apply succeeded." The gateway tier works when:

1. `gateway_enabled = true` apply completes; CI redeploys the image.
2. `curl https://<fd-endpoint>.azurefd.net/<route>` returns the ReelHouse app
   response (FD → APIM → ACA end-to-end).
3. `curl https://<apim-name>.azure-api.net/<route>` **directly** (bypassing FD)
   is **rejected** (NSG drops non-FD source; or header check 403s) — proving the
   lockdown.
4. A WAF-triggering request (e.g. an obvious SQLi probe) is **blocked** by Front
   Door — proving Prevention mode.
5. `gateway_enabled = false` apply removes FD + APIM; ReelHouse is no longer
   publicly reachable; ACA env survives.
