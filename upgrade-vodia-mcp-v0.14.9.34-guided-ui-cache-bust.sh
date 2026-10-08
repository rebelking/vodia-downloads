#!/usr/bin/env bash
# Vodia MCP v0.14.9.34 — guided UI resource cache bust
# Changes the ui:// resource URI so MCP hosts cannot reuse the pre-.33 widget.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="db643230ac94a71fabbde9203cace01b4a4d5f15"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
NEW_URI="ui://vodia/msp-guided/v0.14.9.34/mcp-app.html"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.34-guided-cache-bust-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
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
  0.14.9.33) ;;
  0.14.9.34) echo "v0.14.9.34 already installed; verification mode." ;;
  *) fail "expected v0.14.9.33 or v0.14.9.34; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.34" ]]; then
  echo "[2/7] Download immutable guided resource module"
  curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
  node --check "$TMP/msp-guided-app-v1.js"
  grep -Fq "$NEW_URI" "$TMP/msp-guided-app-v1.js" || fail "versioned guided UI URI missing"
  grep -q '"vodia_setup"' "$TMP/msp-guided-app-v1.js" || fail "vodia_setup launcher missing"
  echo PASS

  echo "[3/7] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.33(["\'])',
    r'\g<1>0.14.9.34\2',
    s,
    count=1
)
if n != 1 and '0.14.9.34' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.34' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
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
[[ -n "$HEALTH" ]] || {
  journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true
  fail "MCP health failed"
}
echo "$HEALTH"
grep -q '"version":"0.14.9.34"' <<<"$HEALTH" || fail "health does not report v0.14.9.34"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"
node --check "$APP/msp-guided-app-v1.js"
grep -Fq "$NEW_URI" "$APP/msp-guided-app-v1.js" || fail "live module does not use versioned UI URI"
grep -q 'class="setup-scroll"' "$APP/ui/msp-guided-app.html" || fail "v0.14.9.33 layout is not present"
grep -q 'max-height:520px' "$APP/ui/msp-guided-app.html" || fail "520px inline layout cap missing"

TOKEN="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
if not p.exists():
    raise SystemExit
for line in p.read_text().splitlines():
    if line.startswith("MCP_BEARER_TOKEN="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"":
            v=v[1:-1]
        print(v,end="")
        break
PY
)" || true

if [[ -n "$TOKEN" ]]; then
  curl -sS     -H "Authorization: Bearer $TOKEN"     -H 'Content-Type: application/json'     -H 'Accept: application/json, text/event-stream'     --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'     http://127.0.0.1:3100/mcp >"$TMP/tools.out"
  grep -Fq "$NEW_URI" "$TMP/tools.out" || fail "tools/list is not advertising the versioned UI URI"
  echo "PASS: tools/list advertises versioned guided UI URI"
fi

echo "PASS: health, .33 layout, and cache-busting URI verified"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.34 guided UI cache bust installed."
echo "Backup retained at: $BACKUP"
echo "Reconnect the client and open Vodia setup in a NEW message."
