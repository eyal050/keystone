# Keystone — Architecture (as built)

*Snapshot date: 2026-05-28.* Reflects what exists in the lab right now,
not what's planned. For decisions and trade-offs, see
[`docs/decisions/`](decisions/). For workflow / operator instructions,
see [the root README](../README.md) and the per-layer READMEs under
`platform/`.

---

## 1. What Keystone is

A personal Azure lab for **building hands-on fluency with CAF
Enterprise-Scale Landing Zones (ESLZ) in Terraform**. The platform
side is the load-bearing learning artifact; ReelHouse (a minimal
video-sharing web app) sits on top as the workload tenant of the
landing zone. ReelHouse exists to justify Keystone, not the other
way around.

**This lab does not retroactively grant the production ESLZ
experience Eyal does not have.** Any narrative drawn from it must
frame as *"built a personal ESLZ lab to develop fluency I didn't get
to build in production."* See [CLAUDE.md §1](../CLAUDE.md) for the
honesty boundary.

## 2. Where we are right now

| Layer | State |
|---|---|
| `00-bootstrap` | ✅ State SA + RG in keystone-platform-management |
| `05-subscriptions` | ⚠️ 2 of 5 planned subs vended (`platform-management`, `platform-connectivity`); the rest are blocked at MCA quota |
| `10-management-groups` | ✅ Full MG hierarchy + 4 policy assignments + 1 custom policy definition + 1 exemption |
| `20-management` | ✅ Log Analytics workspace, DfN diagnostic-settings policy + MI roles, per-sub cost exports + budgets, overview workbook + portal dashboard |
| `30-connectivity` | ✅ E1 hub VNet + subnets + NSG, E2 on-demand firewall + policy, E3 platform + workload Private DNS zones. **E4 (spoke peering) pending workload.** |
| `40-identity` | ✅ One custom role definition (Spoke Network Operator), MG-scoped; operates from Management per ADR-0011 |
| `workloads/reelhouse` | ❌ Not started. `lab-foundation` adopted 2026-05-28 as the workload host (per ADR-0012); workload code itself still to come. |

**Idle cost when nothing is actively running**: ~€4/mo (8 Private DNS zones × €0.50/mo).
**Cost when firewall is up**: +~€115/mo prorated by hours.

---

## 3. Management Group hierarchy

```
Tenant Root
└── keystone                               (top-level MG; CAF "intermediate root")
    ├── keystone-platform
    │   ├── keystone-platform-connectivity      → keystone-platform-connectivity (sub)
    │   ├── keystone-platform-management        → keystone-platform-management (sub)
    │   └── keystone-platform-identity          → (empty; identity collapsed into Management per ADR-0011)
    ├── keystone-landing-zones
    │   └── keystone-landing-zones-corp         → lab-foundation (sub, adopted per ADR-0012)
    ├── keystone-decommissioned                 (empty; reserved for retired subs pre-cancellation)
    └── keystone-sandbox                        (empty; exempted from Environment-tag policy)
```

Built hand-rolled in `platform/10-management-groups/`, not via the
`Azure/caf-enterprise-scale` module — see [ADR-0004](decisions/0004-mg-policy-hand-rolled-then-evaluate-module.md).
Re-evaluate the module decision when policy assignment volume grows.

All MGs carry the `keystone-` prefix except the top-level MG itself
(just `keystone`). The namespacing matters: in a real tenant, MGs
from many programs coexist at the top level, and a generic name
like `platform` collides.

---

## 4. Subscriptions

### Vended & live

| Subscription | MG placement | Role | Vended |
|---|---|---|---|
| `keystone-platform-management` | `keystone-platform-management` | LAW, diag settings, cost exports, TF state SA | 2026-05-21 |
| `keystone-platform-connectivity` | `keystone-platform-connectivity` | Hub VNet, firewall, central DNS | 2026-05-24 |

### Blocked at MCA quota (2026-05-25)

| Subscription | Status |
|---|---|
| `keystone-platform-identity` | Wall hit on `make vend-sub`. Per [ADR-0011](decisions/0011-identity-collapsed-into-management.md), 40-identity operates from Management. MG `keystone-platform-identity` remains for future adoption. |
| `keystone-reelhouse-dev` | Replaced by adoption (see below). |
| `keystone-reelhouse-prod` | Deferred until a real prod sub becomes available. |

### Adopted (2026-05-28, brownfield)

