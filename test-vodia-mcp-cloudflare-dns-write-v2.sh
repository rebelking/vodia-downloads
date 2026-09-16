#!/usr/bin/env bash
# Vodia MCP Cloudflare DNS write permission smoke test v2
#
# Default mode uses the Cloudflare token already encrypted in auth.db. This lets
# an administrator edit the existing token's Cloudflare permissions and test the
# new permission without exposing or re-entering the secret.
#
# Optional replacement mode securely prompts for a NEW token and saves it only
# after the create/read/delete smoke test succeeds.
#
# Live DNS action performed by this script:
#   create unique temporary TXT -> read it -> delete it -> verify it is absent.
# No permanent DNS record is intentionally left behind.
#
# Usage:
#   sudo bash test-vodia-mcp-cloudflare-dns-write-v2.sh
#   sudo bash test-vodia-mcp-cloudflare-dns-write-v2.sh --domain audiomercy.com
#   sudo bash test-vodia-mcp-cloudflare-dns-write-v2.sh --replace-token
#
# Security:
#   - Saved-mode token is decrypted only in process memory using SESSION_SECRET.
#   - Replacement token is entered with terminal echo disabled.
#   - Tokens are never printed, logged, placed on the command line, or written
#     to a plaintext file.

set -Eeuo pipefail

APP="/opt/vodia-mcp"
CF="$APP/cloudflare-integration.js"
ENV_FILE="/etc/vodia-mcp.env"
DEFAULT_DB="/var/lib/vodia-mcp/auth.db"
DOMAIN="audiomercy.com"
MODE="saved"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP_JS="$(mktemp /tmp/vodia-cloudflare-write-test-v2.XXXXXX.mjs)"
TOKEN=""
BACKUP=""
ARMED=0

cleanup(){ TOKEN=""; rm -f "$TMP_JS"; }
trap cleanup EXIT

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
  if (( ARMED )); then restore_db; fi
  cleanup
  exit "$rc"
}

fail(){
  echo "FAIL: $*" >&2
  if (( ARMED )); then restore_db; ARMED=0; fi
  exit 1
}

while (( $# )); do
  case "$1" in
    --domain)
      shift
      [[ -n "${1:-}" ]] || fail "--domain requires a value"
      DOMAIN="$1"
      ;;
    --replace-token)
      MODE="replace"
      ;;
    -h|--help)
      echo "Usage: $0 [--domain example.com] [--replace-token]"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"
