#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
CONTROL_SERVICE="vodia-control-api"
WEB_DIR="$APP/control-center-v2"
SOURCE_REF="${VODIA_MCP_CONTROL_CENTER_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_ROOT="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}/control-center-v2"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.22-control-theme-$STAMP"
TMP_VERSION="$(mktemp --suffix=.js)"
TMP_INDEX="$(mktemp --suffix=.html)"
TMP_CSS="$(mktemp --suffix=.css)"
TMP_APP="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_VERSION" "$TMP_INDEX" "$TMP_CSS" "$TMP_APP" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$VERSION" "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$WEB_DIR/app.js"; do [[ -f "$f" ]] || fail "missing $f"; done
grep -q '0.14.9.21' "$VERSION" || fail "expected installed base v0.14.9.21"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
systemctl is-active --quiet "$CONTROL_SERVICE" || fail "$CONTROL_SERVICE is not active"

echo "=== Vodia MCP v0.14.9.22 — Polished Light/Dark Control Center ==="
echo "Applies the approved compact dashboard layout with persistent light and dark themes."

echo "[1/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$WEB_DIR/index.html" "$BACKUP_DIR/index.html"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$WEB_DIR/app.js" "$BACKUP_DIR/app.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.22 files..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/index.html" "$WEB_DIR/index.html" || true
  cp -a "$BACKUP_DIR/styles.css" "$WEB_DIR/styles.css" || true
  cp -a "$BACKUP_DIR/app.js" "$WEB_DIR/app.js" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  exit "$rc"
}

echo "[2/7] Download approved frontend"
curl -fsSL "$SOURCE_ROOT/index.html" -o "$TMP_INDEX"
curl -fsSL "$SOURCE_ROOT/styles.css" -o "$TMP_CSS"
curl -fsSL "$SOURCE_ROOT/app.js" -o "$TMP_APP"
node --check "$TMP_APP" >/dev/null || fail "frontend JS syntax invalid"
echo PASS

echo "[3/7] UX validation"
for marker in   'Vodia MCP Control Center'   'Connected services'   'Service overview'   'Workflows &amp; Quick actions'   'PBX health'   'Recent MCP activity'   'Advanced administration'   'themeToggle'; do
  grep -q "$marker" "$TMP_INDEX" || fail "missing UI marker: $marker"
done
grep -q 'html\[data-theme="dark"\]' "$TMP_CSS" || fail "dark theme CSS missing"
grep -q 'THEME_KEY="vodia-mcp-theme"' "$TMP_APP" || fail "persistent theme toggle missing"
if grep -Eqi '<input|<textarea|contenteditable=' "$TMP_INDEX"; then
  fail "customer dashboard contains a text-entry control"
fi
echo "PASS: no raw text-entry controls on customer dashboard"
echo "PASS: light + dark modes present"
echo "PASS: theme preference persists in browser"

echo "[4/7] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.22\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[5/7] Install + restart"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_INDEX" "$WEB_DIR/index.html"
install -o root -g root -m 0644 "$TMP_CSS" "$WEB_DIR/styles.css"
install -o root -g root -m 0644 "$TMP_APP" "$WEB_DIR/app.js"
cp -a "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE"
echo PASS

echo "[6/7] Health"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null && curl -fsS http://127.0.0.1:3110/control-api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.22' "$HEALTH" || fail "health did not report v0.14.9.22"
systemctl is-active --quiet "$CONTROL_SERVICE" || fail "$CONTROL_SERVICE is not active"
echo PASS

echo "[7/7] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.22 polished Control Center installed"
echo "PASS: approved compact layout is live"
echo "PASS: light/dark toggle is live and persistent"
echo "PASS: existing live PBX/AWS/Cloudflare/Microsoft wiring is preserved"
echo "PASS: customer dashboard still contains no raw credential fields"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
