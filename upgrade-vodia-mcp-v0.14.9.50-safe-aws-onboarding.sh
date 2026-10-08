#!/usr/bin/env bash
# Vodia MCP v0.14.9.50 — stable and reusable AWS onboarding
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="7a9afdf1b03172c2fd5e56e509124e8a76fcfab6"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.50-safe-aws-onboarding-$STAMP"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/msp-customer-connections-v1.js" "$APP/ui/msp-guided-app.html"; do [[ -f "$f" ]] || fail "missing $f"; done
CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(); m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else '',end='')
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.49) ;;
  0.14.9.50) echo "v0.14.9.50 already installed; verification mode." ;;
  *) fail "expected v0.14.9.49 or v0.14.9.50; found ${CURRENT:-unknown}" ;;
esac
echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$APP/msp-guided-app-v1.js" "$APP/msp-customer-connections-v1.js" "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"
echo "[2/7] Stage safe AWS onboarding"
mkdir -p "$TMP/staged/ui"
cp -a "$APP/ui/msp-guided-app.html" "$TMP/staged/ui/msp-guided-app.html"
cp -a "$APP/msp-guided-app-v1.js" "$APP/msp-customer-connections-v1.js" "$APP/version.js" "$TMP/staged/"
curl -fsSL "$RAW_BASE/patch-vodia-guided-aws-onboarding-v0.14.9.50.py" -o "$TMP/patch.py"
curl -fsSL "$RAW_BASE/verify-vodia-guided-aws-deploy-v0.14.9.50.sh" -o "$TMP/verify.sh"
chmod +x "$TMP/patch.py" "$TMP/verify.sh"
if [[ "$CURRENT" != "0.14.9.50" ]]; then
  python3 "$TMP/patch.py" "$TMP/staged/msp-customer-connections-v1.js" "$TMP/staged/ui/msp-guided-app.html"
  python3 - "$TMP/staged/msp-guided-app-v1.js" "$TMP/staged/version.js" <<'PY'
from pathlib import Path
import re,sys
m=Path(sys.argv[1]); s=m.read_text(); s,n=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.50/mcp-app.html',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: UI URI anchor missing')
m.write_text(s)
v=Path(sys.argv[2]); s=v.read_text(); s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.49(["\'])',r'\g<1>0.14.9.50\2',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: connector version anchor missing')
v.write_text(s)
PY
fi
echo "[3/7] Verify staged files"
VODIA_MCP_APP_DIR="$TMP/staged" "$TMP/verify.sh"
if [[ "$CURRENT" != "0.14.9.50" ]]; then
  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/staged/ui/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/staged/msp-customer-connections-v1.js" "$APP/msp-customer-connections-v1.js"
  install -o root -g root -m 0644 "$TMP/staged/version.js" "$APP/version.js"
  echo "[5/7] Restart"
  systemctl restart "$SERVICE"
else
  echo "[4/7]-[5/7] Install skipped"
fi
echo "[6/7] Verify live service"
HEALTH=""
for _ in {1..30}; do if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi; sleep 1; done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.50"' <<<"$HEALTH" || fail "health does not report v0.14.9.50"
VODIA_MCP_APP_DIR="$APP" "$TMP/verify.sh"
echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.50 installed and verified."
echo "PASS: onboarding retries keep the same pending customer External ID."
echo "PASS: CloudFormation completion is required before verification."
echo "PASS: authorized customers can explicitly reuse an existing verified AWS connection without exposing its External ID."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and open Vodia setup in a new message."
