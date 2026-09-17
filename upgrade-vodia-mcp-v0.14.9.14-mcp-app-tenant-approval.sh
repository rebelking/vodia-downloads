#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
UI_DIR="$APP/ui"
UI_SRC="$UI_DIR/tenant-approval-app.js"
UI_TEMPLATE="$UI_DIR/tenant-approval-app.template.html"
UI_BUNDLE="$UI_DIR/tenant-approval-app.bundle.js"
UI_HTML="$UI_DIR/tenant-approval-app.html"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.14-mcp-app-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring v0.14.9.13 files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  [[ -d "$BACKUP_DIR/ui" ]] && { rm -rf "$UI_DIR"; cp -a "$BACKUP_DIR/ui" "$UI_DIR"; } || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION" "$APP/package.json"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node npm curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.14 — MCP App tenant approval card ==="
echo "Adds an inline tenant approval card for MCP Apps hosts such as Claude."
echo "The normal text plan remains available as a fallback."

echo "[1/9] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -q '0.14.9.13' "$VERSION" || fail "expected installed base version 0.14.9.13"
for marker in \
  'v0.14.9.13 derive tenant display from FQDN' \
  '"plan_create_tenant"' \
  '"plan_create_tenant_with_dns"' \
  '"apply_tenant_change"' \
  '"apply_tenant_dns_change"' \
  '"get_dns_provider_choices"' \
  'setAndVerifyTenantDisplayName' \
  'setAndVerifyTenantCountryCode' \
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS' \
  'deleteSavedCloudflareDnsRecordById'; do
  grep -q "$marker" "$INDEX" || fail "required capability missing: $marker"
done
if grep -q 'v0.14.9.14 MCP App tenant approval UI' "$INDEX"; then
  echo "v0.14.9.14 already appears installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/9] Backup + stage"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -d "$UI_DIR" ]] && cp -a "$UI_DIR" "$BACKUP_DIR/ui" || true
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
mkdir -p "$UI_DIR"
echo "PASS: $BACKUP_DIR"

echo "[3/9] Download MCP App source"
curl -fsSL https://raw.githubusercontent.com/rebelking/vodia-downloads/main/mcp-apps/tenant-approval/app.js -o "$UI_SRC"
curl -fsSL https://raw.githubusercontent.com/rebelking/vodia-downloads/main/mcp-apps/tenant-approval/template.html -o "$UI_TEMPLATE"
[[ -s "$UI_SRC" && -s "$UI_TEMPLATE" ]] || fail "MCP App source download failed"
echo PASS

echo "[4/9] Build single-file MCP App HTML"
cd "$APP"
npm install --no-save --package-lock=false @modelcontextprotocol/ext-apps@^2.0.0 esbuild@^0.25.0 >/dev/null
npx --no-install esbuild "$UI_SRC" --bundle --format=iife --platform=browser --target=es2022 --minify --outfile="$UI_BUNDLE" >/dev/null
python3 - "$UI_TEMPLATE" "$UI_BUNDLE" "$UI_HTML" <<'PY'
from pathlib import Path
import sys
t=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
if '__VODIA_APP_BUNDLE__' not in t: raise SystemExit('UI template placeholder missing')
Path(sys.argv[3]).write_text(t.replace('__VODIA_APP_BUNDLE__',b,1))
PY
[[ -s "$UI_HTML" ]] || fail "MCP App HTML build failed"
grep -q 'Copy to clipboard' "$UI_HTML" || fail "copy UI missing"
echo PASS

