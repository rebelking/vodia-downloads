#!/usr/bin/env bash
# Vodia MCP v0.14.9.35 — guided customer AWS onboarding
# Adds Connect AWS -> STS test/save -> Continue -> region discovery to Vodia Setup.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="f2c137d5d153019a3aa3f2b861ca15dd53b5444b"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
NEW_URI="ui://vodia/msp-guided/v0.14.9.35/mcp-app.html"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.35-guided-aws-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep bash; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
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
  0.14.9.33|0.14.9.34) ;;
  0.14.9.35) echo "v0.14.9.35 already installed; verification mode." ;;
  *) fail "expected v0.14.9.33, v0.14.9.34, or v0.14.9.35; found ${CURRENT:-unknown}" ;;
esac

echo "[1/8] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.35" ]]; then
  echo "[2/8] Download immutable guided AWS files"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"
  curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
  curl -fsSL "$RAW_BASE/verify-vodia-guided-aws-onboarding-v0.14.9.35.sh" -o "$TMP/verify.sh"
  chmod +x "$TMP/verify.sh"

  node --check "$TMP/msp-guided-app-v1.js"
  grep -Fq "$NEW_URI" "$TMP/msp-guided-app-v1.js" || fail "v0.14.9.35 resource URI missing"
  grep -q 'msp_save_customer_aws_connection' "$TMP/msp-guided-app.html" || fail "customer AWS save flow missing"
  grep -q 'aws_list_deployment_regions' "$TMP/msp-guided-app.html" || fail "AWS region step missing"

  mkdir -p "$TMP/staged/ui"
  cp "$TMP/msp-guided-app.html" "$TMP/staged/ui/msp-guided-app.html"
  cp "$TMP/msp-guided-app-v1.js" "$TMP/staged/msp-guided-app-v1.js"
  VODIA_MCP_APP_DIR="$TMP/staged" "$TMP/verify.sh"
  echo PASS

  echo "[3/8] Stage version"
  cp -a "$APP/version.js" "$TMP/version.js"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.(?:33|34)(["\'])',
    r'\g<1>0.14.9.35\2',
    s,
    count=1
)
if n != 1 and '0.14.9.35' not in s:
    raise SystemExit('PATCH ERROR: version anchor not found')
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.35' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[4/8] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  echo PASS

  echo "[5/8] Restart"
  systemctl restart "$SERVICE"
else
  echo "[2/8]-[5/8] Install skipped"
fi

echo "[6/8] Verify live health and UI"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || {
  journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true
  fail "MCP health failed"
}
echo "$HEALTH"
grep -q '"version":"0.14.9.35"' <<<"$HEALTH" || fail "health does not report v0.14.9.35"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"

if [[ ! -f "$TMP/verify.sh" ]]; then
  curl -fsSL "$RAW_BASE/verify-vodia-guided-aws-onboarding-v0.14.9.35.sh" -o "$TMP/verify.sh"
  chmod +x "$TMP/verify.sh"
fi
VODIA_MCP_APP_DIR="$APP" "$TMP/verify.sh"
echo "PASS: live guided AWS UI verified"

echo "[7/8] Verify MCP tool/resource advertisement"
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

  grep -Fq "$NEW_URI" "$TMP/tools.out" || fail "tools/list does not advertise v0.14.9.35 UI URI"
  grep -q 'msp_save_customer_aws_connection' "$TMP/tools.out" || fail "customer AWS save tool not registered"
  grep -q 'aws_list_deployment_regions' "$TMP/tools.out" || fail "AWS region tool not registered"
  echo "PASS: tools/list advertises v0.14.9.35 and AWS onboarding tools"
else
  echo "WARN: trusted-local MCP token unavailable; skipped tools/list verification"
fi

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.35 guided AWS onboarding installed."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and open Vodia setup in a new message."
echo "Test path: customer -> Connect AWS -> Test & Connect -> Continue to AWS -> Load regions."
