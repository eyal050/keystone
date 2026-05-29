"""
ReelHouse API — minimal video upload + share-link service.

Per CLAUDE.md §2, this app exists to *justify* the Keystone platform,
not to be a production video service. It deliberately skips:
- Real auth (single hardcoded admin user, password from Key Vault).
- Transcoding, adaptive bitrate, multi-format support.
- Mobile clients, watch lists, recommendations, anything Netflix-like.

What it does:
- POST /upload  (auth required)  — store video to Blob, mint share token.
- GET  /share/<token>             — return a player page if token is live.
- GET  /play/<token>              — stream the blob through the app
                                   (proxy pattern — storage stays private,
                                   no SAS URLs exposed to the client).
- GET  /                          — login + upload form.
- GET  /healthz                   — ACA health probe.

Auth flow:
- POST /login with admin password → sets a signed cookie.
- Cookie carries an HMAC of "admin" signed with REELHOUSE_COOKIE_SECRET
  (random per-container-start; sessions die when the app restarts).

Storage access:
- ACA's managed identity reads/writes Blob via Storage Blob Data
  Contributor (granted in Terraform aca.tf).
- Postgres connection string read from KV (Key Vault Secrets User).
- KV name + Storage account name come from env vars set by ACA.
"""

import base64
import hashlib
import hmac
import os
import secrets
import uuid
from datetime import datetime

import psycopg
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.storage.blob import BlobServiceClient
from flask import (
    Flask,
    Response,
    abort,
    make_response,
    redirect,
    render_template_string,
    request,
)

app = Flask(__name__)

# --- Config (env vars set by ACA Container App) -----------------------------

KEYVAULT_URI = os.environ["KEYVAULT_URI"]
STORAGE_ACCOUNT_NAME = os.environ["STORAGE_ACCOUNT_NAME"]
STORAGE_CONTAINER = os.environ["STORAGE_CONTAINER"]
PORT = int(os.environ.get("PORT", "8080"))

# Cookie signing secret — random per container start. Sessions die on
# restart, which is fine for a lab admin login.
COOKIE_SECRET = secrets.token_bytes(32)

# --- Azure clients ---------------------------------------------------------

credential = DefaultAzureCredential()
kv = SecretClient(vault_url=KEYVAULT_URI, credential=credential)
blob_service = BlobServiceClient(
    account_url=f"https://{STORAGE_ACCOUNT_NAME}.blob.core.windows.net",
    credential=credential,
)
container_client = blob_service.get_container_client(STORAGE_CONTAINER)

# --- Bootstrap: fetch secrets, init Postgres schema ------------------------

PG_CONN_STR = kv.get_secret("postgres-connection-string").value
ADMIN_PASSWORD = kv.get_secret("reelhouse-admin-password").value


