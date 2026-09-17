#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.15-ui-first-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring v0.14.9.14 files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.15 — UI-first tenant plan response ==="
echo "Keeps the MCP App approval card as the primary tenant-plan presentation and asks UI-capable hosts not to duplicate the card contents in prose."
echo "Plain-text fallback remains available when the MCP App is not rendered."

echo "[1/7] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -q '0.14.9.14' "$VERSION" || fail "expected installed base version 0.14.9.14"
for marker in \
  'v0.14.9.14 MCP App tenant approval UI' \
  'ui://vodia/tenant-approval/mcp-app.html' \
  '"plan_create_tenant"' \
  '"plan_create_tenant_with_dns"' \
  '"apply_tenant_change"' \
  '"apply_tenant_dns_change"' \
  'Present a short customer-facing summary of the tenant and DNS change plus requiredConfirmation.'; do
  grep -q "$marker" "$INDEX" || fail "required capability/anchor missing: $marker"
done
if grep -q 'v0.14.9.15 UI-first tenant plan presentation' "$INDEX"; then
  echo "v0.14.9.15 already appears installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/7] Backup + stage"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"

echo "[3/7] Patch UI-first response guidance"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='v0.14.9.15 UI-first tenant plan presentation'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.15 marker already present')

old='Present a short customer-facing summary of the tenant and DNS change plus requiredConfirmation. '
new=(
  'For tenant PLAN tools that expose the Vodia MCP App approval card, treat the card as the primary user-facing presentation. '
  'When the host renders the MCP App, do not repeat the tenant plan table, tenant FQDN, DNS provider, country code, display name, risk, Plan ID, expiry, or exact confirmation phrase in assistant prose below the card; respond only with a minimal status such as "Plan ready — use the approval card above." '
  'When the host does not render the MCP App, present the normal short customer-facing tenant/DNS summary and requiredConfirmation as the fallback. '
)
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: admin instruction anchor count={s.count(old)}')
s=s.replace(old,new,1)

# Strengthen both planner descriptions so model hosts get the same UI-first cue at tool selection time.
for name in ('plan_create_tenant','plan_create_tenant_with_dns'):
    token=f'"{name}"'
    start=s.find(token)
    if start < 0:
        raise SystemExit(f'PATCH ERROR: {name} not found')
    # Locate this tool block only.
    candidates=[x for x in (s.find('\n  server.registerTool(',start+1),s.find('\n    server.registerTool(',start+1)) if x>=0]
    end=min(candidates) if candidates else len(s)
    block=s[start:end]
    desc_marker='description: "'
    dpos=block.find(desc_marker)
    if dpos < 0:
        raise SystemExit(f'PATCH ERROR: {name} description not found')
    qstart=dpos+len(desc_marker)
    qend=block.find('",',qstart)
    if qend < 0:
        raise SystemExit(f'PATCH ERROR: {name} description terminator not found')
    desc=block[qstart:qend]
    suffix=' When the MCP App approval card is rendered, do not repeat the card contents or exact confirmation phrase in prose below it; use only a minimal status line. Keep the normal text summary only as a fallback for clients that do not render MCP Apps.'
    if suffix.strip() not in desc:
        desc += suffix
    block=block[:qstart]+desc+block[qend:]
    s=s[:start]+block+s[end:]

# Marker near the server instructions for idempotence and easy inspection.
anchor='const server = new McpServer('
if s.count(anchor) != 1:
    raise SystemExit(f'PATCH ERROR: server anchor count={s.count(anchor)}')
s=s.replace(anchor,'// v0.14.9.15 UI-first tenant plan presentation\n'+anchor,1)
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/7] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.15\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/7] Static safety validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
required=[
 'v0.14.9.15 UI-first tenant plan presentation',
 'ui://vodia/tenant-approval/mcp-app.html',
 'text/html;profile=mcp-app',
 '"plan_create_tenant"',
 '"plan_create_tenant_with_dns"',
 '"apply_tenant_change"',
 '"apply_tenant_dns_change"',
 'When the host renders the MCP App, do not repeat the tenant plan table',
 'When the host does not render the MCP App, present the normal short customer-facing tenant/DNS summary and requiredConfirmation as the fallback.',
 'When the MCP App approval card is rendered, do not repeat the card contents or exact confirmation phrase in prose below it',
 'setAndVerifyTenantDisplayName',
 'setAndVerifyTenantCountryCode',
 'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
 'deleteSavedCloudflareDnsRecordById',
]
for text in required:
    if text not in s:
        raise SystemExit(f'VALIDATION ERROR: missing {text}')
if s.count('_meta: { ui: { resourceUri: TENANT_APPROVAL_UI_URI }, "ui/resourceUri": TENANT_APPROVAL_UI_URI },') != 2:
    raise SystemExit('VALIDATION ERROR: tenant approval UI metadata count changed')
print('PASS: MCP App card remains attached to both tenant planners')
print('PASS: UI-capable hosts are instructed not to duplicate card contents in prose')
print('PASS: text fallback remains explicitly preserved for non-UI clients')
print('PASS: apply confirmation guards and tenant/DNS safety logic remain untouched')
PY
echo PASS

echo "[6/7] Install + restart + health"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
node --check "$INDEX" >/dev/null
node --check "$VERSION" >/dev/null
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.15' "$HEALTH" || fail "health endpoint did not report v0.14.9.15"
echo PASS

echo "[7/7] Complete"
echo "PASS: v0.14.9.15 installed"
echo "PASS: Claude/MCP Apps hosts are instructed to show the approval card without duplicating its details underneath"
echo "PASS: a minimal status line is allowed after the card"
echo "PASS: non-MCP-Apps clients retain the text fallback"
echo "PASS: Copy to clipboard and exact apply confirmation remain unchanged"
echo "Backup: $BACKUP_DIR"
echo "Reconnect Claude/start a fresh MCP session so updated server instructions and tool descriptions are loaded."
trap - ERR