| Subscription | MG placement | Role | Status |
|---|---|---|---|
| `lab-foundation` *(pre-existing in MCA)* | `keystone-landing-zones-corp` | Workload host for ReelHouse dev | **Adopted 2026-05-28 per [ADR-0012](decisions/0012-adopt-lab-foundation-as-workload-sub.md).** MG association applied via `10-management-groups` (`adopted` resource). Budget (€50/mo) + MTD cost export applied via `20-management` (merged for_each over vended + adopted). |

Quota raise ticket open with Microsoft; ETA "slow." See [`subscription-topology.md`](subscription-topology.md) for full history.

---

## 5. Network topology

### Hub VNet (keystone-platform-connectivity)

```
vnet-hub-conn-weu-001        10.10.0.0/16
├── AzureFirewallSubnet              10.10.0.0/26   (Azure-mandated name)
├── AzureFirewallManagementSubnet    10.10.0.64/26  (required by Firewall Basic)
├── GatewaySubnet                    10.10.1.0/27   (reserved; no VPN/ER yet)
└── snet-default-001                 10.10.2.0/24   (NSG-attached; break/debug subnet)
```

The /16 has ~60k IPs free for future subnets (bastion, additional
hub-side testing). Address layout deliberately keeps the firewall +
gateway slots in the first /18 so the workload-style /24s can grow
contiguously.

### Azure Firewall — on-demand, default off

Per [ADR-0010](decisions/0010-firewall-on-demand-not-scheduled.md)
(supersedes [ADR-0005](decisions/0005-firewall-basic-with-deallocation.md)
in part):

- **Firewall policy** `afwp-hub-conn-weu-001` — Basic tier, always
  in state, free, survives up/down cycles so rules persist.
- **Firewall** `afw-hub-conn-weu-001` — Basic tier (`AZFW_VNet`),
  conditional on `var.firewall_enabled`, default `false`.
- **Public IPs** — Standard Static, both conditional, allocated only
  when the firewall is up. **New PIPs each up cycle ⇒ egress IP
  changes per session** (the one real ergonomic cost of on-demand).
- `make firewall-up` / `make firewall-down` toggle the variable.

Verified end-to-end 2026-05-25: 3 resources added in ~13 min on up,
removed cleanly on down.

### Central Private DNS Zones

8 zones, all in the hub RG, all linked to the hub VNet via a single
`merge()` over both sets (see `platform/30-connectivity/dns-zones.tf`).
Spokes get their own links when they land.

| Set | Zone | Used by |
|---|---|---|
| platform | `privatelink.blob.core.windows.net` | TF state SA, cost-export storage, workload blob SAs |
| platform | `privatelink.monitor.azure.com` | App Insights / AMPLS |
| platform | `privatelink.ods.opinsights.azure.com` | Log Analytics ingestion (AMA) |
| platform | `privatelink.oms.opinsights.azure.com` | Log Analytics legacy (MMA) |
| workload | `privatelink.vaultcore.azure.net` | Key Vault |
| workload | `privatelink.postgres.database.azure.com` | PostgreSQL Flexible Server |
| workload | `privatelink.westeurope.azurecontainerapps.io` | Container Apps env — **region-scoped** |
| workload | `privatelink.azure-api.net` | API Management |

Cost: 8 × €0.50/mo flat = €4/mo. Query cost free at lab volumes
(<1M/zone/mo). Centralised in the hub per CLAUDE.md §2 to prevent
the per-spoke DNS-shadowing attack vector that the
[Spoke Network Operator role](../platform/40-identity/README.md)
also defends against.

---

## 6. Identity & RBAC

### Custom role definitions

Defined at MG scope in `platform/40-identity/` (operating from
Management per ADR-0011):

| Role | Assignable scope | Status |
|---|---|---|
| **Keystone Spoke Network Operator** | `keystone-landing-zones` | ✅ defined, ❌ unassigned (no workload identities yet) |

**Spoke Network Operator** is the canonical "delegate without
escalation" hub-spoke pattern: full ops inside the spoke (VNets,
NSGs, NICs, endpoints, route tables) but **NotActions** block
peering writes and Private DNS zone-link writes. Both prevent the
spoke operator from rewriting the connectivity fabric the hub team
is supposed to own — peering rewrite = route past firewall, DNS link
rewrite = shadow names to attacker IPs. See `platform/40-identity/README.md` and
the role's `permissions` block for details.

### Managed Identities

