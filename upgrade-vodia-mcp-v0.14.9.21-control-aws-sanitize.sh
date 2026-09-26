#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
CONTROL_SERVICE="vodia-control-api"
CONTROL_API="$APP/control-center-api-v1.js"
WEB_DIR="$APP/control-center-v2"
SOURCE_REF="${VODIA_MCP_CONTROL_CENTER_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_ROOT="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.21-control-aws-sanitize-$STAMP"
TMP_VERSION="$(mktemp --suffix=.js)"
TMP_API="$(mktemp --suffix=.js)"
TMP_APP="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
CONNECTIONS="$(mktemp)"
PBX="$(mktemp)"
trap 'rm -f "$TMP_VERSION" "$TMP_API" "$TMP_APP" "$HEALTH" "$CONNECTIONS" "$PBX"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
[[ -f "$VERSION" ]] || fail "missing $VERSION"
[[ -f "$CONTROL_API" ]] || fail "missing $CONTROL_API"
[[ -f "$WEB_DIR/app.js" ]] || fail "missing $WEB_DIR/app.js"
grep -q '0.14.9.20' "$VERSION" || fail "expected installed base v0.14.9.20"
systemctl is-enabled --quiet "$CONTROL_SERVICE" || fail "$CONTROL_SERVICE is not enabled"

echo "=== Vodia MCP v0.14.9.21 — AWS guided manage + browser payload hardening ==="
echo "Keeps raw AWS/PBX internals out of the customer browser and makes AWS Connect/Manage use the live saved-profile overview."

echo "[1/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$CONTROL_API" "$BACKUP_DIR/control-center-api-v1.js"
cp -a "$WEB_DIR/app.js" "$BACKUP_DIR/app.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.21 files..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/control-center-api-v1.js" "$CONTROL_API" || true
  cp -a "$BACKUP_DIR/app.js" "$WEB_DIR/app.js" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  exit "$rc"
}

echo "[2/8] Download patched API/frontend"
curl -fsSL "$SOURCE_ROOT/control-center-api-v1.js" -o "$TMP_API"
curl -fsSL "$SOURCE_ROOT/control-center-v2/app.js" -o "$TMP_APP"
node --check "$TMP_API" >/dev/null || fail "control API syntax invalid"
node --check "$TMP_APP" >/dev/null || fail "frontend JS syntax invalid"
grep -q 'sanitizeProviderData' "$TMP_API" || fail "browser payload sanitizer missing"
grep -q '/control-api/aws/overview' "$TMP_API" || fail "AWS overview endpoint missing"
grep -q 'aws-copy-setup' "$TMP_APP" || fail "AWS guided setup flow missing"
grep -q 'aws-copy-deploy' "$TMP_APP" || fail "AWS guided deployment handoff missing"
echo PASS

echo "[3/8] Static privacy validation"
python3 - "$TMP_API" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
required=[
  'sanitizeProviderData',
  'externalIdConfigured',
  'totalCalls',
  'extensionCdrs',
  'trunkCdrs',
  '"/control-api/aws/overview"',
]
for x in required:
    if x not in s:
        raise SystemExit(f'VALIDATION ERROR: missing {x}')
# Browser-facing PBX sanitizer must not intentionally emit interface/network fields.
pbx=s.split('if (provider === "pbx") {',1)[1].split('}',1)[0]
for forbidden in ['mac:', 'dns_servers', 'pbx_server_ip', 'pbx_server_ip6', 'cwd:']:
    if forbidden in pbx:
        raise SystemExit(f'VALIDATION ERROR: PBX browser sanitizer exposes {forbidden}')
print('PASS: PBX customer payload limited to health/version/call counters')
print('PASS: AWS profile sanitizer does not return Role ARN or External ID')
PY
echo PASS

echo "[4/8] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.21\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[5/8] Install"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_API" "$CONTROL_API"
install -o root -g root -m 0644 "$TMP_APP" "$WEB_DIR/app.js"
cp -a "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE"
echo PASS

echo "[6/8] Health"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null && curl -fsS http://127.0.0.1:3110/control-api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.21' "$HEALTH" || fail "health did not report v0.14.9.21"
systemctl is-active --quiet "$CONTROL_SERVICE" || fail "$CONTROL_SERVICE is not active"
echo PASS

echo "[7/8] Live privacy + AWS overview validation"
curl -fsS http://127.0.0.1:3110/control-api/connections > "$CONNECTIONS"
curl -fsS http://127.0.0.1:3110/control-api/pbx > "$PBX"
for f in "$CONNECTIONS" "$PBX"; do
  if grep -Eqi '"(mac|dns_servers|pbx_server_ip|pbx_server_ip6|cwd|roleArn|externalId|clientSecret|token)"[[:space:]]*:' "$f"; then
    echo "Unsafe browser payload:"
    cat "$f"
    fail "sensitive/internal field found in browser response"
  fi
done
AWS="$(curl -fsS http://127.0.0.1:3110/control-api/aws/overview)"
echo "$AWS" | grep -q '"configured"' || fail "AWS overview endpoint did not return configured state"
echo "PASS: browser payload excludes PBX network internals and AWS Role ARN/External ID"
echo "AWS overview:"
echo "$AWS" | python3 -m json.tool | sed -n '1,120p'

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.21 installed"
echo "PASS: AWS Connect/Manage now loads live saved-profile/Marketplace/region status"
echo "PASS: if AWS is not configured, the UI offers the one-time secure MCP setup command without raw fields"
echo "PASS: Deploy PBX hands off to the existing guarded Marketplace/DryRun workflow"
echo "PASS: PBX browser data is sanitized to version/build/status/call counters"
echo "Backup: $BACKUP_DIR"
trap - ERR
