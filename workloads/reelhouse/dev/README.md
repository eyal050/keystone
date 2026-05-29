# `workloads/reelhouse/dev`

The ReelHouse dev environment. Lives in the **`lab-foundation`**
adopted subscription per [ADR-0012](../../../docs/decisions/0012-adopt-lab-foundation-as-workload-sub.md),
under the `keystone-landing-zones-corp` MG.

Network ownership follows [ADR-0013](../../../docs/decisions/0013-workload-owns-spoke-network.md):
this layer owns the spoke VNet, both peerings, and the spoke-side
Private DNS zone links — via two aliased `azurerm` providers (one
per subscription).

## Current state — full v1 workload

| Sub-chunk | Status | Contents | Cost when applied |
|---|---|---|---|
| **N1** | ✅ applied 2026-05-28 | RG, spoke VNet, 3 subnets, bidirectional peering, 8 spoke-side DNS zone links | €0 |
| **D1** | ✅ written 2026-05-29 | Postgres Flexible B1ms (single AZ) + reelhouse database + private endpoint | ~€12/mo |
| **K1** | ✅ written 2026-05-29 | Key Vault (RBAC mode) + 3 seeded secrets + private endpoint | <€1/mo |
| **S1** | ✅ written 2026-05-29 | Blob storage SA + videos container + private endpoint | usage-based (pennies for lab) |
| **C1** | ✅ written 2026-05-29 | ACA env (Consumption) + Container App with MI + RBAC to KV + Blob | scale-to-zero idle, pennies when running |
| **W1** | ✅ written 2026-05-29 | Static HTML frontend (login + upload + share + player) embedded in the Container App's Flask templates | (part of C1) |
| ~~A1~~ | **Deferred** | APIM Developer + PE | Skipped per [ADR-0014](../../../docs/decisions/0014-defer-apim-and-front-door.md) — ACA external ingress serves as the public entry point. |
| ~~F1~~ | **Deferred** | Front Door Standard | Skipped per [ADR-0014](../../../docs/decisions/0014-defer-apim-and-front-door.md). |

## What's where

| File | Contents |
|---|---|
| `network.tf` | Spoke VNet + subnets + peerings + DNS links (N1) |
| `workload.tf` | Shared workload RG (data + compute plane) |
| `postgres.tf` | Postgres Flexible Server + DB + PE (D1) |
| `keyvault.tf` | Key Vault + operator RBAC + 3 seeded secrets + PE (K1) |
| `storage.tf` | Blob SA + videos container + PE (S1) |
| `aca.tf` | ACA env + Container App + MI + RBAC to KV/Blob (C1) |
| `data.tf` | Cross-layer remote-state reads (connectivity + management) |
| `providers.tf` | Two aliased providers (workload + connectivity) |
| `outputs.tf` | Spoke + workload outputs for future consumers |

## Cost shape

Continuous (always-on):
- Postgres B1ms: **~€12/mo** (1 vCPU burstable, 32 GB storage)
- Key Vault: pennies/month
- Blob storage: pennies/month at lab data volumes
- Container Apps env (Consumption): **€0 idle** (scale-to-zero), pennies when serving requests

**Total idle cost contribution from this workload: ~€13/mo.** Postgres
is the only resource that bills continuously regardless of traffic.

## N1: what gets created

### In the workload sub (`lab-foundation`)

- **`rg-reelhouse-dev-net-weu-001`** — RG for spoke network resources.
- **`vnet-reelhouse-dev-weu-001`** — spoke VNet, address space `10.20.0.0/20`.
- **Subnets:**
  - `snet-aca-001` (`10.20.0.0/23`) — Container Apps env subnet.
    Delegation to `Microsoft.App/environments` added when ACA lands.
  - `snet-pe-001` (`10.20.2.0/26`) — Private Endpoints subnet.
  - `snet-apim-001` (`10.20.3.0/28`) — APIM internal-mode subnet.
- **`peer-to-hub`** — spoke-side peering to the hub VNet.

### In the connectivity sub (`keystone-platform-connectivity`, via aliased provider)

- **`peer-to-reelhouse-dev`** — hub-side peering to this spoke. Lives
  on the hub VNet in the hub RG.
- **8 spoke DNS zone links** — one per central Private DNS zone, all
  named `link-vnet-reelhouse-dev-weu-001`. These live in the hub RG
  next to the existing hub VNet links.

### Subnet layout rationale

```
10.20.0.0/20  (vnet-reelhouse-dev)
├── 10.20.0.0/23      snet-aca-001    (Container Apps env)
├── 10.20.2.0/26      snet-pe-001     (Private Endpoints)
├── 10.20.3.0/28      snet-apim-001   (APIM internal mode)
└── 10.20.4.0/22+     reserved
```

- ACA consumption-only minimum is **/23**. The whole /23 is allocated
  even though early IPs are <30. Resizing an ACA subnet after the env
  exists is painful — give it room up front.
- PE subnets don't need much — every private endpoint consumes ~1
  IP. /26 (64 IPs) covers all the workload PEs (Key Vault + Postgres
  + Blob + APIM internal) with headroom.
- APIM Developer requires a dedicated subnet of **/28 minimum** for
  internal mode. /28 is exactly enough; no growth headroom needed
  since APIM scales within the subnet, not across it.

## Cost when N1 applies

- VNet, subnets, peerings, DNS zone links: **all free**.
- N1's realised cost is **€0**. The spoke is plumbing — it costs
  nothing until something with a meter lands inside it.

## Why this layer uses two providers

Per ADR-0013 the workload-team-owned layer creates resources in
**two subscriptions**:

1. **Workload sub (default provider)**: spoke VNet, subnets,
   spoke-side peering.
2. **Connectivity sub (`azurerm.connectivity` alias)**: hub-side
   peering, spoke DNS zone links.

The reason both sides of the peering live in the workload layer
(rather than splitting peering by which-sub-it's-in) is that
peerings have a strong sequencing constraint — Azure rejects a
peering whose remote VNet hasn't been registered, and a split
across two state files would require interleaved applies. With both
in one state file, Terraform sequences them correctly.

Convention: **every resource that lands in the connectivity sub
MUST set `provider = azurerm.connectivity` explicitly.** Forgetting
the alias lands the resource in the workload sub by mistake.

## Operator workflow

```bash
# Plan / apply via the path-mode helper
./scripts/_tf-cmd.sh workloads/reelhouse/dev plan
./scripts/_tf-cmd.sh workloads/reelhouse/dev apply -auto-approve
```

The Makefile pattern targets don't yet cover workload paths because
slashes don't play well with Make target names. Add explicit
targets (e.g. `make workload-plan-reelhouse-dev`) if the workflow
becomes painful.

## Why no NSGs yet

Subnets work without NSGs; Azure's default rules permit VNet-internal
traffic and deny inbound-from-internet. NSGs land when their
consumers do, attached to the specific subnet (ACA NSG with
ACA-specific rules, APIM NSG with APIM-specific allow rules, etc.).

## What's pending

See the chunk table above — C1, D1, K1, S1, A1, F1, W1. Order is
flexible but a sensible sequence is: D1 (Postgres + PE) → K1 (KV +
PE) → S1 (Blob + PE) → C1 (ACA + Container App that consumes
Postgres/KV/Blob) → A1 (APIM in front of ACA) → F1 (Front Door in
front of APIM) → W1 (static frontend behind Front Door).