None platform-scoped yet. The DfN-policy-spawned MI in
`platform/20-management` lives where it's used (Management sub). Workload
MIs land alongside the workload code in `workloads/reelhouse/` once
that exists.

---

## 7. Policy posture

### Assignments

| Name | Effect | Scope | Source |
|---|---|---|---|
| `env-tag-enum` | Deny | `keystone` MG | Custom `required_tag_enum` definition (`policy-definitions.tf`) — only allows `Environment` ∈ {platform, dev, prod, sandbox} |
| `allowed-locations-weu` | Deny | `keystone` MG | Built-in. Enforces ADR-0002 (westeurope only). Indexed-mode — global resources not evaluated. |
| `secure-transfer-audit` | Deny | `keystone` MG | Built-in. HTTPS required on storage accounts. Originally Audit, promoted to Deny 2026-05-22 after zero historical violators. |
| `deny-storage-public` | Deny | `keystone-landing-zones-corp` MG | Built-in. Public-network-access denied on workload SAs. Platform SAs excluded — TF state SA is currently still public-network-accessible (TODO in 00-bootstrap). |
| `diag-storage-to-law` | DeployIfNotExists | `keystone` MG | Built-in initiative. Storage account diagnostic settings to platform LAW. Lives in `20-management` because the LAW does. |

### Exemptions

| Name | Exempts | Scope | Why |
|---|---|---|---|
| `sandbox-env-tag-waiver` | `env-tag-enum` | `keystone-sandbox` MG | Sandbox is the lab's experimentation archetype; strict Environment-tag enforcement would block ad-hoc deploys. |

### Custom policy definitions

Defined in `platform/10-management-groups/policy-definitions.tf`:

- **`required_tag_enum`** — generalised "tag value must be in this
  allowed enum" definition. Currently used by the
  `env-tag-enum` assignment to enforce ADR-0008's
  Environment tag taxonomy.

---

## 8. Centralized logging & cost

### Logging

- **Log Analytics workspace** `log-platmgmt-weu-001` in
  `rg-platmgmt-weu-001`, sub `keystone-platform-management`.
- **DfN policy** `diag-storage-to-law` ensures every new storage
  account at or below `keystone` MG forwards diagnostic settings to
  the workspace. Assigned in `platform/20-management/` (see
  [break-debug-log § DfN MI role assignments](break-debug-log.md)
  for the silent-non-compliance failure mode this guards against).

### Cost

- **Per-sub MCA cost exports** — daily, MonthToDate, ActualCost
  scope, into the `cost-exports` container of the state SA, root
  folder per sub alias. for_each over the subscriptions remote-state
  map; new sub vends auto-pick-up via `make vend-sub` chaining.
  Start-date computed from `timeadd(timestamp(), "24h")` to avoid
  the [time-rot failure mode logged 2026-05-25](break-debug-log.md).
- **Per-sub monthly budgets** — €100/mo platform-management, €100/mo
  platform-connectivity (firewall-dominated when running, near-zero
  otherwise). Alerts at 10/20/50/80/100%. Defined in
  `platform/20-management/budgets.tf`.
- **Overview workbook + dashboard** — Azure Monitor workbook in
  Management + a Portal Dashboard pointing at it. Gives MTD cost
  rollup per sub at a glance. JSON in
  `platform/20-management/workbooks/keystone-overview.json`.
- **`make cost`** — MTD snapshot per sub via
  `scripts/cost-snapshot.sh`. Faster than the workbook for one-off
  checks.

---

## 9. Terraform structure & state

### Layer map

```
platform/
├── 00-bootstrap/            State SA, state RG, lifecycle protections
├── 05-subscriptions/        MCA subscription vending (phase-gated, -target for partial)
├── 10-management-groups/    MG hierarchy + custom policy def + 4 assignments + 1 exemption
├── 20-management/           LAW, diag DfN policy, MI roles, cost exports, budgets, workbook
├── 30-connectivity/         Hub VNet, NSG, firewall (on-demand) + policy + PIPs (conditional), 8 DNS zones
└── 40-identity/             Custom RBAC role definitions (MG-scoped)
```

Numeric prefix dictates apply order. Each layer has its own state file in
the same Azure Storage container (`tfstate`) under
`platform-<layer>.tfstate`. Cross-layer references via
`terraform_remote_state` data sources; no shared modules yet.

### State backend