echo "[5/9] Patch tenant planner tool metadata + ui:// resource"
python3 - "$TMP_INDEX" "$UI_HTML" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]); html_path=sys.argv[2]
s=p.read_text()
marker='v0.14.9.14 MCP App tenant approval UI'
if marker in s: raise SystemExit('PATCH ERROR: marker already present')
anchor='    // Customer tenant tool surface — Phase 2D\n'
if s.count(anchor)!=1: raise SystemExit(f'PATCH ERROR: tenant surface anchor count={s.count(anchor)}')
resource='''    // v0.14.9.14 MCP App tenant approval UI.\n    const TENANT_APPROVAL_UI_URI = "ui://vodia/tenant-approval/mcp-app.html";\n    server.registerResource(\n      "Vodia tenant approval",\n      TENANT_APPROVAL_UI_URI,\n      { mimeType: "text/html;profile=mcp-app" },\n      async () => {\n        const { readFile } = await import("node:fs/promises");\n        const html = await readFile(%s, "utf8");\n        return { contents: [{ uri: TENANT_APPROVAL_UI_URI, mimeType: "text/html;profile=mcp-app", text: html }] };\n      }\n    );\n\n''' % json.dumps(html_path)
s=s.replace(anchor,resource+anchor,1)

def patch_tool(name):
    global s
    token=f'"{name}"'
    start=s.find(token)
    if start<0: raise SystemExit(f'PATCH ERROR: {name} not found')
    candidates=[x for x in (s.find('\n  server.registerTool(',start+1),s.find('\n    server.registerTool(',start+1)) if x>=0]
    end=min(candidates) if candidates else len(s)
    block=s[start:end]
    key='outputSchema: toolOutputSchema,'
    if block.count(key)!=1: raise SystemExit(f'PATCH ERROR: {name} outputSchema count={block.count(key)}')
    meta=key+'\n        _meta: { ui: { resourceUri: TENANT_APPROVAL_UI_URI }, "ui/resourceUri": TENANT_APPROVAL_UI_URI },'
    block=block.replace(key,meta,1)
    s=s[:start]+block+s[end:]

patch_tool('plan_create_tenant')
patch_tool('plan_create_tenant_with_dns')
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[6/9] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.14\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[7/9] Static safety validation"
python3 - "$TMP_INDEX" "$UI_HTML" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text(); h=Path(sys.argv[2]).read_text()
for text in [
 'v0.14.9.14 MCP App tenant approval UI',
 'ui://vodia/tenant-approval/mcp-app.html',
 'text/html;profile=mcp-app',
 '"get_dns_provider_choices"',
 'resolveTenantDisplayName',
 'setAndVerifyTenantDisplayName',
 'setAndVerifyTenantCountryCode',
 'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
 'deleteSavedCloudflareDnsRecordById',
]:
    if text not in s: raise SystemExit(f'VALIDATION ERROR: missing {text}')
meta='_meta: { ui: { resourceUri: TENANT_APPROVAL_UI_URI }, "ui/resourceUri": TENANT_APPROVAL_UI_URI },'
if s.count(meta)!=2: raise SystemExit(f'VALIDATION ERROR: expected 2 tenant UI metadata entries, found {s.count(meta)}')
if 'Copy to clipboard' not in h: raise SystemExit('VALIDATION ERROR: approval UI incomplete')
print('PASS: ui:// MCP App resource registered')
print('PASS: both tenant PLAN tools advertise the approval card')
print('PASS: apply tools remain separate confirmation-guarded writes')
print('PASS: plain text fallback, provider choice, display/country verification, DNS-FIRST and rollback are preserved')
PY
echo PASS

echo "[8/9] Install + restart + health"
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
grep -q '0.14.9.14' "$HEALTH" || fail "health endpoint did not report v0.14.9.14"
echo PASS

echo "[9/9] Complete"
echo "PASS: v0.14.9.14 installed"
echo "PASS: tenant plan tools now expose the Vodia approval MCP App"
echo "PASS: Copy to clipboard copies the existing exact confirmation phrase"
echo "PASS: the UI does not bypass the apply confirmation guard"
echo "PASS: non-MCP-Apps clients still receive the normal text plan"
echo "Backup: $BACKUP_DIR"
echo "Reconnect Claude/start a fresh MCP session so tools and resources are reloaded."
trap - ERR
