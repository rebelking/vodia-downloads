#!/usr/bin/env bash
# Diagnose Vodia MCP Cloudflare integration storage without exposing secrets.
# Read-only: does not modify Vodia MCP, Cloudflare, or the database.

set -Eeuo pipefail

APP="/opt/vodia-mcp"
SERVICE="vodia-mcp"
CF="$APP/cloudflare-integration.js"
DEFAULT_DB="/var/lib/vodia-mcp/auth.db"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"
[[ -f "$CF" ]] || fail "Missing $CF"

printf '%s\n' "=== Vodia MCP Cloudflare configuration diagnostic v1 ==="
echo "READ ONLY: this script does not print Cloudflare tokens or SESSION_SECRET values."
echo

printf '%s\n' "[1/6] Service status"
printf 'vodia-mcp active: '
systemctl is-active "$SERVICE" || true
printf 'WorkingDirectory: '
systemctl show "$SERVICE" -p WorkingDirectory --value || true

echo
printf '%s\n' "[2/6] Resolve DB_PATH used by Cloudflare integration"
DB_PATH_RESOLVED=""
DB_SOURCE="default"

# Look for an explicit DB_PATH in systemd unit/drop-ins without printing other env values.
INLINE_DB_LINE="$(systemctl cat "$SERVICE" 2>/dev/null | grep -E '^[[:space:]]*Environment=.*DB_PATH=' | tail -1 || true)"
if [[ -n "$INLINE_DB_LINE" ]]; then
  DB_PATH_RESOLVED="$(printf '%s\n' "$INLINE_DB_LINE" | sed -nE 's/.*DB_PATH=([^"[:space:]]+).*/\1/p')"
  if [[ -z "$DB_PATH_RESOLVED" ]]; then
    DB_PATH_RESOLVED="$(printf '%s\n' "$INLINE_DB_LINE" | sed -nE 's/.*DB_PATH=\"([^\"]+)\".*/\1/p')"
  fi
  [[ -n "$DB_PATH_RESOLVED" ]] && DB_SOURCE="systemd Environment=DB_PATH"
fi

# If no inline DB_PATH was found, inspect only DB_PATH= from configured EnvironmentFile(s).
if [[ -z "$DB_PATH_RESOLVED" ]]; then
  ENV_FILES_RAW="$(systemctl show "$SERVICE" -p EnvironmentFiles --value 2>/dev/null || true)"
  while read -r token; do
    token="${token#-}"
    token="${token#\"}"
    token="${token%\"}"
    [[ "$token" == /* ]] || continue
    [[ -f "$token" ]] || continue
    value="$(grep -E '^[[:space:]]*DB_PATH=' "$token" | tail -1 | cut -d= -f2- || true)"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    if [[ -n "$value" ]]; then
      DB_PATH_RESOLVED="$value"
      DB_SOURCE="EnvironmentFile:$token"
      break
    fi
  done < <(printf '%s\n' "$ENV_FILES_RAW" | tr ' ' '\n')
fi

if [[ -z "$DB_PATH_RESOLVED" ]]; then
  DB_PATH_RESOLVED="$DEFAULT_DB"
fi

printf 'Cloudflare DB_PATH: %s\n' "$DB_PATH_RESOLVED"
printf 'DB_PATH source: %s\n' "$DB_SOURCE"
printf 'Module default: %s\n' "$DEFAULT_DB"

echo
printf '%s\n' "[3/6] Database file"
if [[ -e "$DB_PATH_RESOLVED" ]]; then
  stat -c 'exists: yes | owner=%U:%G | mode=%a | size=%s bytes | modified=%y' "$DB_PATH_RESOLVED"
else
  echo "exists: NO"
fi

echo
printf '%s\n' "[4/6] Inspect Cloudflare integration row (no secret values)"
DB_PATH="$DB_PATH_RESOLVED" node --input-type=module <<'NODE'
import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';

const path = process.env.DB_PATH;
if (!existsSync(path)) {
  console.log(JSON.stringify({ databaseExists: false, cloudflareRowFound: false }, null, 2));
  process.exit(0);
}

const db = new DatabaseSync(path, { readOnly: true });
const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='integrations'").get();
if (!table) {
  console.log(JSON.stringify({ databaseExists: true, integrationsTableExists: false, cloudflareRowFound: false }, null, 2));
  db.close();
  process.exit(0);
}
const row = db.prepare("SELECT provider, display_name, config_json, created_at, updated_at, length(secret_blob) AS secret_blob_length FROM integrations WHERE provider='cloudflare'").get();
db.close();
if (!row) {
  console.log(JSON.stringify({ databaseExists: true, integrationsTableExists: true, cloudflareRowFound: false }, null, 2));
  process.exit(0);
}
let config = {};
try { config = JSON.parse(row.config_json || '{}'); } catch {}
console.log(JSON.stringify({
  databaseExists: true,
  integrationsTableExists: true,
  cloudflareRowFound: true,
  provider: row.provider,
  displayName: row.display_name,
  domain: config.domain || null,
  zoneIdPresent: Boolean(config.zoneId),
  accountName: config.accountName || null,
  credentialBlobPresent: Number(row.secret_blob_length || 0) > 0,
  createdAt: row.created_at,
  updatedAt: row.updated_at,
}, null, 2));
NODE

echo
printf '%s\n' "[5/6] Ask the installed Cloudflare module for status"
DB_PATH="$DB_PATH_RESOLVED" node --input-type=module <<'NODE'
import { getCloudflareIntegrationStatus } from '/opt/vodia-mcp/cloudflare-integration.js';
try {
  const status = getCloudflareIntegrationStatus();
  // Status does not expose the stored API token.
  console.log(JSON.stringify(status, null, 2));
} catch (error) {
  console.log(JSON.stringify({ statusError: error.message }, null, 2));
}
NODE

echo
printf '%s\n' "[6/6] Compare fallback database if DB_PATH differs"
if [[ "$DB_PATH_RESOLVED" != "$DEFAULT_DB" && -e "$DEFAULT_DB" ]]; then
  DB_PATH="$DEFAULT_DB" node --input-type=module <<'NODE'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.env.DB_PATH, { readOnly: true });
const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='integrations'").get();
if (!table) {
  console.log(JSON.stringify({ fallbackDb: process.env.DB_PATH, integrationsTableExists: false }, null, 2));
} else {
  const row = db.prepare("SELECT config_json, length(secret_blob) AS secret_blob_length FROM integrations WHERE provider='cloudflare'").get();
  let cfg = {};
  if (row) { try { cfg = JSON.parse(row.config_json || '{}'); } catch {} }
  console.log(JSON.stringify({
    fallbackDb: process.env.DB_PATH,
    cloudflareRowFound: Boolean(row),
    domain: cfg.domain || null,
    credentialBlobPresent: Boolean(row && Number(row.secret_blob_length || 0) > 0),
  }, null, 2));
}
db.close();
NODE
else
  echo "No different fallback database to compare."
fi

echo
echo "Diagnostic complete. No changes were made."
