#!/usr/bin/env bash
# Vodia MCP v0.14.9.33 — guided setup inline/fullscreen layout fix
# Inline stays capped and scrollable; fullscreen is opt-in via Expand/Collapse.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="90851c4593f4fd34e18acc1a8f9c557c1ee2f895"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.33-guided-layout-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep bash; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/ui/msp-guided-app.html"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.31|0.14.9.32) ;;
  0.14.9.33) echo "v0.14.9.33 already installed; verification mode." ;;
  *) fail "expected v0.14.9.31, v0.14.9.32, or v0.14.9.33; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.33" ]]; then
  echo "[2/7] Download immutable UI and verifier"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"
  curl -fsSL "$RAW_BASE/verify-vodia-guided-ui-layout-v0.14.9.33.sh" -o "$TMP/verify.sh"
  chmod +x "$TMP/verify.sh"

  mkdir -p "$TMP/staged/ui"
  cp "$TMP/msp-guided-app.html" "$TMP/staged/ui/msp-guided-app.html"
  VODIA_MCP_APP_DIR="$TMP/staged" "$TMP/verify.sh"
  echo PASS

  echo "[3/7] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.(?:31|32)(["\'])',
    r'\g<1>0.14.9.33\2',
    s,
    count=1
)
if n != 1 and '0.14.9.33' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.33' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  echo PASS

  echo "[5/7] Restart"
  systemctl restart "$SERVICE"
else
  echo "[2/7]-[5/7] Install skipped"
fi

echo "[6/7] Verify live service and UI"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || {
  journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true
  fail "MCP health failed"
}
echo "$HEALTH"
grep -q '"version":"0.14.9.33"' <<<"$HEALTH" || fail "health does not report v0.14.9.33"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"

if [[ ! -f "$TMP/verify.sh" ]]; then
  curl -fsSL "$RAW_BASE/verify-vodia-guided-ui-layout-v0.14.9.33.sh" -o "$TMP/verify.sh"
  chmod +x "$TMP/verify.sh"
fi
VODIA_MCP_APP_DIR="$APP" "$TMP/verify.sh"
echo "PASS: health and guided layout verified"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.33 guided layout fix installed."
echo "Backup retained at: $BACKUP"
echo "Reconnect/refresh the MCP client, then open Vodia setup and test Expand/Collapse."