[[ -f "$CF" ]] || fail "missing $CF"
[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE"

printf '%s\n' "=== Vodia MCP Cloudflare DNS write permission test v2 ==="
printf 'Zone: %s\n' "$DOMAIN"
printf 'Credential mode: %s\n' "$MODE"
echo "LIVE TEST: creates one temporary TXT record, reads it, deletes it, and verifies deletion."
echo

set +x
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
set +x

DB_PATH="${DB_PATH:-$DEFAULT_DB}"
[[ -n "${SESSION_SECRET:-}" ]] || fail "SESSION_SECRET is not present in $ENV_FILE"
(( ${#SESSION_SECRET} >= 24 )) || fail "SESSION_SECRET is shorter than required"
[[ -f "$DB_PATH" ]] || fail "database does not exist: $DB_PATH"

if [[ "$MODE" == "replace" ]]; then
  BACKUP="${DB_PATH}.pre-cloudflare-dns-write-test-v2.${STAMP}"
  cp -a "$DB_PATH" "$BACKUP"
  chmod 600 "$BACKUP" 2>/dev/null || true
  echo "Database rollback copy: $BACKUP"
  ARMED=1
  trap rollback ERR
  read -r -s -p "New Cloudflare API token with DNS Edit permission: " TOKEN
  echo
  [[ -n "$TOKEN" ]] || fail "no API token entered"
fi

cat > "$TMP_JS" <<'NODE'
import fs from "node:fs";
import { createDecipheriv, createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import {
  saveCloudflareIntegration,
  getCloudflareIntegrationStatus,
  checkSavedCloudflareConnection,
} from "file:///opt/vodia-mcp/cloudflare-integration.js";

const domain = String(process.env.CF_TEST_DOMAIN || "").trim().toLowerCase().replace(/\.$/, "");
const mode = String(process.env.CF_TOKEN_MODE || "saved");
const dbPath = String(process.env.DB_PATH || "/var/lib/vodia-mcp/auth.db");
const sessionSecret = String(process.env.SESSION_SECRET || "");
const API = "https://api.cloudflare.com/client/v4";

if (!domain || !domain.includes(".")) throw new Error("Invalid zone name");
if (sessionSecret.length < 24) throw new Error("SESSION_SECRET is unavailable or too short");

function decryptSavedToken() {
  const db = new DatabaseSync(dbPath, { readOnly: true });
  let row;
  try {
    row = db.prepare("SELECT config_json, secret_blob FROM integrations WHERE provider='cloudflare'").get();
  } finally {
    db.close();
  }
  if (!row?.secret_blob) throw new Error("Saved Cloudflare credential was not found");
  let cfg = {};
  try { cfg = JSON.parse(row.config_json || "{}"); } catch {}
  const savedDomain = String(cfg.domain || "").toLowerCase();
  if (savedDomain && savedDomain !== domain) {
    throw new Error(`Saved Cloudflare zone is ${savedDomain}; requested test zone is ${domain}`);
  }
  const parts = String(row.secret_blob).split(".");
  if (parts.length !== 3) throw new Error("Saved Cloudflare credential blob has an invalid format");
  const [ivText, tagText, cipherText] = parts;
  const key = createHash("sha256").update(`vodia-mcp:integrations:${sessionSecret}`).digest();
  const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(cipherText, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}

let token;
if (mode === "replace") {
  token = fs.readFileSync(0, "utf8").replace(/[\r\n]+$/, "");
  if (!token) throw new Error("Replacement Cloudflare token was empty");
} else {
  token = decryptSavedToken();
}

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
    throw new Error(detail || `Cloudflare returned HTTP ${response.status}`);
  }
  return body;
}

let zoneId = null;
let recordId = null;
let recordName = null;
let deleted = false;

async function lookup() {
  const q = new URLSearchParams({ type: "TXT", name: recordName, per_page: "100" });
  const data = await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records?${q}`);
  return Array.isArray(data.result) ? data.result : [];
}

async function removeTemporaryRecord() {
  if (!recordId) return;
  await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records/${encodeURIComponent(recordId)}`, { method: "DELETE" });
  recordId = null;
  deleted = true;
}

try {
  const verify = await cf("/user/tokens/verify");
  if (String(verify?.result?.status || "").toLowerCase() !== "active") {
    throw new Error("Cloudflare token is not active");
  }

  const zq = new URLSearchParams({ name: domain, status: "active", per_page: "20" });
  const zones = await cf(`/zones?${zq}`);
  const zone = (zones.result || []).find((z) => String(z?.name || "").toLowerCase() === domain);
  if (!zone?.id) throw new Error(`Zone ${domain} was not found or is outside the token scope`);
  zoneId = zone.id;

  const nonce = `${Date.now()}-${Math.random().toString(16).slice(2, 10)}`;
  recordName = `_vodia-mcp-write-test-${nonce}.${domain}`;
  const content = `vodia-mcp-write-test-${nonce}`;

  const created = await cf(`/zones/${encodeURIComponent(zoneId)}/dns_records`, {
    method: "POST",
    body: JSON.stringify({ type: "TXT", name: recordName, content, ttl: 120 }),
  });
  recordId = created?.result?.id || null;
  if (!recordId) throw new Error("Create call succeeded without returning a DNS record ID");

  const found = await lookup();
  if (!found.some((r) => r?.id === recordId)) {
    throw new Error("Temporary TXT record was not found by read-back after creation");
  }

  await removeTemporaryRecord();

  let remaining = [];
  for (let attempt = 1; attempt <= 6; attempt++) {
    remaining = await lookup();
    if (remaining.length === 0) break;
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  if (remaining.length !== 0) throw new Error(`Temporary TXT record ${recordName} still exists after deletion`);

  if (mode === "replace") {
    await saveCloudflareIntegration({ domain, apiToken: token });
    const status = getCloudflareIntegrationStatus();
    const checked = await checkSavedCloudflareConnection();
    if (!status?.configured || !checked?.connected) {
      throw new Error("Replacement token passed write testing but failed saved-integration verification");
    }
  }

  console.log(JSON.stringify({
    dnsWriteVerified: true,
    credentialMode: mode,
    domain,
    zoneId,
    temporaryRecord: recordName,
    createVerified: true,
    readBackVerified: true,
    deleteVerified: true,
    temporaryRecordRemoved: true,
    replacementCredentialSaved: mode === "replace",
    changesMade: true,
  }, null, 2));
} catch (error) {
  if (recordId) {
    try {
      await removeTemporaryRecord();
      console.error(`Cleanup: temporary record ${recordName} was removed after the failed test.`);
    } catch (cleanupError) {
      console.error(`CLEANUP WARNING: temporary record ${recordName} may remain: ${cleanupError.message}`);
    }
  }
  console.error(`WRITE TEST FAILED: ${error.message}`);
  if (recordName) console.error(`Temporary record name: ${recordName}`);
  process.exit(1);
} finally {
  token = "";
}
NODE

chmod 600 "$TMP_JS"

echo "Running Cloudflare create/read/delete test..."
if [[ "$MODE" == "replace" ]]; then
  printf '%s' "$TOKEN" | CF_TEST_DOMAIN="$DOMAIN" CF_TOKEN_MODE="$MODE" DB_PATH="$DB_PATH" SESSION_SECRET="$SESSION_SECRET" node --no-warnings "$TMP_JS"
else
  CF_TEST_DOMAIN="$DOMAIN" CF_TOKEN_MODE="$MODE" DB_PATH="$DB_PATH" SESSION_SECRET="$SESSION_SECRET" node --no-warnings "$TMP_JS" </dev/null
fi
TOKEN=""

if [[ "$MODE" == "replace" ]]; then
  if id vodiamcp >/dev/null 2>&1; then
    chown vodiamcp:vodiamcp "$DB_PATH"
    chmod 600 "$DB_PATH"
  fi
  ARMED=0
  trap - ERR
  echo "PASS: replacement Cloudflare token was stored encrypted after write verification."
  echo "Rollback copy retained at: $BACKUP"
else
  echo "PASS: existing saved Cloudflare credential now has DNS write permission."
fi

echo "PASS: temporary DNS record was created, read back, deleted, and verified absent."
echo "No Vodia tenant was created by this script."
echo "Next step: add approval-gated Cloudflare write tools, then create the test tenant + DNS A record."
