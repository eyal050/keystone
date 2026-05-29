# ADR-0017: On-demand workload data plane (Postgres + workload PEs)

- **Status**: Accepted
- **Date**: 2026-05-29
- **Decider**: Eyal
- **Supersedes**: —
- **Builds on**: [ADR-0010](0010-firewall-on-demand-not-scheduled.md) (same conditional-count pattern, different resources)

## Context

After ADR-0016 made operator inspection possible, Eyal asked for a
cost audit of the workload at scale. The audit revealed:

- The 3 workload private endpoints (Postgres, Key Vault, Blob) cost
  **~$22/mo flat** regardless of traffic — $7.30/mo each just for
  the PE resource hours (`$0.01/hr × 730 hr`).
- Postgres Flexible B1ms is **~$13/mo always-on** for a server
  that's idle 95% of the time between learning sessions.

Combined, the workload's "idle but exists" baseline is ~$35/mo
even when the operator isn't actively using anything. The lab's
target is "≤€20/mo idle"; we were exceeding it ~2×.

The workload doesn't need to be live continuously. Sessions are
infrequent. Most of the time the workload sits unused.

## Decision

**Toggle the workload data plane on demand.** Two new variables on
`workloads/reelhouse/dev`:

- **`var.postgres_enabled`** (default `false`) — gates:
  - `azurerm_postgresql_flexible_server.this`
  - `azurerm_postgresql_flexible_server_database.reelhouse`
  - `azurerm_private_endpoint.postgres`
  - `azurerm_key_vault_secret.postgres_connection_string` (the secret value references the PG FQDN; both come/go together)

- **`var.workload_pe_enabled`** (default `false`) — gates the
  *workload-side private endpoints* that aren't tied to PG lifecycle:
  - `azurerm_private_endpoint.keyvault`
  - `azurerm_private_endpoint.blob`

Postgres and the KV/Blob PEs are split because they have different
cadences:

- **Postgres is long-term off** ("destroy it; I'll tell you when I
  want it back"). Provisioning is slow (~10–15 min), so re-creating
  every session would be operationally painful — only flip when a
  session genuinely needs DB-backed features.
- **KV/Blob PEs are per-session.** Provisioning is ~30s each.
  Future me asks the operator at session start: *"do you want the
  KV + Blob PEs up today?"* (feedback memory captures this prompt).

Other workload resources stay always-on because they're cheap or
need to be:

- **Container App + ACA env**: scale-to-zero (Consumption), ~$0
  idle. CI also requires the Container App resource to exist (so it
  can `az containerapp update --image`).
- **Key Vault + Blob storage account**: pennies/mo storage. Holding
  state across sessions matters (secrets, video files).
- **ACR**: ~$4.30/mo. Holds the built image; destroying it forces a
  rebuild + re-push next session.
- **Spoke VNet + subnets + peerings**: free.
- **Workload-side PEs not gated**: none currently.

## Consequences

**Positive:**

- **Idle cost drops by ~$36/mo** when both toggles are off
  (~€17/mo → ~€3/mo for the workload contribution).
- **No data loss** — Postgres data IS lost when the server is
  destroyed (no backup retention beyond the live DB), but the lab's
  data is "videos for testing" which is recoverable. App's
  `init_schema()` is idempotent — fresh DB after recreate works.
- **Pattern reuse**: same conditional-count + `make X-up`/`X-down`
  shape as ADR-0010. Operators learn one pattern, apply it everywhere.
- **Future-me memory hook**: a feedback memory ensures the next
  session asks before silently applying with PEs off.

**Negative / trade-offs:**

- **Postgres provisioning latency.** ~10–15 min between
  `make postgres-up` and "DB reachable." First session of any
  workload-needing day eats this.
- **Postgres FQDN is stable across destroys/recreates** (it derives
  from the resource name), so the KV-stored connection string is
  re-creatable cleanly. But: any client that cached the IP, or any
  PE-routed DNS A record, becomes stale during the gap. The central
  DNS zone's A record IS auto-managed by the PE, so it
  re-materialises with the PE.
- **Workload functionality is split**: with PG off, the app's
  upload/share/play paths all fail (DB write/read errors). The
  app's `/healthz` still returns 200 ok (doesn't touch PG), so the
  ACA health probe doesn't crash-loop the container. But human-visible
  use is broken.
- **Random password regeneration risk**: `random_password.postgres_admin`
  is NOT gated by `var.postgres_enabled` — it stays in state and
  produces a stable password across PG recreates. **Don't add a
  `keeper` that ties it to the PG resource**, or each recreate
  would generate a new password and break the consumer.

## Toggles & operator workflow

```bash
# At session start (when DB-backed features will be used)
TF_VAR_postgres_enabled=true \
TF_VAR_workload_pe_enabled=true \
  ./scripts/_tf-cmd.sh workloads/reelhouse/dev apply -auto-approve

# At session end (return to €3/mo idle)
./scripts/_tf-cmd.sh workloads/reelhouse/dev apply -auto-approve
# (both vars default false → PG + PEs destroyed)

# Or finer: bring up just the PEs for blob inspection,
# without provisioning Postgres
TF_VAR_workload_pe_enabled=true \
  ./scripts/_tf-cmd.sh workloads/reelhouse/dev apply -auto-approve
```

The Makefile gains `postgres-up`, `postgres-down`, `workload-pe-up`,
`workload-pe-down` as thin wrappers.

## What ISN'T conditionally gated

| Resource | Why stays always-on |
|---|---|
| Spoke VNet + subnets + peerings | Free |
| Hub-side peering (in connectivity sub) | Free |
| Spoke DNS zone links | Free |
| Key Vault (the vault itself, not the PE) | Pennies/mo, holds secrets |
| Blob storage account + container | Pennies/mo, holds videos |
| ACA env + Container App | Free idle (scale-to-zero) |
| ACR | ~$4.30/mo, holds built image |
| All role assignments | Free |
| Policy exemptions | Free |

## Alternatives considered

- **`var.workload_running` single toggle.** Considered. Forced
  Postgres provisioning latency onto every PE bring-up. Eyal
  explicitly wanted to separate them — PG is "off for now," PEs are
  "per session."
- **Destroy the Container App + ACA env too.** Rejected. The CI/CD
  workflow assumes both exist (does `az containerapp update`).
  Tearing them down would also tear down the GH Actions role
  assignments (Contributor on the CA + env), forcing recreate of
  those too. Compound complexity for ~$0 savings (ACA env on
  Consumption profile is free, Container App scale-to-zero is free).
- **Backup Postgres before destroy + restore on bring-up.** Rejected:
  Postgres Flexible "long-term backup" feature is in preview and
  adds cost; manual `pg_dump` to Blob would work but requires
  network access AT destroy time (PE alive) and is brittle for a
  lab. Accept data loss on PG cycles.
- **Scheduled deallocation instead of operator-toggled.** Rejected
  for the same reasons as ADR-0010 — usage is unpredictable,
  scheduled uptime still wastes hours.

## Future revisit triggers

- Operator finds the per-session PE prompt friction-y → set
  `workload_pe_enabled = true` as the new default.
- PG provisioning latency becomes painful → consider keeping PG
  always-on (~$13/mo for the convenience).
- Workload sees real users (no longer "Eyal occasionally") → revisit
  the whole on-demand posture, switch to always-on with Cost
  Management budgets and lifecycle policies instead.
