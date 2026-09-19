#!/usr/bin/env bash
# Vodia MCP v0.14.9.32 — fullscreen guided setup preference
# Requests fullscreen for the guided MCP App when the host supports it, with
# an Expand/Inline fallback control in the UI.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="b0c94106a33f31ab6848f7e956d2b98afbe6d08c"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.32-fullscreen-guided-$STAMP"
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
  0.14.9.31) ;;
  0.14.9.32) echo "v0.14.9.32 already installed; verification mode." ;;
  *) fail "expected v0.14.9.31 or v0.14.9.32; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.32" ]]; then
  echo "[2/7] Download immutable UI"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"
  grep -q 'ui/request-display-mode' "$TMP/msp-guided-app.html" || fail "display-mode request missing"
  grep -q 'requestDisplayMode("fullscreen")' "$TMP/msp-guided-app.html" || fail "fullscreen preference missing"
  grep -q 'id="expandView"' "$TMP/msp-guided-app.html" || fail "Expand fallback button missing"
  grep -q 'version:"1.3.0"' "$TMP/msp-guided-app.html" || fail "guided app v1.3 marker missing"
  echo PASS

  echo "[3/7] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.31(["\'])',
    r'\g<1>0.14.9.32\2',
    s,
    count=1
)
if n != 1 and '0.14.9.32' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.32' "$TMP/version.js" || fail "version staging failed"
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

echo "[6/7] Verify"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.32"' <<<"$HEALTH" || fail "health does not report v0.14.9.32"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"
grep -q 'ui/request-display-mode' "$APP/ui/msp-guided-app.html" || fail "live display-mode request missing"
grep -q 'requestDisplayMode("fullscreen")' "$APP/ui/msp-guided-app.html" || fail "live fullscreen preference missing"
grep -q 'id="expandView"' "$APP/ui/msp-guided-app.html" || fail "live Expand button missing"
echo "PASS: health and fullscreen guided UI verified"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.32 fullscreen guided setup installed."
echo "Backup retained at: $BACKUP"
echo "Refresh/reconnect the MCP client and open Vodia setup again."
