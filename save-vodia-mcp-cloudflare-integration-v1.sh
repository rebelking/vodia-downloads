#!/usr/bin/env bash
# Vodia MCP Cloudflare integration saver v1
#
# Purpose:
#   Securely save the Cloudflare zone + API token into the existing Vodia MCP
#   encrypted integrations store when the Control Center has only tested the
#   connection but no 'cloudflare' row exists in auth.db.
#
# Security:
#   - API token is entered interactively with terminal echo disabled.
#   - Token is never printed, logged, passed on the command line, or written to
#     a plaintext file.
#   - Uses the installed cloudflare-integration.js saveCloudflareIntegration()
#     function, so the credential is encrypted with the existing SESSION_SECRET.
#
# Usage:
#   sudo bash save-vodia-mcp-cloudflare-integration-v1.sh
#   sudo bash save-vodia-mcp-cloudflare-integration-v1.sh --domain audiomercy.com

set -Eeuo pipefail

APP="/opt/vodia-mcp"
CF="$APP/cloudflare-integration.js"
ENV_FILE="/etc/vodia-mcp.env"
SERVICE="vodia-mcp"
DEFAULT_DB="/var/lib/vodia-mcp/auth.db"
DOMAIN="audiomercy.com"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP_JS="$(mktemp /tmp/vodia-cloudflare-save.XXXXXX.mjs)"
TOKEN=""
BACKUP=""
SAVED=0

cleanup() {
  TOKEN=""
  rm -f "$TMP_JS"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

case "${1:-}" in
  "") ;;
  --domain)
    [[ -n "${2:-}" ]] || fail "--domain requires a value"
    DOMAIN="$2"
    ;;
  *)
    echo "Usage: $0 [--domain example.com]" >&2
    exit 2
    ;;
esac

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"
[[ -f "$CF" ]] || fail "missing $CF"
[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE"

echo "=== Vodia MCP Cloudflare integration saver v1 ==="
echo "Zone: $DOMAIN"
echo "The API token will be entered securely and will not be displayed."
echo

# Load the exact environment used by the service. Do not enable shell tracing.
set +x
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
set +x

DB_PATH="${DB_PATH:-$DEFAULT_DB}"
[[ -n "${SESSION_SECRET:-}" ]] || fail "SESSION_SECRET is not present in $ENV_FILE"
(( ${#SESSION_SECRET} >= 24 )) || fail "SESSION_SECRET is shorter than required by the Cloudflare integration"
[[ -f "$DB_PATH" ]] || fail "database does not exist: $DB_PATH"

BACKUP="${DB_PATH}.pre-cloudflare-save.${STAMP}"
cp -a "$DB_PATH" "$BACKUP"
echo "Backup: $BACKUP"

read -r -s -p "Cloudflare API token: " TOKEN
echo
[[ -n "$TOKEN" ]] || fail "no API token entered"

cat > "$TMP_JS" <<'NODE'
import fs from "node:fs";
import {
  saveCloudflareIntegration,
  getCloudflareIntegrationStatus,
  checkSavedCloudflareConnection,
} from "file:///opt/vodia-mcp/cloudflare-integration.js";

const token = fs.readFileSync(0, "utf8").replace(/[\r\n]+$/, "");
const domain = String(process.env.CF_SAVE_DOMAIN || "").trim();

if (!domain) throw new Error("CF_SAVE_DOMAIN is missing");
if (!token) throw new Error("Cloudflare API token was empty");

const saved = await saveCloudflareIntegration({ domain, apiToken: token });
const status = getCloudflareIntegrationStatus();
const checked = await checkSavedCloudflareConnection();

const safe = {
  saved: true,
  provider: status.provider,
  configured: status.configured,
  connected: Boolean(checked.connected),
  domain: checked.domain || status.domain || null,
  zoneId: checked.zoneId || status.zoneId || null,
  zoneStatus: checked.zoneStatus || null,
  accountName: checked.accountName || status.accountName || null,
  tokenStatus: checked.tokenStatus || null,
  permissions: checked.permissions || null,
  credentialStored: Boolean(status.credentialStored),
  changesMade: true,
};

console.log(JSON.stringify(safe, null, 2));
NODE

chmod 600 "$TMP_JS"

echo
printf '%s' "$TOKEN" | CF_SAVE_DOMAIN="$DOMAIN" node "$TMP_JS"
SAVED=1
TOKEN=""

# Keep database ownership/permissions consistent with the service account.
if id vodiamcp >/dev/null 2>&1; then
  chown vodiamcp:vodiamcp "$DB_PATH"
  chmod 600 "$DB_PATH"
fi

echo
echo "Verifying the Cloudflare row exists without exposing the credential..."
python3 - "$DB_PATH" <<'PY'
import json, sqlite3, sys
p = sys.argv[1]
con = sqlite3.connect(p)
row = con.execute("SELECT provider, config_json, length(secret_blob), updated_at FROM integrations WHERE provider='cloudflare'").fetchone()
con.close()
if not row:
    raise SystemExit("VERIFY FAIL: cloudflare row was not found after save")
config = json.loads(row[1] or "{}")
print(json.dumps({
    "cloudflareRowFound": True,
    "provider": row[0],
    "domain": config.get("domain"),
    "zoneIdPresent": bool(config.get("zoneId")),
    "credentialBlobPresent": bool(row[2] and row[2] > 0),
    "updatedAt": row[3],
}, indent=2))
PY

echo
echo "PASS: Cloudflare integration is saved in $DB_PATH"
echo "No service restart is required; the MCP tools read the integration from the database on each call."
echo "Next test in Claude: cloudflare_check_connection"
echo "Rollback copy retained at: $BACKUP"
