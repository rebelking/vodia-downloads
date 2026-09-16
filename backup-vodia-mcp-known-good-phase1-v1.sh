#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
SERVICE="vodia-mcp"
ENV_FILE="/etc/vodia-mcp.env"
DB="/var/lib/vodia-mcp/auth.db"
BACKUP_ROOT="/opt/vodia-mcp-backups"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="vodia-mcp-known-good-phase1-${STAMP}"
STAGE="$BACKUP_ROOT/.${NAME}.stage"
ARCHIVE="$BACKUP_ROOT/${NAME}.tar.gz"
SHA_FILE="$ARCHIVE.sha256"
WAS_ACTIVE=0
STOPPED=0

fail(){ echo "FAIL: $*" >&2; exit 1; }

restart_if_needed(){
  trap - ERR
  if (( STOPPED )); then
    systemctl restart "$SERVICE" 2>/dev/null || true
    STOPPED=0
  fi
}

rollback(){
  local rc=$?
  restart_if_needed
  rm -rf "$STAGE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"
trap rollback ERR

printf '%s\n' "=== Vodia MCP known-good Phase 1 backup v1 ==="
printf '%s\n' "This captures the working MCP application, encrypted auth/integration DB, service environment, and optional service/proxy config."
printf '%s\n' "Secrets are NOT printed. The backup itself contains sensitive encrypted/configuration data and is created root-only."

echo "[1/8] Preflight"
test -d "$APP" || fail "missing $APP"
test -f "$APP/package.json" || fail "missing $APP/package.json"
test -f "$ENV_FILE" || fail "missing $ENV_FILE"
test -f "$DB" || fail "missing $DB"
mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
rm -rf "$STAGE"
mkdir -p "$STAGE"
chmod 700 "$STAGE"
VERSION="$(node -p "require('$APP/package.json').version" 2>/dev/null || echo unknown)"
if systemctl is-active --quiet "$SERVICE"; then WAS_ACTIVE=1; fi
printf 'MCP version: %s\n' "$VERSION"
printf 'Service active before backup: %s\n' "$WAS_ACTIVE"
echo "PASS"

echo "[2/8] Capture non-secret metadata"
{
  echo "backup_name=$NAME"
  echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "service=$SERVICE"
  echo "mcp_version=$VERSION"
  echo "hostname=$(hostname)"
  echo "app_path=$APP"
  echo "db_path=$DB"
  echo "env_path=$ENV_FILE"
  echo "service_active_before=$WAS_ACTIVE"
} > "$STAGE/MANIFEST.txt"
chmod 600 "$STAGE/MANIFEST.txt"

# Record Cloudflare presence without exposing the credential blob.
node --no-warnings --input-type=module - "$DB" >> "$STAGE/MANIFEST.txt" <<'NODE'
import { DatabaseSync } from 'node:sqlite';
const path = process.argv[2];
const db = new DatabaseSync(path, { readOnly: true });
try {
  const table = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='integrations'").get();
  if (!table) {
    console.log('cloudflare_integration_row=false');
  } else {
    const row = db.prepare("SELECT config_json, length(secret_blob) AS secret_len FROM integrations WHERE provider='cloudflare'").get();
    if (!row) {
      console.log('cloudflare_integration_row=false');
    } else {
      let cfg = {};
      try { cfg = JSON.parse(row.config_json || '{}'); } catch {}
      console.log('cloudflare_integration_row=true');
      console.log(`cloudflare_domain=${cfg.domain || ''}`);
      console.log(`cloudflare_zone_id_present=${Boolean(cfg.zoneId)}`);
      console.log(`cloudflare_credential_blob_present=${Number(row.secret_len || 0) > 0}`);
    }
  }
} finally {
  db.close();
}
NODE

echo "PASS"

echo "[3/8] Briefly stop service for a consistent application/database copy"
if (( WAS_ACTIVE )); then
  systemctl stop "$SERVICE"
  STOPPED=1
fi

mkdir -p "$STAGE/opt" "$STAGE/etc" "$STAGE/var/lib/vodia-mcp"
cp -a "$APP" "$STAGE/opt/vodia-mcp"
cp -a "$ENV_FILE" "$STAGE/etc/vodia-mcp.env"
cp -a "$DB" "$STAGE/var/lib/vodia-mcp/auth.db"

# Optional runtime configuration. Missing files do not fail the backup.
if [[ -f /etc/systemd/system/vodia-mcp.service ]]; then
  mkdir -p "$STAGE/etc/systemd/system"
  cp -a /etc/systemd/system/vodia-mcp.service "$STAGE/etc/systemd/system/"
fi
if [[ -f /lib/systemd/system/vodia-mcp.service ]]; then
  mkdir -p "$STAGE/lib/systemd/system"
  cp -a /lib/systemd/system/vodia-mcp.service "$STAGE/lib/systemd/system/"
fi
if [[ -f /etc/caddy/Caddyfile ]]; then
  mkdir -p "$STAGE/etc/caddy"
  cp -a /etc/caddy/Caddyfile "$STAGE/etc/caddy/Caddyfile"
fi

echo "PASS: consistent files copied"

echo "[4/8] Restart service immediately"
if (( WAS_ACTIVE )); then
  systemctl restart "$SERVICE"
  STOPPED=0
fi

HEALTH="$STAGE/health-after-backup.json"
: > "$HEALTH"
for _ in {1..25}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then
    break
  fi
  sleep 1
done
if (( WAS_ACTIVE )) && [[ ! -s "$HEALTH" ]]; then
  journalctl -u "$SERVICE" -n 80 --no-pager || true
  fail "service did not return healthy after backup"
fi
[[ -s "$HEALTH" ]] && cat "$HEALTH" || true
echo
echo "PASS"

echo "[5/8] Validate copied known-good state"
node --check "$STAGE/opt/vodia-mcp/index.js"
node --check "$STAGE/opt/vodia-mcp/cloudflare-integration.js"
node --no-warnings --input-type=module - "$STAGE/var/lib/vodia-mcp/auth.db" <<'NODE'
import { DatabaseSync } from 'node:sqlite';
const db = new DatabaseSync(process.argv[2], { readOnly: true });
try {
  const row = db.prepare("SELECT config_json, length(secret_blob) AS secret_len FROM integrations WHERE provider='cloudflare'").get();
  if (!row) throw new Error('Cloudflare integration row missing in backup copy');
  const cfg = JSON.parse(row.config_json || '{}');
  if (!cfg.domain) throw new Error('Cloudflare domain missing in backup copy');
  if (!row.secret_len) throw new Error('Cloudflare encrypted credential missing in backup copy');
  console.log(`PASS: Cloudflare backup row present for ${cfg.domain}; encrypted credential present`);
} finally {
  db.close();
}
NODE

echo "PASS"

echo "[6/8] Create root-only archive"
cat > "$STAGE/RESTORE.txt" <<EOF
Vodia MCP known-good Phase 1 backup
Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
MCP version: $VERSION

This archive contains sensitive service configuration and the encrypted authentication/integration database.
Keep it root-only.

Do not restore blindly on a different host.
Recommended restore procedure:
1. Stop vodia-mcp.
2. Back up the current state before restoring.
3. Restore /opt/vodia-mcp, /etc/vodia-mcp.env, and /var/lib/vodia-mcp/auth.db from this archive.
4. Preserve original file ownership/modes.
5. systemctl daemon-reload if the service unit is restored.
6. Restart vodia-mcp.
7. Verify http://127.0.0.1:3100/health.
8. Reconnect an authenticated MCP client and verify Cloudflare Phase 1 reads.
EOF
chmod 600 "$STAGE/RESTORE.txt"

tar -C "$STAGE" -czf "$ARCHIVE" .
chmod 600 "$ARCHIVE"
rm -rf "$STAGE"
echo "PASS: $ARCHIVE"

echo "[7/8] Verify archive and checksum"
tar -tzf "$ARCHIVE" >/dev/null
sha256sum "$ARCHIVE" > "$SHA_FILE"
chmod 600 "$SHA_FILE"
cat "$SHA_FILE"
echo "PASS"

echo "[8/8] Backup complete"
printf 'Archive: %s\n' "$ARCHIVE"
printf 'Checksum: %s\n' "$SHA_FILE"
printf 'Size: '
du -h "$ARCHIVE" | awk '{print $1}'
printf 'Permissions: '
stat -c '%a %U:%G' "$ARCHIVE"
echo "Known-good state captured: Cloudflare Phase 1 working, encrypted integration DB included."
echo "No customer-facing configuration was changed."

trap - ERR
