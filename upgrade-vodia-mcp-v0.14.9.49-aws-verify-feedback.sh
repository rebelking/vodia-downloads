#!/usr/bin/env bash
# Vodia MCP v0.14.9.49 — visible AWS verification and automatic continuation
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="e138cc6f63360b3926105534c279c470866ed0c2"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.49-aws-verify-feedback-$STAMP"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js" "$APP/ui/msp-guided-app.html"; do [[ -f "$f" ]] || fail "missing $f"; done
CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(); m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else '',end='')
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.48) ;;
  0.14.9.49) echo "v0.14.9.49 already installed; verification mode." ;;
  *) fail "expected v0.14.9.48 or v0.14.9.49; found ${CURRENT:-unknown}" ;;
esac
echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$APP/msp-guided-app-v1.js" "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"
echo "[2/7] Stage visible AWS verification"
cp -a "$APP/ui/msp-guided-app.html" "$TMP/msp-guided-app.html"
cp -a "$APP/msp-guided-app-v1.js" "$TMP/msp-guided-app-v1.js"
cp -a "$APP/aws-marketplace-ec2-deploy-v1.js" "$TMP/aws-marketplace-ec2-deploy-v1.js"
cp -a "$APP/version.js" "$TMP/version.js"
curl -fsSL "$RAW_BASE/patch-vodia-guided-aws-verify-v0.14.9.49.py" -o "$TMP/patch.py"
curl -fsSL "$RAW_BASE/verify-vodia-guided-aws-deploy-v0.14.9.49.sh" -o "$TMP/verify.sh"
chmod +x "$TMP/patch.py" "$TMP/verify.sh"
if [[ "$CURRENT" != "0.14.9.49" ]]; then
  python3 "$TMP/patch.py" "$TMP/msp-guided-app.html"
  python3 - "$TMP/msp-guided-app-v1.js" "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
m=Path(sys.argv[1]); s=m.read_text(); s,n=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.49/mcp-app.html',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: UI URI anchor missing')
m.write_text(s)
v=Path(sys.argv[2]); s=v.read_text(); s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.\d+(["\'])',r'\g<1>0.14.9.49\2',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: connector version anchor missing')
v.write_text(s)
PY
fi
echo "[3/7] Verify staged files"
mkdir -p "$TMP/staged/ui"
cp "$TMP/msp-guided-app.html" "$TMP/staged/ui/msp-guided-app.html"
cp "$TMP/msp-guided-app-v1.js" "$TMP/aws-marketplace-ec2-deploy-v1.js" "$TMP/staged/"
VODIA_MCP_APP_DIR="$TMP/staged" "$TMP/verify.sh"
if [[ "$CURRENT" != "0.14.9.49" ]]; then
  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  echo "[5/7] Restart"
  systemctl restart "$SERVICE"
else
  echo "[4/7]-[5/7] Install skipped"
fi
echo "[6/7] Verify live service"
HEALTH=""
for _ in {1..30}; do if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi; sleep 1; done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.49"' <<<"$HEALTH" || fail "health does not report v0.14.9.49"
VODIA_MCP_APP_DIR="$APP" "$TMP/verify.sh"
echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.49 installed and verified."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and retry Verify & Connect. The result will now remain visible and success advances to Marketplace."
