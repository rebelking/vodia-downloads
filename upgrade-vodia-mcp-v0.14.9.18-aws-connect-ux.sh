#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
MODULE="$APP/aws-marketplace-ec2-deploy-v1.js"
PROFILE_MODULE="$APP/aws-connection-profile-v1.js"
SERVICE="vodia-mcp"
UI_DIR="$APP/ui"
UI_SRC="$UI_DIR/aws-connect-app.js"
UI_TEMPLATE="$UI_DIR/aws-connect-app.template.html"
UI_BUNDLE="$UI_DIR/aws-connect-app.bundle.js"
UI_HTML="$UI_DIR/aws-connect-app.html"
STATE_DIR="${VODIA_MCP_AWS_CONNECTION_STATE_DIR:-/var/lib/vodia-mcp}"
SOURCE_REF="${VODIA_MCP_AWS_CONNECT_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.18-aws-connect-ux-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
TMP_MODULE="$(mktemp --suffix=.js)"
TMP_PROFILE="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$TMP_MODULE" "$TMP_PROFILE" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.18 files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  [[ -f "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" ]] && cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$MODULE" || true
  if [[ -f "$BACKUP_DIR/aws-connection-profile-v1.js" ]]; then
    cp -a "$BACKUP_DIR/aws-connection-profile-v1.js" "$PROFILE_MODULE"
  else
    rm -f "$PROFILE_MODULE"
  fi
  [[ -d "$BACKUP_DIR/ui" ]] && { rm -rf "$UI_DIR"; cp -a "$BACKUP_DIR/ui" "$UI_DIR"; } || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION" "$MODULE" "$APP/package.json"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node npm curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.18 — AWS Connect UX + saved connection profile ==="
echo "Adds a Connect AWS Account MCP App, STS Test & Save, encrypted-at-rest connection profile, and saved-profile reuse by AWS tools."

echo "[1/10] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -Eq '0\.14\.9\.17(\.1)?' "$VERSION" || fail "expected installed base v0.14.9.17 or v0.14.9.17.1"
grep -q 'registerAwsMarketplaceDeployTools' "$INDEX" || fail "AWS Marketplace registration missing"
if grep -q '0.14.9.18' "$VERSION"; then
  echo "v0.14.9.18 already appears installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/10] Backup + stage"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$MODULE" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
[[ -f "$PROFILE_MODULE" ]] && cp -a "$PROFILE_MODULE" "$BACKUP_DIR/aws-connection-profile-v1.js" || true
[[ -d "$UI_DIR" ]] && cp -a "$UI_DIR" "$BACKUP_DIR/ui" || true
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
mkdir -p "$UI_DIR"
echo "PASS: $BACKUP_DIR"

echo "[3/10] Ensure AWS tool registration is single-shot"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
call='registerAwsMarketplaceDeployTools(server'
if s.count(call) != 1:
    raise SystemExit(f'PATCH ERROR: expected exactly one AWS registration call, found {s.count(call)}')

# v0.14.9.17 inserted the call inside registerPbXReadTool. If so, relocate it
# into createVodiaServer before the first registerPbXReadTool(...) invocation.
bad='''  // v0.14.9.17 AWS Marketplace EC2 deployment
  registerAwsMarketplaceDeployTools(server, {
    z,
    toolOutputSchema,
    scopedAudit,
    scopedSuccess,
    failure,
  });

'''
if bad in s:
    s=s.replace(bad,'',1)
    factory=s.find('export function createVodiaServer')
    if factory < 0: raise SystemExit('PATCH ERROR: createVodiaServer not found')
    anchor=s.find('registerPbXReadTool(',factory)
    if anchor < 0: raise SystemExit('PATCH ERROR: registerPbXReadTool call not found')
    line_start=s.rfind('\n',factory,anchor)+1
    indent=s[line_start:anchor]
    if indent.strip(): indent='  '
    reg='''// v0.14.9.17.1 AWS Marketplace EC2 registration hotfix
registerAwsMarketplaceDeployTools(server, {
  z,
  toolOutputSchema,
  scopedAudit,
  scopedSuccess,
  failure,
});

'''
    reg='\n'.join((indent+x if x else x) for x in reg.split('\n'))
    s=s[:line_start]+reg+s[line_start:]

if s.count(call) != 1:
    raise SystemExit('PATCH ERROR: AWS registration count is not one after repair')
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "registration-repaired index.js syntax invalid"
echo PASS

