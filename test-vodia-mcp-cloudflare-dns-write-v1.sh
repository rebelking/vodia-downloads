#!/usr/bin/env bash
# Vodia MCP Cloudflare DNS write permission smoke test v1
#
# Purpose:
#   Verify a replacement Cloudflare API token has the minimum write access we
#   need for Phase 2, without leaving a permanent DNS record behind.
#
# What it does:
#   1. Backs up the current auth/integration database.
#   2. Prompts for the replacement Cloudflare token with terminal echo disabled.
#   3. Verifies token + zone access for the selected zone.
#   4. Creates a unique temporary TXT record.
#   5. Reads the record back.
#   6. Deletes the temporary record and verifies it is gone.
#   7. Only after the write smoke test passes, stores the new token using the
#      existing encrypted Cloudflare integration store.
#   8. Verifies the saved integration is connected.
#
# Security:
#   - Token is never printed, logged, passed on the command line, or written to
#     a plaintext file.
#   - The old integration database is retained as a rollback copy.
#   - If saving/verifying the new credential fails, the database is restored.
#
# Usage:
#   sudo bash test-vodia-mcp-cloudflare-dns-write-v1.sh
#   sudo bash test-vodia-mcp-cloudflare-dns-write-v1.sh --domain audiomercy.com

set -Eeuo pipefail

APP="/opt/vodia-mcp"
CF="$APP/cloudflare-integration.js"
ENV_FILE="/etc/vodia-mcp.env"
DEFAULT_DB="/var/lib/vodia-mcp/auth.db"
DOMAIN="audiomercy.com"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP_JS="$(mktemp /tmp/vodia-cloudflare-write-test.XXXXXX.mjs)"
TOKEN=""
BACKUP=""
ARMED=0

cleanup(){
  TOKEN=""
  rm -f "$TMP_JS"
}

restore_db(){
  trap - ERR
  if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
    echo "Restoring integration database from $BACKUP"
    cp -a "$BACKUP" "$DB_PATH"
    if id vodiamcp >/dev/null 2>&1; then
      chown vodiamcp:vodiamcp "$DB_PATH" 2>/dev/null || true
      chmod 600 "$DB_PATH" 2>/dev/null || true
    fi
  fi
}

rollback(){
  local rc=$?
  if (( ARMED )); then
    restore_db
  fi
  cleanup
  exit "$rc"
}

fail(){
  echo "FAIL: $*" >&2
  if (( ARMED )); then
    restore_db
    ARMED=0
  fi
  cleanup
  exit 1
}

trap cleanup EXIT

case "${1:-}" in
  "") ;;
  --domain)
    [[ -n "${2:-}" ]] || { echo "FAIL: --domain requires a value" >&2; exit 2; }
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

printf '%s\n' "=== Vodia MCP Cloudflare DNS write permission test v1 ==="
printf 'Zone: %s\n' "$DOMAIN"
echo "This performs one temporary DNS write: create TXT -> read -> delete -> verify absent."
echo "The test record is automatically removed before the new token is saved."
echo "The API token will be entered securely and will not be displayed."
echo

# Load the same environment as the service without enabling shell tracing.
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

BACKUP="${DB_PATH}.pre-cloudflare-dns-write-test.${STAMP}"
cp -a "$DB_PATH" "$BACKUP"
chmod 600 "$BACKUP" 2>/dev/null || true
echo "Database rollback copy: $BACKUP"
ARMED=1
trap rollback ERR

read -r -s -p "Cloudflare API token with DNS Edit permission: " TOKEN
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
const domain = String(process.env.CF_TEST_DOMAIN || "").trim().toLowerCase().replace(/\.$/, "");
const API = "https://api.cloudflare.com/client/v4";

if (!token) throw new Error("Cloudflare token was empty");
if (!domain || !domain.includes(".")) throw new Error("Cloudflare zone name is invalid");

async function cf(path, options = {}) {
  const response = await fetch(`${API}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(options.body ? { "Content-Type": "application/json" } : {}),
      ...(options.headers || {}),
    },
    signal: AbortSignal.timeout(15000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.success === false) {
    const detail = Array.isArray(body?.errors)
      ? body.errors.map((e) => e?.message).filter(Boolean).join("; ")
      : "";
    const error = new Error(detail || `Cloudflare returned HTTP ${response.status}`);
    error.status = response.status;
    throw error;
  }
  return body;
}

let zoneId = null;
let recordId = null;
let recordName = null;
let cleanupVerified = false;
let writeVerified = false;

async function lookupRecord() {
  const q = new URLSearchParams({ type: "TXT", name: recordName, per_page: "100" });
  const result = await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records?${q}`);
  return Array.isArray(result.result) ? result.result : [];
}

