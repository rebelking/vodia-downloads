#!/usr/bin/env bash
# Vodia MCP v0.14.9.26 — Admin Save/Restart Race Hotfix (revised)
#
# Changes:
#   - Any failure after install (health, version, service state, race checks)
#     now rolls back.
#   - Base-version check is anchored to CONNECTOR_VERSION.
#   - Health output is cleared before polling and version match is anchored.
#   - Restart delay is configurable: VODIA_MCP_RESTART_DELAY (default 3s).
#   - Staged systemd units are validated with systemd-analyze verify.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
ADMIN_SERVICE="vodia-admin-connections"
ADMIN_UNIT="/etc/systemd/system/vodia-admin-connections.service"
WATCH_SERVICE="/etc/systemd/system/vodia-provider-connections-reload.service"
WATCH_PATH_UNIT="vodia-provider-connections.path"
FROM_VER="0.14.9.25"
TO_VER="0.14.9.26"
RESTART_DELAY="${VODIA_MCP_RESTART_DELAY:-3}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-admin-save-race-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"
INSTALLED=0

trap 'rm -rf "$TMP_DIR"' EXIT

rollback(){
  local rc="${1:-1}"
  trap - ERR
  INSTALLED=0
  echo "Activation failed; restoring pre-v${TO_VER} state from $BACKUP_DIR ..." >&2
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/vodia-admin-connections.service" "$ADMIN_UNIT" || true
  cp -a "$BACKUP_DIR/vodia-provider-connections-reload.service" "$WATCH_SERVICE" || true
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$ADMIN_SERVICE" 2>/dev/null || true
  systemctl restart "$WATCH_PATH_UNIT" 2>/dev/null || true
  echo "ROLLED BACK. Backup kept at: $BACKUP_DIR" >&2
  exit "$rc"
}

fail(){
  echo "FAIL: $*" >&2
  if (( INSTALLED )); then rollback 1; fi
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root"

for c in python3 node systemctl systemd-analyze curl grep install; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

[[ "$RESTART_DELAY" =~ ^[0-9]+$ ]] && (( RESTART_DELAY >= 1 && RESTART_DELAY <= 30 )) \
  || fail "VODIA_MCP_RESTART_DELAY must be an integer 1-30 (got '$RESTART_DELAY')"

[[ -f "$VERSION" ]]       || fail "missing $VERSION"
[[ -f "$ADMIN_UNIT" ]]    || fail "missing $ADMIN_UNIT"
[[ -f "$WATCH_SERVICE" ]] || fail "missing $WATCH_SERVICE"

grep -Eq "CONNECTOR_VERSION[[:space:]]*=[[:space:]]*[\"']${FROM_VER//./\\.}[\"']" "$VERSION" \
  || fail "expected installed base v${FROM_VER} (CONNECTOR_VERSION in $VERSION)"

echo "=== Vodia MCP v${TO_VER} — Admin Save/Restart Race Hotfix ==="
echo "Fixes AWS Save losing the response/session when provider changes restart the MCP."
echo "Restart delay: ${RESTART_DELAY}s"

echo "[1/8] Sanity check current units — NO LIVE CHANGES"
grep -q '^Requires=vodia-mcp.service$' "$ADMIN_UNIT" \
  || fail "expected Requires=vodia-mcp.service in admin unit"
grep -q '^ExecStart=/bin/systemctl try-restart vodia-mcp.service$' "$WATCH_SERVICE" \
  || fail "expected current immediate MCP restart watcher"
echo "PASS: current race condition detected exactly as expected"

echo "[2/8] Stage fixed units — NO LIVE CHANGES"
cp -a "$ADMIN_UNIT" "$TMP_DIR/vodia-admin-connections.service"
cp -a "$WATCH_SERVICE" "$TMP_DIR/vodia-provider-connections-reload.service"

python3 - "$TMP_DIR/vodia-admin-connections.service" \
          "$TMP_DIR/vodia-provider-connections-reload.service" "$RESTART_DELAY" <<'PY'
from pathlib import Path
import sys
admin, watch, delay = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]

a = admin.read_text()
if "Requires=vodia-mcp.service\n" not in a:
    raise SystemExit("PATCH ERROR: admin Requires= anchor missing")
admin.write_text(a.replace("Requires=vodia-mcp.service\n", ""))