echo "[4/10] Download AWS profile/module/UI sources"
curl -fsSL "$SOURCE_BASE/aws-marketplace-ec2-deploy-v1.js" -o "$TMP_MODULE"
curl -fsSL "$SOURCE_BASE/aws-connection-profile-v1.js" -o "$TMP_PROFILE"
curl -fsSL "$SOURCE_BASE/mcp-apps/aws-connect/app.js" -o "$UI_SRC"
curl -fsSL "$SOURCE_BASE/mcp-apps/aws-connect/template.html" -o "$UI_TEMPLATE"
for f in "$TMP_MODULE" "$TMP_PROFILE" "$UI_SRC" "$UI_TEMPLATE"; do [[ -s "$f" ]] || fail "downloaded source is empty: $f"; done
node --check "$TMP_MODULE" >/dev/null || fail "AWS deployment module syntax invalid"
node --check "$TMP_PROFILE" >/dev/null || fail "AWS connection profile module syntax invalid"
echo PASS

echo "[5/10] Install modules + secure state directory"
SERVICE_USER="$(systemctl show -p User --value "$SERVICE" 2>/dev/null || true)"
[[ -n "$SERVICE_USER" ]] || SERVICE_USER="root"
install -o root -g root -m 0644 "$TMP_MODULE" "$MODULE"
install -o root -g root -m 0644 "$TMP_PROFILE" "$PROFILE_MODULE"
mkdir -p "$STATE_DIR"
chown "$SERVICE_USER":"$(id -gn "$SERVICE_USER")" "$STATE_DIR"
chmod 0700 "$STATE_DIR"
if [[ "$SERVICE_USER" != "root" ]]; then
  runuser -u "$SERVICE_USER" -- test -r "$MODULE" || fail "deployment module unreadable by $SERVICE_USER"
  runuser -u "$SERVICE_USER" -- test -r "$PROFILE_MODULE" || fail "profile module unreadable by $SERVICE_USER"
  runuser -u "$SERVICE_USER" -- test -w "$STATE_DIR" || fail "state directory not writable by $SERVICE_USER"
fi
echo "PASS: modules 0644; state dir 0700 owned by $SERVICE_USER"

echo "[6/10] Build Connect AWS MCP App"
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
chmod 0644 "$UI_HTML"
grep -q 'Test &amp; Save Connection' "$UI_HTML" || fail "AWS connect UI missing Test & Save button"
echo PASS

echo "[7/10] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.18\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[8/10] Static safety validation"
python3 - "$TMP_INDEX" "$MODULE" "$PROFILE_MODULE" "$UI_HTML" <<'PY'
from pathlib import Path
import sys
index=Path(sys.argv[1]).read_text()
module=Path(sys.argv[2]).read_text()
profile=Path(sys.argv[3]).read_text()
ui=Path(sys.argv[4]).read_text()
if index.count('registerAwsMarketplaceDeployTools(server') != 1:
    raise SystemExit('VALIDATION ERROR: AWS tool registration must occur exactly once')
for x in [
  '"aws_connect_customer_account"',
  '"aws_get_customer_connection_profile"',
  '"aws_save_customer_connection_profile"',
  'ui://vodia/aws-connect/mcp-app.html',
  'resolveAwsConnection',
  'saveAwsConnectionProfile',
]:
    if x not in module: raise SystemExit(f'VALIDATION ERROR: deployment module missing {x}')
if 'aes-256-gcm' not in profile:
    raise SystemExit('VALIDATION ERROR: encrypted profile store missing AES-256-GCM')
if 'externalId:' in profile.split('sanitizeAwsConnectionProfile',1)[1].split('}',1)[0]:
    raise SystemExit('VALIDATION ERROR: sanitized profile appears to expose External ID')
for x in ['Connect AWS Account','Test &amp; Save Connection','encrypted at rest']:
    if x not in ui: raise SystemExit(f'VALIDATION ERROR: UI missing {x}')
print('PASS: Connect AWS MCP App registered')
print('PASS: STS Test & Save tool present')
print('PASS: connection profile encrypted at rest')
print('PASS: profile read does not return External ID')
print('PASS: AWS tools accept saved-profile fallback')
print('PASS: existing Marketplace/EC2 plan/apply tools preserved')
PY
echo PASS

echo "[9/10] Activate + restart"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
cd "$APP"
node --check "$INDEX" >/dev/null
node --check "$VERSION" >/dev/null
node -e 'import("./aws-marketplace-ec2-deploy-v1.js").then(()=>process.exit(0)).catch(e=>{console.error(e);process.exit(1)})'
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 150 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.18' "$HEALTH" || fail "health endpoint did not report v0.14.9.18"
sleep 2
if journalctl -u "$SERVICE" --since "-10 seconds" --no-pager | grep -q 'Tool aws_check_customer_connection is already registered'; then
  fail "duplicate AWS tool registration detected"
fi
echo PASS

echo "[10/10] Complete"
echo "PASS: v0.14.9.18 AWS Connect UX installed"
echo "PASS: customer can enter Role ARN + External ID once in the MCP App"
echo "PASS: successful STS check saves an encrypted connection profile"
echo "PASS: future AWS tools may omit roleArn/externalId and reuse the saved profile"
echo "PASS: External ID is never returned by profile-read tools"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session and invoke aws_connect_customer_account."
trap - ERR
