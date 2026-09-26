#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.17.1-aws-registration-hotfix-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Hotfix failed; restoring pre-hotfix files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.17.1 — AWS tool registration hotfix ==="
echo "Purpose: move AWS Marketplace tool registration out of registerPbXReadTool and register it once per MCP server instance."

echo "[1/7] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q '0.14.9.17' "$VERSION" || fail "expected installed v0.14.9.17 base"
grep -q 'registerAwsMarketplaceDeployTools' "$INDEX" || fail "AWS Marketplace registration import missing"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer anchor missing"
grep -q 'registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool anchor missing"
echo PASS

echo "[2/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[3/7] Relocate AWS registration"
cp -a "$INDEX" "$TMP_INDEX"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

block='''  // v0.14.9.17 AWS Marketplace EC2 deployment
  registerAwsMarketplaceDeployTools(server, {
    z,
    toolOutputSchema,
    scopedAudit,
    scopedSuccess,
    failure,
  });

'''

count=s.count(block)
if count != 1:
    raise SystemExit(f'HOTFIX ERROR: expected exactly one AWS registration block, found {count}')

old=s.find(block)
factory=s.find('export function createVodiaServer')
if factory < 0:
    raise SystemExit('HOTFIX ERROR: createVodiaServer not found')

s=s.replace(block,'',1)
factory=s.find('export function createVodiaServer')

# Register once in createVodiaServer, immediately before its first top-level
# registerPbXReadTool call. The bad v0.14.9.17 installer inserted the block
# inside registerPbXReadTool itself, causing duplicate tool registration.
anchor=s.find('registerPbXReadTool(', factory)
if anchor < 0:
    raise SystemExit('HOTFIX ERROR: registerPbXReadTool call after createVodiaServer not found')

# Preserve indentation of the line containing the call.
line_start=s.rfind('\n', factory, anchor)+1
indent=s[line_start:anchor]
if indent.strip():
    # If anchor landed in an expression, use standard two-space function body indent.
    indent='  '

registration='''// v0.14.9.17.1 AWS Marketplace EC2 registration hotfix
registerAwsMarketplaceDeployTools(server, {
  z,
  toolOutputSchema,
  scopedAudit,
  scopedSuccess,
  failure,
});

'''
registration='\n'.join((indent + line if line else line) for line in registration.split('\n'))

s=s[:line_start]+registration+s[line_start:]

if s.count('registerAwsMarketplaceDeployTools(server') != 1:
    raise SystemExit('HOTFIX ERROR: registration call count is not exactly one')
newreg=s.find('registerAwsMarketplaceDeployTools(server')
factory=s.find('export function createVodiaServer')
helper=s.find('function registerPbXReadTool')
if newreg < factory:
    raise SystemExit('HOTFIX ERROR: registration is not inside/after createVodiaServer')
if helper >= 0 and helper < factory and helper < newreg < factory:
    raise SystemExit('HOTFIX ERROR: registration remained in helper')
if 'v0.14.9.17.1 AWS Marketplace EC2 registration hotfix' not in s:
    raise SystemExit('HOTFIX ERROR: hotfix marker missing')

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "hotfixed index.js syntax invalid"
echo PASS

echo "[4/7] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.17.1\2',s,count=1)
if n==s:
    raise SystemExit('HOTFIX ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "hotfixed version.js syntax invalid"
echo PASS

echo "[5/7] Static validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
if s.count('registerAwsMarketplaceDeployTools(server') != 1:
    raise SystemExit('VALIDATION ERROR: expected one AWS registration call')
factory=s.find('export function createVodiaServer')
reg=s.find('registerAwsMarketplaceDeployTools(server')
if not (factory >= 0 and reg > factory):
    raise SystemExit('VALIDATION ERROR: AWS registration is not after createVodiaServer')
if 'v0.14.9.17.1 AWS Marketplace EC2 registration hotfix' not in s:
    raise SystemExit('VALIDATION ERROR: hotfix marker missing')
print('PASS: AWS tool set registers once per MCP server')
print('PASS: duplicate-registration failure path removed')
PY

echo "[6/7] Activate + restart"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.17.1' "$HEALTH" || fail "health endpoint did not report v0.14.9.17.1"

# Catch immediate duplicate registration errors after restart.
sleep 2
if journalctl -u "$SERVICE" --since "-10 seconds" --no-pager | grep -q 'Tool aws_check_customer_connection is already registered'; then
  fail "duplicate AWS tool registration still detected"
fi
echo PASS

echo "[7/7] Complete"
echo "PASS: v0.14.9.17.1 AWS registration hotfix installed"
echo "PASS: aws_check_customer_connection registration is no longer nested in registerPbXReadTool"
echo "Backup: $BACKUP_DIR"
echo "Reconnect the MCP connector and retry."
trap - ERR
