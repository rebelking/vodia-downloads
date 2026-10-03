#!/usr/bin/env bash
# Vodia MCP v0.14.9.30 — Guided UI polish
# Compact required-information UI + cleaner model-visible launcher.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="b339f57d0acc83d8e11a964d6fc224e4713d9dd3"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.30-guided-ui-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/index.js" "$APP/version.js" "$APP/msp-guided-app-v1.js"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
if [[ "$CURRENT" == "0.14.9.30" ]]; then
  echo "v0.14.9.30 already installed; verification mode."
elif [[ "$CURRENT" != "0.14.9.29" ]]; then
  fail "expected v0.14.9.29 or v0.14.9.30; found ${CURRENT:-unknown}"
fi

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
[[ -f "$APP/ui/msp-guided-app.html" ]] && cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/" || true
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.30" ]]; then
  echo "[2/7] Download immutable UI files"
  curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"
  grep -q '"vodia_setup"' "$TMP/msp-guided-app-v1.js" || fail "friendly Vodia launcher missing"
  grep -q 'visibility: \["app"\]' "$TMP/msp-guided-app-v1.js" || fail "legacy launcher is not app-only"
  grep -q 'Only required information is shown' "$TMP/msp-guided-app.html" || fail "compact guided UI missing"
  node --check "$TMP/msp-guided-app-v1.js"
  echo PASS

  echo "[3/7] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.29(["\'])',r'\g<1>0.14.9.30\2',s,count=1)
if n != 1 and '0.14.9.30' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.30' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  mkdir -p "$APP/ui"
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
grep -q '"version":"0.14.9.30"' <<<"$HEALTH" || fail "health does not report v0.14.9.30"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"
node --check "$APP/msp-guided-app-v1.js"
grep -q '"vodia_setup"' "$APP/msp-guided-app-v1.js" || fail "vodia_setup missing"
grep -q 'Only required information is shown' "$APP/ui/msp-guided-app.html" || fail "new UI not installed"
echo "PASS: health and guided UI verified"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.30 guided UI polish installed."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client so it sees the new vodia_setup launcher."
