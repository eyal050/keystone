# `app/api` — ReelHouse API

Minimal Flask app behind the Container App in `workloads/reelhouse/dev/`.
Single file: `main.py`. ~250 lines. Per CLAUDE.md §1 this exists to
*justify* the Keystone platform, not to be a production video service.

## What it does

- **POST /upload** (auth required) — multipart upload, stores video
  to Blob via the ACA managed identity, mints a random share token,
  redirects to the share page.
- **GET /share/<token>** — HTML player page for a live token. Returns
  404 if the token is revoked or missing.
- **GET /play/<token>** — streams the blob through the app
  (*proxy pattern* — storage stays private, no SAS URLs are exposed).
- **POST /revoke/<token>** (auth required) — marks the token revoked.
- **GET /** — login form (single hardcoded admin) + upload form (when
  logged in).
- **GET /healthz** — for the ACA liveness probe.

## Why no SAS URLs

Workload storage has public network access disabled (enforced by the
`deny-storage-public` policy at the `keystone-landing-zones-corp` MG
scope per CLAUDE.md §2). A SAS URL pointing at
`https://<sa>.blob.core.windows.net/...` would resolve to the public
storage IP, which rejects all traffic — the SAS would be unusable from
a browser. Proxying through the Container App keeps the storage truly
private.

## Auth model

Single hardcoded admin user. Password lives in Key Vault as
`reelhouse-admin-password` (set by Terraform K1 from a `random_password`
resource). Cookie is HMAC-signed with a per-container-process secret;
restarting the Container App invalidates all sessions. **For lab demo
use only** — no MFA, no rate limiting, no audit log.

## Build & push

The Container App's `image` variable defaults to
`mcr.microsoft.com/azuredocs/aci-helloworld:latest` so Terraform can
apply before the real image exists. To swap in the real ReelHouse API:

```bash
# 1. Build locally
cd app/api
docker build -t ghcr.io/eyal050/reelhouse-api:latest .

# 2. Authenticate to GHCR with a Personal Access Token that has
#    `write:packages` scope:
echo "$GHCR_PAT" | docker login ghcr.io -u eyal050 --password-stdin

# 3. Push
docker push ghcr.io/eyal050/reelhouse-api:latest

# 4. (One-time) On GitHub: Profile → Packages → reelhouse-api →
#    Package settings → Change visibility → Public. Without this,
#    ACA's anonymous pull from GHCR will fail with 401.

# 5. Re-apply Terraform with the real image
cd ../../workloads/reelhouse/dev
TF_VAR_workload_image=ghcr.io/eyal050/reelhouse-api:latest \
  ../../../scripts/_tf-cmd.sh workloads/reelhouse/dev apply -auto-approve
```

The Container App will create a new revision pointing at the new
image; ACA shifts 100% traffic to it once the readiness probe passes.

## Local development

```bash
# Set env vars to match what ACA sets, then run locally with `az login` auth
export KEYVAULT_URI="https://kv-reelhdev-XXXXXXXX.vault.azure.net/"
export STORAGE_ACCOUNT_NAME="streelhdevXXXXXXXX"
export STORAGE_CONTAINER="videos"
export PORT=8080
pip install -r requirements.txt
python main.py
```

For local development to work end-to-end, your `az login` identity
needs:
- `Key Vault Secrets User` on the workload KV
- `Storage Blob Data Contributor` on the workload SA
- Network reachability to the private endpoints (i.e. through a VPN to
  the spoke VNet, OR temporarily allow your IP in the storage/KV
  firewall — which the deny-storage-public policy forbids for storage)

Realistically, local dev against the deployed Postgres/KV/Blob is
painful because of the private-endpoint posture. Use a fresh local
sandbox if you need to iterate on the app code.

## Future improvements

- Real auth (Entra External ID / B2C).
- Server-side video transcoding.
- Range-request support on `/play/<token>` for proper video seeking
  (current impl streams the whole blob start-to-finish).
- Move Postgres auth to Entra (workload MI authenticates to PG instead
  of password from KV).
- Rate limiting on `/upload` and `/login`.
- Audit log table (who uploaded what, when revoked).