w = watch.read_text()
old = "ExecStart=/bin/systemctl try-restart vodia-mcp.service"
new = f"ExecStart=/bin/sh -c 'sleep {delay}; /bin/systemctl try-restart vodia-mcp.service'"
if old not in w:
    raise SystemExit("PATCH ERROR: watcher ExecStart anchor missing")
watch.write_text(w.replace(old, new, 1))
PY

grep -q '^Requires=vodia-mcp.service$' "$TMP_DIR/vodia-admin-connections.service" \
  && fail "Requires still present after staging"

grep -q "sleep ${RESTART_DELAY}; /bin/systemctl try-restart vodia-mcp.service" \
  "$TMP_DIR/vodia-provider-connections-reload.service" \
  || fail "delayed restart not staged"

systemd-analyze verify \
  "$TMP_DIR/vodia-admin-connections.service" \
  "$TMP_DIR/vodia-provider-connections-reload.service" \
  >/dev/null 2>&1 \
  || fail "staged systemd unit validation failed"

echo "PASS: staged units valid"

echo "[3/8] Stage version — NO LIVE CHANGES"
cp -a "$VERSION" "$TMP_VERSION"

python3 - "$TMP_VERSION" "$TO_VER" <<'PY'
from pathlib import Path
import re, sys
p, to = Path(sys.argv[1]), sys.argv[2]
s = p.read_text()
n = re.sub(
    r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
    r'\g<1>' + to + r'\2',
    s,
    count=1
)
if n == s:
    raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY

node --check "$TMP_VERSION" >/dev/null || fail "staged version.js failed node --check"
echo PASS

echo "[4/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION"       "$BACKUP_DIR/version.js"
cp -a "$ADMIN_UNIT"    "$BACKUP_DIR/vodia-admin-connections.service"
cp -a "$WATCH_SERVICE" "$BACKUP_DIR/vodia-provider-connections-reload.service"
echo "PASS: $BACKUP_DIR"

echo "[5/8] Install hotfix"
INSTALLED=1
trap 'rollback $?' ERR

install -o root -g root -m 0644 "$TMP_DIR/vodia-admin-connections.service" "$ADMIN_UNIT"
install -o root -g root -m 0644 "$TMP_DIR/vodia-provider-connections-reload.service" "$WATCH_SERVICE"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"

systemctl daemon-reload
systemctl restart "$ADMIN_SERVICE"
systemctl restart "$WATCH_PATH_UNIT"
systemctl restart "$SERVICE"

echo PASS

echo "[6/8] Health validation"
rm -f "$HEALTH"

for _ in {1..30}; do
  if curl -fsS -o "$HEALTH" http://127.0.0.1:3100/health 2>/dev/null && [[ -s "$HEALTH" ]]; then
    break
  fi
  rm -f "$HEALTH"
  sleep 1
done

[[ -s "$HEALTH" ]] || fail "MCP health failed after 30s"

grep -Eq "(^|[^0-9.])${TO_VER//./\\.}([^0-9.]|$)" "$HEALTH" \
  || fail "health did not report v${TO_VER}"

systemctl is-active --quiet "$ADMIN_SERVICE" \
  || fail "admin service inactive"

systemctl is-active --quiet "$WATCH_PATH_UNIT" \
  || fail "provider watcher inactive"

echo PASS

echo "[7/8] Dependency/race validation"

if systemctl cat "$ADMIN_SERVICE" | grep -q '^Requires=vodia-mcp.service$'; then
  fail "admin service still has hard Requires dependency"
fi

systemctl cat vodia-provider-connections-reload.service \
  | grep -q "sleep ${RESTART_DELAY};" \
  || fail "restart delay missing"

systemctl is-active --quiet "$WATCH_PATH_UNIT" \
  || fail "provider watcher inactive"

echo "PASS: admin service no longer stops when MCP restarts"
echo "PASS: provider-store restart is delayed ${RESTART_DELAY}s so Save can complete first"

echo "[8/8] Complete"

trap - ERR
INSTALLED=0

cat "$HEALTH"
echo

echo "PASS: v${TO_VER} admin save/restart race hotfix installed"
echo
echo "Now log in once, Save AWS, wait $((RESTART_DELAY + 2)) seconds, then click Test."
echo "Backup: $BACKUP_DIR"