- **Storage Account**: `sttfstateplatweu<suffix>`, RG
  `rg-tfstate-plat-weu-001`, sub `keystone-platform-management`.
- **Container**: `tfstate`.
- **Bootstrap chicken-and-egg**: `00-bootstrap` was applied with a
  local backend first, then `terraform init -migrate-state` moved the
  state into the SA it itself had created. Subsequent layers
  initialise directly against the remote backend via
  `scripts/_tf-cmd.sh`.

### Operator workflows

The Makefile encodes the common workflows:

```bash
make plan-<layer>            # plan a layer (e.g. plan-30-connectivity)
make apply-<layer>           # apply a layer
make vend-sub ALIAS=<alias>  # vend a Phase-2 sub + chain reconciliation across 05 → 10 → 20
make firewall-up             # apply 30-connectivity with -var=firewall_enabled=true
make firewall-down           # apply 30-connectivity with -var=firewall_enabled=false
make cost                    # MTD cost snapshot across MCA billing profile
make destroy-platform        # destroy 40 → 30 → 20 → 10 in reverse order — NEVER touches 05 or 00
```

`make destroy-platform` deliberately excludes the subscription and
bootstrap layers per [CLAUDE.md §7](../CLAUDE.md) — cancelling MCA subs
burns 90 days of quota.

The `vend-sub` chain (`05 → 10 → 20`) was extended from a single
apply to a three-layer chain after the
[generalised cross-layer-vend lesson](break-debug-log.md): every
layer that `for_each`-es over upstream remote state needs re-apply
when the upstream changes. 40-identity is *not* in the chain because
its current resources don't iterate over subs.

---

## 10. Cost shape

| State | Cost/mo | What runs |
|---|---|---|
| **Idle** (firewall down, default) | ~€4 | 8 Private DNS zones × €0.50 |
| **+ Firewall up** | ~€115 | + Firewall Basic prorated (~€275/mo always-on) + 2× Standard Static PIPs (~€3.20/mo each) |
| **+ Workload** (eventual) | + ~€30-60 estimated | + Postgres B1ms (~€12), Container Apps consumption, Key Vault standard, APIM Developer (~€40/mo if always-on), Front Door Standard base (~€30) |

Lab is operated in the **idle** state most of the time. Firewall
gets brought up only when actively learning hub-spoke routing /
testing rules. Workload (when it lands) will follow the same
"on-demand or scheduled" cost discipline.

---

## 11. What's pending

| Item | Blocker |
|---|---|
| `workloads/reelhouse/` | Awaiting workload sub. Workaround chosen 2026-05-28: adopt `lab-foundation` MCA sub into `keystone-landing-zones-corp`. ADR forthcoming. |
| `30-connectivity` E4 (spoke peering, UDR forcing through firewall) | Workload spoke VNet must exist first. |
| Workload MI definitions | In `workloads/reelhouse/` when it lands; not in 40-identity. |
| GitHub Actions workflows | Per CLAUDE.md §5 — OIDC federation to Azure, per-env approvals. Local applies work today; CI is the next step once a layer churns. |
| Going-public audit | Per CLAUDE.md §6 — gitleaks full-history scan + secrets inventory verification before flipping repo to public. |

---

## 12. ADRs

See [`docs/decisions/`](decisions/) for the full set. Index:
[`decisions/README.md`](decisions/README.md).

Decisions most worth re-reading before extending the lab:

- [ADR-0010](decisions/0010-firewall-on-demand-not-scheduled.md) — firewall lifecycle model (interview question: scheduled vs. on-demand cost management)
- [ADR-0011](decisions/0011-identity-collapsed-into-management.md) — what happens when MCA quota walls a planned topology
- [ADR-0001](decisions/0001-directory-per-env.md) — directory-per-env vs. branch-per-env, with the GuardianLink counter-example
- [ADR-0008](decisions/0008-tag-taxonomy.md) — enforced tag enum, the basis for the `env-tag-enum` policy

---

## 13. Other docs

- [`subscription-topology.md`](subscription-topology.md) — sub history and MG placement detail.
- [`break-debug-log.md`](break-debug-log.md) — every break/debug practiced or surfaced, with hypothesis path + root cause + signal-to-look-at.
- [`secrets-inventory.md`](secrets-inventory.md) — every sensitive value the lab uses, where it lives, how to obtain a fresh copy.
- [Per-layer READMEs under `platform/`](../platform/) — detailed layer-by-layer "what's in here and why."