def init_schema():
    """Create the videos table if not exists. Idempotent."""
    with psycopg.connect(PG_CONN_STR, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS videos (
                    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    blob_name    TEXT NOT NULL,
                    original_name TEXT,
                    uploaded_at  TIMESTAMP NOT NULL DEFAULT NOW(),
                    share_token  TEXT UNIQUE NOT NULL,
                    revoked      BOOLEAN NOT NULL DEFAULT FALSE
                );
                """
            )


init_schema()

# --- Cookie auth -----------------------------------------------------------


def sign(value: str) -> str:
    """Return base64(HMAC-SHA256(value)) using the per-process secret."""
    digest = hmac.new(COOKIE_SECRET, value.encode(), hashlib.sha256).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")


def is_authed() -> bool:
    cookie = request.cookies.get("reelhouse_auth")
    return cookie == sign("admin")


def require_auth():
    if not is_authed():
        abort(401)


# --- Routes ----------------------------------------------------------------


@app.route("/healthz")
def healthz():
    return "ok", 200


@app.route("/")
def index():
    authed = is_authed()
    return render_template_string(INDEX_HTML, authed=authed)


@app.route("/login", methods=["POST"])
def login():
    password = request.form.get("password", "")
    if not hmac.compare_digest(password, ADMIN_PASSWORD):
        return "Invalid password", 401
    resp = make_response(redirect("/"))
    resp.set_cookie(
        "reelhouse_auth",
        sign("admin"),
        httponly=True,
        secure=True,
        samesite="Lax",
    )
    return resp


@app.route("/logout", methods=["POST"])
def logout():
    resp = make_response(redirect("/"))
    resp.delete_cookie("reelhouse_auth")
    return resp


@app.route("/upload", methods=["POST"])
def upload():
    require_auth()
    f = request.files.get("video")
    if f is None or f.filename == "":
        return "No file", 400

    blob_name = f"{uuid.uuid4()}-{f.filename}"
    container_client.upload_blob(
        name=blob_name,
        data=f.stream,
        overwrite=False,
        content_type=f.content_type or "application/octet-stream",
    )

    share_token = secrets.token_urlsafe(16)
    with psycopg.connect(PG_CONN_STR, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO videos (blob_name, original_name, share_token) "
                "VALUES (%s, %s, %s)",
                (blob_name, f.filename, share_token),
            )

    return redirect(f"/share/{share_token}")


@app.route("/share/<token>")
def share(token):
    row = lookup_token(token)
    if row is None:
        abort(404)
    blob_name, original_name = row
    return render_template_string(
        SHARE_HTML, token=token, original_name=original_name
    )


@app.route("/play/<token>")
def play(token):
    row = lookup_token(token)
    if row is None:
        abort(404)
    blob_name, _ = row
    bc = container_client.get_blob_client(blob_name)
    stream = bc.download_blob()

    def generate():
        for chunk in stream.chunks():
            yield chunk

    content_type = bc.get_blob_properties().content_settings.content_type
    return Response(generate(), mimetype=content_type or "application/octet-stream")


@app.route("/revoke/<token>", methods=["POST"])
def revoke(token):
    require_auth()
    with psycopg.connect(PG_CONN_STR, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE videos SET revoked = TRUE WHERE share_token = %s", (token,)
            )
    return redirect("/")


def lookup_token(token: str):
    """Return (blob_name, original_name) for a live token, or None."""
    with psycopg.connect(PG_CONN_STR, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT blob_name, original_name FROM videos "
                "WHERE share_token = %s AND revoked = FALSE",
                (token,),
            )
            return cur.fetchone()


# --- Templates (embedded for single-file deploy) ----------------------------

INDEX_HTML = """
<!doctype html><html><head><meta charset=utf-8>
<title>ReelHouse</title>
<style>
body { font-family: system-ui, sans-serif; max-width: 600px; margin: 2em auto; padding: 1em; }
form { margin: 1em 0; }
input, button { font-size: 1em; padding: 0.4em; }
.muted { color: #888; font-size: 0.85em; }
</style></head>
<body>
<h1>ReelHouse</h1>
<p class=muted>Minimal video upload + revocable share-link service.
Part of the <em>Keystone</em> ESLZ lab. See repo for context.</p>

{% if authed %}
  <form method=POST action="/logout"><button>Log out</button></form>
  <h2>Upload</h2>
  <form method=POST action="/upload" enctype="multipart/form-data">
    <input type=file name=video required accept="video/*">
    <button>Upload</button>
  </form>
{% else %}
  <form method=POST action="/login">
    <label>Admin password: <input type=password name=password required></label>
    <button>Log in</button>
  </form>
{% endif %}
</body></html>
"""

SHARE_HTML = """
<!doctype html><html><head><meta charset=utf-8>
<title>ReelHouse — {{ original_name or token }}</title>
<style>
body { font-family: system-ui, sans-serif; max-width: 800px; margin: 2em auto; padding: 1em; }
video { width: 100%; max-height: 70vh; background: #000; }
.muted { color: #888; font-size: 0.85em; }
</style></head>
<body>
<h1>{{ original_name or "Untitled" }}</h1>
<video controls preload=metadata>
  <source src="/play/{{ token }}">
  Your browser doesn't support this video format.
</video>
<p class=muted>Share token: <code>{{ token }}</code>. Anyone with this
link can play the video until it is revoked.</p>
</body></html>
"""


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
