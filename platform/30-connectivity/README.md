# `platform/30-connectivity`

Hub-spoke connectivity for Keystone. Lives in
`keystone-platform-connectivity`. Per [ADR-0005](../../docs/decisions/0005-firewall-basic-with-deallocation.md)
the firewall is Azure Firewall Basic with a scheduled deallocation;
per CLAUDE.md §2, Private DNS zones are centrally managed here.

## Apply is blocked

`keystone-platform-connectivity` is vended in Phase 2 of
`platform/05-subscriptions`, which is blocked on the MCA quota
increase ticket. Until the sub exists, this layer is in the repo for
**review only** — `terraform plan` will fail at the
`data.azurerm_subscription.conn` lookup with "subscription not found".

## Layer is built in sub-chunks

| Sub-chunk | Status | Contents | Cost when applied |
|---|---|---|---|
| **E1** | ✅ written, ❌ not applied | Hub RG, hub VNet, reserved subnets (firewall + management + gateway + default), default NSG, 4 platform-side Private DNS zones | ~€2/mo (4 × €0.50 DNS zones) |
| E2 | pending | Azure Firewall Basic + scheduled deallocation Action | ~€100/mo realised (€275/mo always-on, deallocated nights & weekends) |
| E3 | pending | Workload-side Private DNS zones (Key Vault, Postgres, Container Apps, APIM) | ~€2/mo (4 more zones) |
| E4 | pending | Spoke VNet peering once workload VNets land | free (peering itself is free; data transfer between peered VNets is metered) |

## E1: what gets created

- **Resource group** `rg-hub-conn-weu-001`.
- **Hub VNet** `vnet-hub-conn-weu-001` with address space `10.10.0.0/16`.
- **Subnets:**
  - `AzureFirewallSubnet` (10.10.0.0/26) — reserved for the firewall data plane. Azure-mandated name.
  - `AzureFirewallManagementSubnet` (10.10.0.64/26) — required by Firewall Basic for control-plane traffic. Azure-mandated name.
  - `GatewaySubnet` (10.10.1.0/27) — reserved for future VPN/ExpressRoute. Azure-mandated name.
  - `snet-default-001` (10.10.2.0/24) — placeholder workload-style subnet; NSG attaches here.
- **NSG** `nsg-default-hub-weu-001`, associated with `snet-default-001`. Azure's implicit default rules are sufficient for now (deny inbound from internet, allow VNet inbound, allow outbound).
- **4 Private DNS zones** linked to the hub VNet:
  - `privatelink.blob.core.windows.net`
  - `privatelink.monitor.azure.com`
  - `privatelink.ods.opinsights.azure.com`
  - `privatelink.oms.opinsights.azure.com`

## Cost when E1 applies

- VNet, subnets, NSG: **free**.
- Private DNS zones: **flat-monthly**, €0.50/zone, no free tier. 4 zones = ~€2/mo.
- DNS queries: first 1M/mo per zone free, then €0.40 per million. Lab volumes are deep in the free tier.

This is the first layer where realised cost exits the noise floor.
Cost rises significantly in E2 when the firewall lands.

## Lifecycle protections

- `prevent_destroy = true` on the RG and hub VNet. Tearing either down would orphan every subnet, NSG, and DNS zone link below.
- DNS zones are deliberately NOT prevent_destroy because the workload-side zone set (E3) may need to be repartitioned. Lock them down once the catalog stabilises.

## Subnet layout rationale

```
10.10.0.0/16  (vnet-hub-conn)
├── 10.10.0.0/18         reserved for firewall + control / gateway
│   ├── 10.10.0.0/26     AzureFirewallSubnet
│   ├── 10.10.0.64/26    AzureFirewallManagementSubnet
│   └── 10.10.1.0/27     GatewaySubnet
└── 10.10.2.0/24         snet-default-001 (workload-style placeholder)
```

`/26` is the Azure-required minimum for AzureFirewallSubnet (and the
management subnet, when using Firewall Basic). `/27` is sufficient
for a single VPN + ER gateway. The hub has ~60k more IPs free for
future use — bastion, additional workload-style placeholders, etc.

## Why DNS zones in the hub rather than in each workload

CLAUDE.md §2 mandates centralised hub-managed DNS. The pattern is:

1. Zone exists once in the hub.
2. Hub VNet links to zone (registration_enabled = false; resolution only).
3. Each spoke VNet adds its own link to the same zone.
4. When a workload creates a private endpoint, its
   `private_dns_zone_group` references the hub zone — Azure auto-adds
   the A record into the central zone.

Result: every spoke resolves the same FQDN to the same private IP,
managed by one team in one place. The alternative — per-workload
DNS zones — duplicates state and creates resolution surprises when
two workloads expect different IPs for the same service name.
