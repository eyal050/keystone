# ReelHouse Gateway Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-demand, default-off Front Door + APIM gateway tier in front of ReelHouse's now-internal ACA backend, with two-layer FD-only lockdown and WAF.

**Architecture:** Internet → Front Door Standard (+WAF Prevention) → APIM Developer (External VNet, public VIP, in `snet-apim-001`) → ACA environment flipped to internal ingress (internal LB private IP in `snet-aca-001`). FD + APIM are gated behind `var.gateway_enabled` (default `false`); the ACA-internal flip and its private DNS are permanent. Source spec: `docs/superpowers/specs/2026-06-01-reelhouse-gateway-tier-design.md`.

**Tech Stack:** Terraform, `azurerm` 4.x (`azurerm_container_app_environment`, `azurerm_api_management`, `azurerm_cdn_frontdoor_*`, `azurerm_network_security_group`, `azurerm_private_dns_zone`), Azure (Front Door Standard, APIM Developer, Container Apps).

**Working dir for all `terraform` commands:** `workloads/reelhouse/dev/`. Source `~/.keystone/secrets.env` first.

**Pre-flight checks that gate "done" for code tasks (no apply):**
- `terraform fmt -check`
- `terraform validate`
- `tflint` and `checkov -d .` (or `tfsec`) clean, or `#checkov:skip` / `#tfsec:ignore` with justification (note: `#tfsec:ignore` — no space after `#`, per break-debug log entry).
- `terraform plan` with the stated `-var 'gateway_enabled=...'` shows the expected resource count and nothing unexpected destroyed.

---

## File Structure

| File | Responsibility | New/Modify |
|---|---|---|
| `docs/decisions/0019-build-gateway-tier-fd-apim.md` | ADR superseding ADR-0014 in part | New |
| `workloads/reelhouse/dev/network.tf` | Fix stale APIM comment; add NSG on `snet-apim-001` | Modify |
| `workloads/reelhouse/dev/variables.tf` | `gateway_enabled` variable | Modify |
| `workloads/reelhouse/dev/terraform.tfvars.example` | `gateway_enabled` placeholder | Modify |
| `workloads/reelhouse/dev/aca.tf` | Flip env to internal | Modify |
| `workloads/reelhouse/dev/aca-dns.tf` | ACA internal default-domain private DNS zone + wildcard A + spoke link | New |
| `workloads/reelhouse/dev/frontdoor.tf` | FD profile, endpoint, WAF, origin group, origin (APIM), route | New |
| `workloads/reelhouse/dev/apim.tf` | APIM Developer (External VNet), wildcard API, inbound policy | New |
| `workloads/reelhouse/dev/outputs.tf` | FD endpoint hostname output | Modify |
| `workloads/reelhouse/dev/README.md` | Toggle usage + CI-reorder note + verification runbook | Modify |

**Dependency order inside the layer** (Terraform resolves automatically, but tasks are ordered to match): FD profile/WAF → APIM (references FD `resource_guid` for the header check) → FD origin+route (references APIM gateway hostname). This is acyclic.

---

## Task 1: ADR-0019 + fix stale network comment

**Files:**
- Create: `docs/decisions/0019-build-gateway-tier-fd-apim.md`
- Modify: `workloads/reelhouse/dev/network.tf` (the `snet-apim-001` comment block, lines ~15 and ~78-83)

- [ ] **Step 1: Write the ADR**