async function cleanupRecord() {
  if (!recordId) return;
  try {
    await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records/${encodeURIComponent(recordId)}`, { method: "DELETE" });
    recordId = null;
  } catch (error) {
    console.error(`WRITE TEST CLEANUP ERROR: could not delete temporary record ${recordName}: ${error.message}`);
    throw error;
  }
}

try {
  const verification = await cf("/user/tokens/verify");
  if (String(verification?.result?.status || "").toLowerCase() !== "active") {
    throw new Error("Cloudflare token is not active");
  }

  const zoneQuery = new URLSearchParams({ name: domain, status: "active", per_page: "20" });
  const zones = await cf(`/zones?${zoneQuery}`);
  const zone = (zones.result || []).find((z) => String(z?.name || "").toLowerCase() === domain);
  if (!zone?.id) throw new Error(`Zone ${domain} was not found or is outside the token scope`);
  zoneId = zone.id;

  const nonce = `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
  recordName = `_vodia-mcp-write-test-${nonce}.${domain}`;
  const content = `vodia-mcp-write-test-${nonce}`;

  const created = await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records`, {
    method: "POST",
    body: JSON.stringify({
      type: "TXT",
      name: recordName,
      content,
      ttl: 120,
    }),
  });
  recordId = created?.result?.id || null;
  if (!recordId) throw new Error("Cloudflare create call did not return a record ID");

  const found = await lookupRecord();
  if (!found.some((r) => r?.id === recordId && String(r?.name || "").toLowerCase() === recordName.toLowerCase())) {
    throw new Error("Temporary TXT record was not found by an independent read after creation");
  }

  await cleanupRecord();

  let remaining = [];
  for (let attempt = 1; attempt <= 6; attempt++) {
    remaining = await lookupRecord();
    if (remaining.length === 0) break;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (remaining.length !== 0) {
    throw new Error(`Temporary TXT record ${recordName} still appears after deletion`);
  }

  cleanupVerified = true;
  writeVerified = true;

  // Persist the replacement token only after create/read/delete has passed.
  await saveCloudflareIntegration({ domain, apiToken: token });
  const status = getCloudflareIntegrationStatus();
  const checked = await checkSavedCloudflareConnection();
  if (!status?.configured || !checked?.connected) {
    throw new Error("New token passed DNS write testing but the saved integration did not verify as connected");
  }

  console.log(JSON.stringify({
    dnsWriteVerified: true,
    temporaryRecordCreated: true,
    temporaryRecordDeleted: true,
    cleanupVerified,
    recordName,
    provider: "cloudflare",
    configured: Boolean(status.configured),
    connected: Boolean(checked.connected),
    domain: checked.domain || status.domain || domain,
    zoneId: checked.zoneId || status.zoneId || zoneId,
    tokenStatus: checked.tokenStatus || "active",
    credentialStored: Boolean(status.credentialStored),
    changesMade: true,
    note: "Only the temporary TXT record was written and it was deleted before completion. The new encrypted token is now saved server-side.",
  }, null, 2));
} catch (error) {
  if (recordId) {
    try { await cleanupRecord(); }
    catch {}
  }
  console.error(`WRITE TEST FAILED: ${error.message}`);
  if (recordName) console.error(`Temporary record name: ${recordName}`);
  process.exit(1);
}
NODE

chmod 600 "$TMP_JS"

echo
printf '%s' "$TOKEN" | CF_TEST_DOMAIN="$DOMAIN" DB_PATH="$DB_PATH" node --no-warnings "$TMP_JS"
TOKEN=""

# Preserve expected database ownership/mode after a successful save.
if id vodiamcp >/dev/null 2>&1; then
  chown vodiamcp:vodiamcp "$DB_PATH"
  chmod 600 "$DB_PATH"
fi

# Final non-secret verification of the saved row.
echo
echo "Verifying saved integration row..."
python3 - "$DB_PATH" "$DOMAIN" <<'PY'
import json, sqlite3, sys
path, expected = sys.argv[1], sys.argv[2]
con = sqlite3.connect(path)
try:
    row = con.execute("SELECT config_json, length(secret_blob), updated_at FROM integrations WHERE provider='cloudflare'").fetchone()
finally:
    con.close()
if not row:
    raise SystemExit("VERIFY FAIL: cloudflare integration row missing")
cfg = json.loads(row[0] or "{}")
actual = str(cfg.get("domain") or "").lower()
if actual != expected.lower():
    raise SystemExit(f"VERIFY FAIL: saved zone is {actual!r}, expected {expected!r}")
if not row[1]:
    raise SystemExit("VERIFY FAIL: encrypted credential blob missing")
print(json.dumps({
    "cloudflareRowFound": True,
    "domain": actual,
    "zoneIdPresent": bool(cfg.get("zoneId")),
    "credentialBlobPresent": True,
    "updatedAt": row[2],
}, indent=2))
PY

ARMED=0
trap - ERR

echo
echo "PASS: Cloudflare DNS write permission is verified for $DOMAIN"
echo "PASS: temporary TXT record was removed"
echo "PASS: replacement token is stored encrypted in $DB_PATH"
echo "Rollback copy retained at: $BACKUP"
echo "No Vodia tenant was created by this script."
echo "Next step: use the MCP approval flow to plan and create the test tenant + DNS A record."
