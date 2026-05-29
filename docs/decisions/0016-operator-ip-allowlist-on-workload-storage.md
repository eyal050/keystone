# ADR-0016: Operator IP allowlist on workload storage (policy exemption)

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Supersedes**: —
- **Builds on**: [ADR-0014](0014-defer-apim-and-front-door.md) (the
  reason there's no SAS URL pattern in front of the videos blob)

## Context

The workload's video storage account (`streelhdev*`) has
`public_network_access_enabled = false` per [CLAUDE.md §2's CAF
posture for workload data] and the `deny-storage-public` policy
assignment at the `keystone-landing-zones-corp` MG scope. Reads/writes
from the ReelHouse Container App work because they traverse the
private endpoint in `snet-pe-001`.

On 2026-05-29 the operator (Eyal) hit a real ergonomic problem:

> *"I can't see the content on the videos storage blob"* — Azure
> Portal browse returned HTTP 403 with the storage firewall rejecting
> the operator's public IP (`***REDACTED-IP-SEE-SECRETS-ENV***`).

The problem is structural, not a misconfiguration:

- Portal blob browsing fetches blob metadata from the **public**
  storage endpoint directly from the operator's browser.
- With public network access disabled, that endpoint rejects everything.
- VPN-to-spoke or jumpbox-in-spoke would solve it but is heavy
  scaffolding for ad-hoc inspection.

## Decision

**Allow the operator's current public IP to reach the workload
storage account's public endpoint**, scoped narrowly:

1. **Enable PNA** on `azurerm_storage_account.videos` but set
   `network_rules.default_action = "Deny"` — opens the door only
   for explicitly-allowlisted sources.
2. **Allowlist `var.operator_ip`** (sourced from
   `KEYSTONE_OPERATOR_IP` in `~/.keystone/secrets.env` per CLAUDE.md
   §6 — personal IP is sensitive).
3. **Add `bypass = ["AzureServices"]`** — lets Azure-internal services
   (e.g. some portal-rendered metadata) reach the account without
   needing per-service IP rules.
4. **Add a resource-scoped policy exemption** for the
   `deny-storage-public` assignment on this specific storage account
   (`azurerm_resource_policy_exemption`). Without this, step 1 would
   fail with `RequestDisallowedByPolicy`.

ACA's existing private-endpoint path is unchanged — workload reads/writes
still traverse the spoke VNet via the PE.

## Consequences

**Positive:**

- **Operator can use the portal + `az storage blob list` from their
  laptop** for ad-hoc inspection without standing up a jumpbox or VPN.
- **Workload data path remains private** — ACA reaches the SA via the
  PE, unchanged. Only the operator's specific IP can reach the public
  endpoint.
- **Exercises policy exemptions in the workload layer.** The lab now
  has two exemptions for different reasons: the sandbox-tag waiver
  in `10-management-groups` (broad MG-scope exemption) and this
  resource-scope exemption (narrow). Two valid shapes; useful for
  interview narrative.

**Negative / trade-offs:**

- **Residential IPs change.** When `KEYSTONE_OPERATOR_IP` no longer
  matches the operator's real IP, portal access starts failing again
  with the same 403. Update the secret + `terraform apply` to fix.
  Documented in `secrets.example.env`.
- **The deny-storage-public policy is weaker than it appears at the
  catalog level** — there's an exemption for `streelhdev*`. The policy
  catalog (`docs/policy-catalog.md` when it lands) needs to note this.
- **Operator IP in storage ACL is recoverable from the SA's resource
  state** (anyone with reader on the SA can see the IP). Per CLAUDE.md
  §6 personal IPs are sensitive — this leaks the operator's home IP
  to anyone with read on the workload sub. Acceptable for a lab
  with a single user; document the exposure.

**Interview-defensibility:**

> *"My workload storage is PE-only by default, enforced by the
> deny-storage-public policy at the landing-zones MG. For ad-hoc
> operator inspection, I exempt the specific SA and add a narrow IP
> allowlist for the operator's address. The exemption is resource-
> scoped, not MG-scoped — every other workload SA still inherits the
> deny."*

## Alternatives considered

- **VPN to the spoke VNet + portal access via private IP.** Rejected
  for a personal lab — Azure VPN Gateway runs ~€25/mo and the setup
  takes a session of its own.
- **Jumpbox in the spoke + `az storage` from there.** Rejected:
  bastion + VM = real cost and operational surface.
- **Add `/admin/list` endpoint to the ReelHouse app.** Considered
  and rejected. Would only show what the app's Postgres knows, not
  raw blob contents (file sizes, content types, blob metadata). The
  portal experience is broader.
- **Drop the deny-storage-public policy entirely.** Rejected. The
  policy is correct for workloads in general; this is one operator's
  exception, not a baseline change.

## Future revisit triggers

Revisit when:

- A real prod env (`workloads/reelhouse/prod/`) needs storage
  inspection. Probably *don't* apply the same exemption — prod
  inspection should go through a jumpbox or proper IAM, not an IP
  allowlist.
- Multiple operators need access — IP allowlist breaks; switch to a
  proper VPN or Bastion + private endpoint pattern.
- IP changes get burdensome — consider a small Logic App or Function
  that re-evaluates the operator's current IP via a dyndns record and
  updates the SA ACL automatically.