Create `docs/decisions/0019-build-gateway-tier-fd-apim.md`. Follow the existing ADR format (see `0014`, `0017`). Required content:
- Status: Accepted; Date: 2026-06-01; Decider: Eyal; **Revises: ADR-0014** (partially supersedes the deferral).
- **Context:** driver is interview demonstrability, not uptime (quote the honesty boundary). ACA already VNet-injected.
- **Decision:** build FD Standard + APIM Developer (External VNet) → ACA internal, on-demand default-off (`gateway_enabled`). Permanent ACA-internal flip.
- **FD-only lockdown:** two layers — NSG `AzureFrontDoor.Backend` service tag + APIM `check-header` on `X-Azure-FDID`. Explain *why both* (shared service tag → header pins to this FD instance).
- **Rejected alternative:** `ip-filter` policy — takes explicit IP ranges not service tags, drifts, manual refresh hazard.
- **Consequences:** ~€70/mo while up, €0 off; ~45min APIM provision; **idle = ReelHouse not publicly reachable** (deliberate reversal of ADR-0014's always-reachable principle); ACA env recreation is destructive once; CI must redeploy image after the flip.
- **Interview soundbite** (from spec §6).

- [ ] **Step 2: Fix the stale `snet-apim-001` comment in network.tf**

In `network.tf`, the subnet-layout comment (line ~15) and the `azurerm_subnet "apim"` block (lines ~78-83) say "API Management internal mode". We use **External** VNet mode. Update both mentions to: `snet-apim-001 (API Management, External VNet mode)`.

- [ ] **Step 3: Validate + commit**

```bash
cd workloads/reelhouse/dev && terraform fmt -check && terraform validate
git add docs/decisions/0019-build-gateway-tier-fd-apim.md workloads/reelhouse/dev/network.tf
git commit -m "docs: ADR-0019 build gateway tier (FD+APIM); fix stale APIM comment"
```
Expected: `validate` succeeds (no resource change yet).

---

## Task 2: `gateway_enabled` variable + tfvars example

**Files:**
- Modify: `workloads/reelhouse/dev/variables.tf`
- Modify: `workloads/reelhouse/dev/terraform.tfvars.example`

- [ ] **Step 1: Add the variable**

In `variables.tf`:

```hcl
variable "gateway_enabled" {
  description = "When true, stand up the on-demand gateway tier (Front Door + APIM) in front of the internal ACA backend. Default false keeps idle cost at €0; when false ReelHouse is not publicly reachable (ACA is internal). See ADR-0019."
  type        = bool
  default     = false
}
```

- [ ] **Step 2: Add to tfvars.example**

In `terraform.tfvars.example`, add (placeholder only, no real values):

```hcl
# Gateway tier (Front Door + APIM). false = idle/€0, not publicly reachable.
# true = ~€70/mo while up, ~45min APIM provision. See ADR-0019.
gateway_enabled = false
```

- [ ] **Step 3: Validate + commit**

```bash
terraform fmt -check && terraform validate
git add workloads/reelhouse/dev/variables.tf workloads/reelhouse/dev/terraform.tfvars.example
git commit -m "feat(reelhouse/dev): gateway_enabled toggle (default off)"
```
Expected: `validate` succeeds.

---

## Task 3: Flip ACA to internal + ACA internal private DNS (PERMANENT, destructive once)

> ⚠️ This task recreates the ACA environment on apply (`internal_load_balancer_enabled` is ForceNew). After applying, the Container App has no image until CI redeploys. Do NOT apply mid-task; the apply is a milestone (Task 9). This task only writes + validates + plans.

**Files:**
- Modify: `workloads/reelhouse/dev/aca.tf`
- Create: `workloads/reelhouse/dev/aca-dns.tf`

- [ ] **Step 1: Flip the env to internal**

In `aca.tf`, change the env resource:

```hcl
  # Internal ingress: the env exposes an internal load balancer with a
  # private IP in snet-aca-001. No public *.azurecontainerapps.io endpoint.
  # Reached only from inside the spoke VNet (APIM). Per ADR-0019.
  # NOTE: ForceNew — flipping this recreates the env (and the Container App).
  internal_load_balancer_enabled = true
```

Update the comment block above the resource (currently says "External ingress endpoint ... reachable from the internet ... per ADR-0014") to reflect ADR-0019 internal ingress.

- [ ] **Step 2: Flip the Container App ingress to internal**

In `aca.tf`, the `ingress` block of `azurerm_container_app.api`:

```hcl
  ingress {
    external_enabled = false # internal-only; reached via APIM in-VNet. ADR-0019.
    target_port      = 8080
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }
```

- [ ] **Step 3: Create the ACA internal private DNS zone**

Create `aca-dns.tf`:

```hcl
# An internal ACA environment is resolvable only via a private DNS zone for
# its default domain. APIM (same spoke VNet) resolves the app FQDN to the
# env's internal static IP through this zone. Per ADR-0019.
#
# This zone is PERMANENT (not gated on gateway_enabled): it belongs to the
# internal env, which is permanent. It is a per-env zone, distinct from the
# central privatelink.* zones in the hub (those are for private endpoints).

resource "azurerm_private_dns_zone" "aca_env" {
  # provider = workload (default)
  name                = azurerm_container_app_environment.this.default_domain
  resource_group_name = azurerm_resource_group.workload.name
  tags                = var.required_tags
}

resource "azurerm_private_dns_a_record" "aca_env_wildcard" {
  name                = "*"
  zone_name           = azurerm_private_dns_zone.aca_env.name
  resource_group_name = azurerm_resource_group.workload.name
  ttl                 = 300
  records             = [azurerm_container_app_environment.this.static_ip_address]
  tags                = var.required_tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "aca_env_spoke" {
  name                  = "link-${azurerm_virtual_network.spoke.name}"
  resource_group_name   = azurerm_resource_group.workload.name
  private_dns_zone_name = azurerm_private_dns_zone.aca_env.name
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.required_tags
}
```

- [ ] **Step 4: Validate + plan + commit**

```bash
terraform fmt -check && terraform validate && tflint && checkov -d . --compact
terraform plan -var 'gateway_enabled=false'
```
Expected: plan shows the ACA env **replaced** (`-/+`), the Container App replaced, and 3 new `azurerm_private_dns_*` resources for the ACA zone. Confirm no *other* resource is unexpectedly destroyed.

```bash
git add workloads/reelhouse/dev/aca.tf workloads/reelhouse/dev/aca-dns.tf
git commit -m "feat(reelhouse/dev): ACA env internal ingress + internal DNS zone (ADR-0019)"
```

---

## Task 4: NSG on the APIM subnet (gated)

**Files:**
- Modify: `workloads/reelhouse/dev/network.tf`

- [ ] **Step 1: Add the NSG + subnet association, gated on `gateway_enabled`**

In `network.tf`:

```hcl
# NSG for the APIM subnet. External-VNet APIM REQUIRES an NSG (its internal LB
# is secure-by-default and rejects all inbound until explicitly allowed). We
# point client inbound at the AzureFrontDoor.Backend service tag (lockdown
# layer 1 — see ADR-0019), plus the mandatory APIM management/health rules.
# Gated on gateway_enabled because the subnet is empty when the gateway is off.
resource "azurerm_network_security_group" "apim" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "nsg-apim-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.network.name
  location            = azurerm_resource_group.network.location
  tags                = var.required_tags

  # Client traffic: only from Azure Front Door (lockdown layer 1).
  security_rule {
    name                       = "AllowFrontDoorInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureFrontDoor.Backend"
    destination_address_prefix = "VirtualNetwork"
  }

  # Mandatory: APIM management endpoint (control plane). Without this APIM
  # cannot be managed and provisioning/health degrades.
  security_rule {
    name                       = "AllowApiManagementInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3443"
    source_address_prefix      = "ApiManagement"
    destination_address_prefix = "VirtualNetwork"
  }

  # Mandatory: Azure Load Balancer health probe.
  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6390"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "VirtualNetwork"
  }
  # Outbound: APIM stv2 needs Storage, AzureActiveDirectory, AzureKeyVault,
  # SQL, AzureMonitor, EventHub on the platform's default Allow-all outbound.
  # We do not restrict outbound here (default rules permit it). Documented in
  # ADR-0019 as a known relaxation.
}

resource "azurerm_subnet_network_security_group_association" "apim" {
  count                     = var.gateway_enabled ? 1 : 0
  subnet_id                 = azurerm_subnet.apim.id
  network_security_group_id = azurerm_network_security_group.apim[0].id
}
```

- [ ] **Step 2: Validate + plan + commit**

```bash
terraform fmt -check && terraform validate && tflint && checkov -d . --compact
terraform plan -var 'gateway_enabled=false'   # expect: NSG NOT planned (count=0)
terraform plan -var 'gateway_enabled=true'    # expect: NSG + association planned
```
Expected: with `false`, zero NSG resources; with `true`, 1 NSG + 1 association.

```bash
git add workloads/reelhouse/dev/network.tf
git commit -m "feat(reelhouse/dev): APIM subnet NSG, FrontDoor-only inbound (ADR-0019)"
```

---

## Task 5: Front Door profile + endpoint + WAF (gated)

**Files:**
- Create: `workloads/reelhouse/dev/frontdoor.tf`

- [ ] **Step 1: Create FD profile, endpoint, WAF policy, security policy**

Create `frontdoor.tf` (origin + route added in Task 7 once APIM exists):

```hcl
# Front Door Standard + WAF (Prevention). Public entry point for ReelHouse
# when gateway_enabled. Origin (APIM) and route are wired in this file after
# APIM is defined (see the origin/route block added in Task 7).
# Gated on gateway_enabled. Per ADR-0019.

resource "azurerm_cdn_frontdoor_profile" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "afd-reelhouse-dev-001"
  resource_group_name = azurerm_resource_group.workload.name
  sku_name            = "Standard_AzureFrontDoor"
  tags                = var.required_tags
}

resource "azurerm_cdn_frontdoor_endpoint" "this" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "fde-reelhouse-dev-001"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id
  tags                     = var.required_tags
}

# WAF — Prevention mode, CUSTOM rules only. Front Door Standard does NOT support
# managed rule sets (DRS); those require Premium (ADR-0019). One custom rule
# blocks common SQLi patterns in the query string — enough to demonstrate WAF
# blocking. Rate-limiting lives at APIM, not duplicated here.
resource "azurerm_cdn_frontdoor_firewall_policy" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "wafreelhousedev001" # alnum only
  resource_group_name = azurerm_resource_group.workload.name
  sku_name            = "Standard_AzureFrontDoor"
  enabled             = true
  mode                = "Prevention"

  custom_rule {
    name     = "BlockSqliPatterns"
    enabled  = true
    priority = 100
    type     = "MatchRule"
    action   = "Block"

    match_condition {
      match_variable     = "QueryString"
      operator           = "Contains"
      negation_condition = false
      # Lowercase transform applied → match_values must be lowercase.
      match_values = ["drop table", "union select", "' or ", "--", ";--"]
      transforms   = ["Lowercase", "UrlDecode"]
    }
  }
  tags = var.required_tags
}

# Bind the WAF policy to the endpoint host.
resource "azurerm_cdn_frontdoor_security_policy" "this" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "secpol-reelhouse-dev-001"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  security_policies {
    firewall {
      cdn_frontdoor_firewall_policy_id = azurerm_cdn_frontdoor_firewall_policy.this[0].id

      association {
        domain {
          cdn_frontdoor_domain_id = azurerm_cdn_frontdoor_endpoint.this[0].id
        }
        patterns_to_match = ["/*"]
      }
    }
  }
}
```

> Confirm `Microsoft_DefaultRuleSet` version against the provider/Azure during implementation (`az afd rule-set list` or provider docs); use the current GA version if 2.1 has moved.

- [ ] **Step 2: Validate + plan + commit**

```bash
terraform fmt -check && terraform validate && tflint && checkov -d . --compact
terraform plan -var 'gateway_enabled=false'   # expect: no FD resources
terraform plan -var 'gateway_enabled=true'    # expect: profile, endpoint, waf, secpol
git add workloads/reelhouse/dev/frontdoor.tf
git commit -m "feat(reelhouse/dev): Front Door Standard + WAF Prevention (ADR-0019)"
```

---

## Task 6: APIM (External VNet) + wildcard API + inbound lockdown/rate-limit policy (gated)

**Files:**
- Create: `workloads/reelhouse/dev/apim.tf`

- [ ] **Step 1: Create the APIM instance (External VNet, in `snet-apim-001`)**

Create `apim.tf`:

```hcl
# APIM Developer in External VNet mode: public gateway VIP (origin for Front
# Door), but VNet-injected into snet-apim-001 so it reaches the internal ACA
# backend over the spoke VNet. Public IP is Azure-managed (optional in External
# mode — we do not supply one). Gated on gateway_enabled. Per ADR-0019.
#
# publisher_email / publisher_name are required by APIM. They are NOT secrets,
# but publisher_email must not be a personal address committed to a public repo
# (CLAUDE.md §6) — sourced from var.apim_publisher_email (see variables.tf add
# below), default a non-personal placeholder.

resource "azurerm_api_management" "this" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "apim-reelhouse-dev-${var.location_short}-001"
  resource_group_name = azurerm_resource_group.workload.name
  location            = azurerm_resource_group.workload.location
  publisher_name      = "ReelHouse Lab"
  publisher_email     = var.apim_publisher_email
  sku_name            = "Developer_1"

  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }

  tags = var.required_tags

  # APIM subnet NSG association (Task 4) must exist before APIM provisions in
  # External mode; make the dependency explicit.
  depends_on = [azurerm_subnet_network_security_group_association.apim]
}
```

Add to `variables.tf`:

```hcl
variable "apim_publisher_email" {
  description = "APIM publisher email (required by APIM; not a secret, but keep personal addresses out of the public repo — use a role/alias). See CLAUDE.md §6."
  type        = string
  default     = "platform@reelhouse.invalid"
}
```

- [ ] **Step 2: Create the wildcard API → ACA internal backend**

Append to `apim.tf`:

```hcl
# Single wildcard pass-through API: all paths proxy to the ACA internal app.
# The backend host is the Container App's internal FQDN, resolvable via the
# per-env private DNS zone (aca-dns.tf) from the APIM subnet.
resource "azurerm_api_management_api" "reelhouse" {
  count               = var.gateway_enabled ? 1 : 0
  name                = "reelhouse"
  resource_group_name = azurerm_resource_group.workload.name
  api_management_name = azurerm_api_management.this[0].name
  revision            = "1"
  display_name        = "ReelHouse"
  path                = "" # root — FD route handles the public path prefix
  protocols           = ["https"]

  # The Container App's internal ingress FQDN. azurerm exposes the app FQDN;
  # for an internal env it is the *.<default_domain> form resolved privately.
  service_url = "https://${azurerm_container_app.api.ingress[0].fqdn}"
}

resource "azurerm_api_management_api_operation" "wildcard" {
  count               = var.gateway_enabled ? 1 : 0
  operation_id        = "wildcard"
  api_name            = azurerm_api_management_api.reelhouse[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.workload.name
  display_name        = "Wildcard"
  method              = "*"
  url_template        = "/*"
  description         = "Catch-all proxy to the ReelHouse ACA backend."
}
```

> Confirm `azurerm_container_app.api.ingress[0].fqdn` returns the internal FQDN for an internal env during implementation. If the attribute is not exposed for internal envs, fall back to constructing `https://<app-name>.internal.${azurerm_container_app_environment.this.default_domain}` and verify resolution from the APIM subnet.

- [ ] **Step 3: Inbound policy — lockdown (check-header) + rate-limit**

Append to `apim.tf`. The `X-Azure-FDID` expected value is the Front Door profile's `resource_guid` (interpolated from Terraform state — never hardcoded, never committed):

```hcl
# Inbound API policy:
#   1. check-header X-Azure-FDID == this Front Door's ID (lockdown layer 2 —
#      pins to THIS FD instance, since the AzureFrontDoor.Backend NSG tag is
#      shared across all tenants). Per ADR-0019.
#   2. rate-limit-by-key — demonstrable gateway policy.
resource "azurerm_api_management_api_policy" "reelhouse" {
  count               = var.gateway_enabled ? 1 : 0
  api_name            = azurerm_api_management_api.reelhouse[0].name
  api_management_name = azurerm_api_management.this[0].name
  resource_group_name = azurerm_resource_group.workload.name

  xml_content = <<XML
<policies>
  <inbound>
    <base />
    <check-header name="X-Azure-FDID" failed-check-httpcode="403" failed-check-error-message="Direct access is not allowed." ignore-case="true">
      <value>${azurerm_cdn_frontdoor_profile.this[0].resource_guid}</value>
    </check-header>
    <rate-limit-by-key calls="100" renewal-period="60" counter-key="@(context.Request.IpAddress)" />
  </inbound>
  <backend><base /></backend>
  <outbound><base /></outbound>
  <on-error><base /></on-error>
</policies>
XML
}
```

- [ ] **Step 4: Validate + plan + commit**

```bash
terraform fmt -check && terraform validate && tflint && checkov -d . --compact
terraform plan -var 'gateway_enabled=false'   # expect: no APIM resources
terraform plan -var 'gateway_enabled=true'    # expect: apim + api + operation + policy
git add workloads/reelhouse/dev/apim.tf workloads/reelhouse/dev/variables.tf
git commit -m "feat(reelhouse/dev): APIM External VNet + wildcard API + FD lockdown/rate-limit (ADR-0019)"
```

---

## Task 7: Wire Front Door origin + route to APIM (gated)

**Files:**
- Modify: `workloads/reelhouse/dev/frontdoor.tf`

- [ ] **Step 1: Add origin group, origin (APIM gateway), and route**

Append to `frontdoor.tf`:

```hcl
resource "azurerm_cdn_frontdoor_origin_group" "apim" {
  count                    = var.gateway_enabled ? 1 : 0
  name                     = "og-apim"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.this[0].id

  load_balancing {}

  health_probe {
    interval_in_seconds = 100
    path                = "/status-0123456789abcdef" # APIM default health endpoint
    protocol            = "Https"
    request_type        = "GET"
  }
}

# Origin = APIM's public gateway hostname. FD reaches APIM over the internet
# (FD Standard can't use a private origin); the NSG + X-Azure-FDID header keep
# APIM reachable only through THIS Front Door.
resource "azurerm_cdn_frontdoor_origin" "apim" {
  count                          = var.gateway_enabled ? 1 : 0
  name                           = "origin-apim"
  cdn_frontdoor_origin_group_id  = azurerm_cdn_frontdoor_origin_group.apim[0].id
  enabled                        = true
  certificate_name_check_enabled = true

  host_name          = "apim-reelhouse-dev-${var.location_short}-001.azure-api.net"
  origin_host_header = "apim-reelhouse-dev-${var.location_short}-001.azure-api.net"
  https_port         = 443
  http_port          = 80
  priority           = 1
  weight             = 1
}

resource "azurerm_cdn_frontdoor_route" "default" {
  count                         = var.gateway_enabled ? 1 : 0
  name                          = "route-default"
  cdn_frontdoor_endpoint_id     = azurerm_cdn_frontdoor_endpoint.this[0].id
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.apim[0].id
  cdn_frontdoor_origin_ids      = [azurerm_cdn_frontdoor_origin.apim[0].id]

  supported_protocols    = ["Http", "Https"]
  patterns_to_match      = ["/*"]
  forwarding_protocol    = "HttpsOnly"
  https_redirect_enabled = true
  link_to_default_domain = true
}
```

> The APIM gateway host is deterministic (`<apim-name>.azure-api.net`), so it is referenced by name to avoid a hard dependency cycle with the FD profile (APIM already depends on the FD profile's `resource_guid`). Confirm the gateway hostname format during implementation via `azurerm_api_management.this[0].gateway_url` and switch to the attribute if it avoids the cycle cleanly.

- [ ] **Step 2: Validate + plan + commit**

```bash
terraform fmt -check && terraform validate && tflint && checkov -d . --compact
terraform plan -var 'gateway_enabled=true'    # expect: origin group, origin, route added
git add workloads/reelhouse/dev/frontdoor.tf
git commit -m "feat(reelhouse/dev): FD origin+route to APIM gateway (ADR-0019)"
```

---

## Task 8: Output the FD endpoint + README runbook

**Files:**
- Modify: `workloads/reelhouse/dev/outputs.tf`
- Modify: `workloads/reelhouse/dev/README.md`

- [ ] **Step 1: Add the FD endpoint output**

In `outputs.tf`:

```hcl
output "frontdoor_endpoint_hostname" {
  description = "Public Front Door hostname for ReelHouse (null when gateway_enabled=false)."
  value       = var.gateway_enabled ? azurerm_cdn_frontdoor_endpoint.this[0].host_name : null
}
```

- [ ] **Step 2: README — toggle usage, CI reorder, verification runbook**

Add a "Gateway tier (on-demand)" section to `README.md` covering:
- `terraform apply -var 'gateway_enabled=true'` to stand up; `=false` to tear down. ~€70/mo while up, ~45min APIM provision.
- **After the FIRST apply that flips ACA internal** (Task 3's apply), re-run the `reelhouse-build-deploy` workflow so the recreated Container App gets its image.
- The §13 verification runbook (copy the 5 checks below from Task 9).

- [ ] **Step 3: Validate + commit**

```bash
terraform fmt -check && terraform validate
git add workloads/reelhouse/dev/outputs.tf workloads/reelhouse/dev/README.md
git commit -m "docs(reelhouse/dev): FD endpoint output + gateway runbook"
```

---

## Task 9: Apply + end-to-end verification (MILESTONE — costs money, ~45min)

> This is an apply milestone, run by Eyal with `~/.keystone/secrets.env` sourced. It is not a code step. Confirm with Eyal before applying (cost + ACA recreation).

- [ ] **Step 1: Apply the permanent ACA-internal flip first (gateway still off)**

```bash
terraform apply -var 'gateway_enabled=false'
```
Expected: ACA env + Container App **recreated** internal; ACA private DNS zone created. ReelHouse is now NOT publicly reachable.

- [ ] **Step 2: Redeploy the image**

Re-run the `reelhouse-build-deploy` GitHub Actions workflow. Confirm the Container App has a running revision.

- [ ] **Step 3: Stand up the gateway**

```bash
terraform apply -var 'gateway_enabled=true'   # ~45min for APIM
terraform output frontdoor_endpoint_hostname
```

- [ ] **Step 4: Verify end-to-end (CLAUDE.md / memory: prove user-visible behavior)**

1. **Through Front Door:** `curl -sS https://<fd-endpoint>.azurefd.net/` returns the ReelHouse app response. ✅
2. **Direct-to-APIM is rejected:** `curl -sS https://apim-reelhouse-dev-<region>-001.azure-api.net/` returns 403 / connection refused (NSG drops non-FD source, or header check 403s). ✅ — this proves lockdown.
3. **WAF blocks an attack:** `curl -sS "https://<fd-endpoint>.azurefd.net/?q=1';DROP TABLE users;--"` (obvious SQLi) returns 403 from Front Door. ✅ — proves Prevention mode.
4. **Rate limit:** a burst >100 req/60s from one IP starts returning 429. ✅
5. **Tear down:** `terraform apply -var 'gateway_enabled=false'` removes FD + APIM; ReelHouse no longer publicly reachable; ACA env survives. ✅

- [ ] **Step 5: Break/debug + session close (CLAUDE.md §8, §9)**

- Add a `docs/break-debug-log.md` entry (or seed): e.g. "APIM 502 because the ACA internal FQDN didn't resolve from the APIM subnet — missing private DNS zone link." Signal to look at first: APIM API inspector / `nslookup` from APIM.
- Confirm ADR-0019 committed, README runbook present, and Eyal can articulate the topology + why two lockdown layers.

---

## Self-Review (completed by plan author)

- **Spec coverage:** §2 topology → Tasks 3,5,6,7. §3 lifecycle/toggle → Tasks 2,4,5,6,7 (count gating). §4 ACA recreate + CI ripple → Task 3 + Task 8/9. §5 ACA DNS → Task 3. §6 two-layer lockdown → Task 4 (NSG) + Task 6 (header check); ip-filter rejected → Task 1 (ADR). §7 WAF + rate-limit → Task 5 + Task 6. §8 wildcard API → Task 6. §9 build inventory → all tasks. §10 cost → ADR + README. §11 out-of-scope → not built (correct). §12 secrets (FD ID via attribute, publisher email var) → Task 6. §13 verification → Task 9. All sections covered.
- **Placeholder scan:** no TBD/TODO; concrete HCL in every code step. Three "confirm during implementation" notes are genuine provider-version verifications (DRS version, internal-env FQDN attribute, APIM gateway host attribute), not deferred work — each has a stated fallback.
- **Type/name consistency:** resource names (`azurerm_cdn_frontdoor_profile.this`, `azurerm_api_management.this`, `azurerm_container_app_environment.this`, `azurerm_subnet.apim`) referenced consistently across tasks; `gateway_enabled` count pattern uniform; `[0]` indexing used wherever a counted resource is referenced.
