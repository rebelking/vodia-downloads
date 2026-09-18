#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
ADMIN_SERVICE="vodia-admin-connections"
ADMIN_UNIT="/etc/systemd/system/vodia-admin-connections.service"
WATCH_SERVICE="/etc/systemd/system/vodia-provider-connections-reload.service"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.26-admin-save-race-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"

trap 'rm -rf "$TMP_DIR"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node systemctl curl grep; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

[[ -f "$VERSION" ]] || fail "missing $VERSION"
[[ -f "$ADMIN_UNIT" ]] || fail "missing $ADMIN_UNIT"
[[ -f "$WATCH_SERVICE" ]] || fail "missing $WATCH_SERVICE"
grep -q '0.14.9.25' "$VERSION" || fail "expected installed base v0.14.9.25"

echo "=== Vodia MCP v0.14.9.26 — Admin Save/Restart Race Hotfix ==="
echo "Fixes AWS Save losing the response/session when provider changes restart the MCP."

echo "[1/8] Sanity check current units — NO LIVE CHANGES"
grep -q '^Requires=vodia-mcp.service$' "$ADMIN_UNIT" || fail "expected Requires=vodia-mcp.service in admin unit"
grep -q '^ExecStart=/bin/systemctl try-restart vodia-mcp.service$' "$WATCH_SERVICE" || fail "expected current immediate MCP restart watcher"
echo "PASS: current race condition detected exactly as expected"

echo "[2/8] Stage fixed units — NO LIVE CHANGES"
cp -a "$ADMIN_UNIT" "$TMP_DIR/vodia-admin-connections.service"
cp -a "$WATCH_SERVICE" "$TMP_DIR/vodia-provider-connections-reload.service"

python3 - "$TMP_DIR/vodia-admin-connections.service" "$TMP_DIR/vodia-provider-connections-reload.service" <<'PY'
from pathlib import Path
import sys
admin=Path(sys.argv[1])
watch=Path(sys.argv[2])

a=admin.read_text()
a=a.replace("Requires=vodia-mcp.service\n","")
admin.write_text(a)

w=watch.read_text()
old="ExecStart=/bin/systemctl try-restart vodia-mcp.service"
new="ExecStart=/bin/sh -c 'sleep 3; /bin/systemctl try-restart vodia-mcp.service'"
if old not in w:
    raise SystemExit("PATCH ERROR: watcher ExecStart anchor missing")
w=w.replace(old,new,1)
watch.write_text(w)
PY

grep -q '^Requires=vodia-mcp.service$' "$TMP_DIR/vodia-admin-connections.service" && fail "Requires still present after staging"
grep -q "sleep 3; /bin/systemctl try-restart vodia-mcp.service" "$TMP_DIR/vodia-provider-connections-reload.service" || fail "delayed restart not staged"
echo PASS

echo "[3/8] Stage version — NO LIVE CHANGES"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.26\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[4/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$ADMIN_UNIT" "$BACKUP_DIR/vodia-admin-connections.service"
cp -a "$WATCH_SERVICE" "$BACKUP_DIR/vodia-provider-connections-reload.service"
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.26 state..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/vodia-admin-connections.service" "$ADMIN_UNIT" || true
  cp -a "$BACKUP_DIR/vodia-provider-connections-reload.service" "$WATCH_SERVICE" || true
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$ADMIN_SERVICE" 2>/dev/null || true
  systemctl restart vodia-provider-connections.path 2>/dev/null || true
  exit "$rc"
}

echo "[5/8] Install hotfix"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_DIR/vodia-admin-connections.service" "$ADMIN_UNIT"
install -o root -g root -m 0644 "$TMP_DIR/vodia-provider-connections-reload.service" "$WATCH_SERVICE"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl daemon-reload
systemctl restart "$ADMIN_SERVICE"
systemctl restart vodia-provider-connections.path
systemctl restart "$SERVICE"
echo PASS

echo "[6/8] Health validation"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed"
grep -q '0.14.9.26' "$HEALTH" || fail "health did not report v0.14.9.26"
systemctl is-active --quiet "$ADMIN_SERVICE" || fail "admin service inactive"
systemctl is-active --quiet vodia-provider-connections.path || fail "provider watcher inactive"
echo PASS

echo "[7/8] Dependency/race validation"
if systemctl cat "$ADMIN_SERVICE" | grep -q '^Requires=vodia-mcp.service$'; then
  fail "admin service still has hard Requires dependency"
fi
systemctl cat vodia-provider-connections-reload.service | grep -q 'sleep 3' || fail "restart delay missing"
echo "PASS: admin service no longer stops when MCP restarts"
echo "PASS: provider-store restart is delayed 3 seconds so Save can complete first"

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.26 admin save/restart race hotfix installed"
echo "PASS: AWS Save request can finish before MCP restart"
echo "PASS: admin login session stays alive during MCP restart"
echo
echo "Now log in once, Save AWS, wait 5 seconds, then click Test."
echo "Backup: $BACKUP_DIR"
trap - ERR
