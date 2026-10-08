#!/usr/bin/env bash
# Vodia MCP v0.14.9.31 — inline guided-app sizing
# Makes the Vodia setup app a taller rectangular inline card and reports
# intrinsic height so the host page scrolls instead of the iframe.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="35e9b4c11d2841018e91c6e3c99693e6ef47363d"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.31-inline-sizing-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/ui/msp-guided-app.html"; do [[ -f "$f" ]] || fail "missing $f"; done

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
  0.14.9.29|0.14.9.30) ;;
  0.14.9.31) echo "v0.14.9.31 already installed; verification mode." ;;
  *) fail "expected v0.14.9.29, v0.14.9.30, or v0.14.9.31; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.31" ]]; then
  echo "[2/7] Download immutable guided-app files"
  curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"

  node --check "$TMP/msp-guided-app-v1.js"
  grep -q '"vodia_setup"' "$TMP/msp-guided-app-v1.js" || fail "friendly vodia_setup launcher missing"
  grep -q 'ui/notifications/size-changed' "$TMP/msp-guided-app.html" || fail "size-change reporting missing"
  grep -q 'max-width:760px' "$TMP/msp-guided-app.html" || fail "rectangular layout missing"
  grep -q 'version:"1.2.0"' "$TMP/msp-guided-app.html" || fail "guided app v1.2 marker missing"
  echo PASS

  echo "[3/7] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.(?:29|30)(["\'])',
    r'\g<1>0.14.9.31\2',
    s,
    count=1
)
if n != 1 and '0.14.9.31' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.31' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  echo PASS

  echo "[5/7] Restart"
  systemctl restart "$SERVICE"
else
  echo "[2/7]-[5/7] Install skipped"
fi

echo "[6/7] Verify"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.31"' <<<"$HEALTH" || fail "health does not report v0.14.9.31"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"
node --check "$APP/msp-guided-app-v1.js"
grep -q 'ui/notifications/size-changed' "$APP/ui/msp-guided-app.html" || fail "live size reporting missing"
grep -q 'max-width:760px' "$APP/ui/msp-guided-app.html" || fail "live rectangular layout missing"
echo "PASS: health and inline sizing verified"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.31 inline app sizing installed."
echo "Backup retained at: $BACKUP"
echo "Reconnect/refresh the MCP client, then open Vodia setup again."
