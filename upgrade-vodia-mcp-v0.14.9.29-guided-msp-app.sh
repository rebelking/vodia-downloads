#!/usr/bin/env bash
# Vodia MCP v0.14.9.29 — Guided MSP MCP App
# Adds a visual organization/customer setup UI without exposing raw UUIDs.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="27074d38733a264b6eeae0d3eac3a8eb1cd923a8"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.29-guided-msp-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc="${1:-1}"
  echo "Upgrade failed; restoring $BACKUP" >&2
  for f in index.js version.js msp-authz-v1.js msp-guided-app-v1.js; do
    [[ -e "$BACKUP/$f" ]] && cp -a "$BACKUP/$f" "$APP/$f" || rm -f "$APP/$f"
  done
  if [[ -e "$BACKUP/msp-guided-app.html" ]]; then
    mkdir -p "$APP/ui"
    cp -a "$BACKUP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  else
    rm -f "$APP/ui/msp-guided-app.html"
  fi
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/index.js" "$APP/version.js" "$APP/msp-authz-v1.js"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
REPAIR29=false
if [[ "$CURRENT" == "0.14.9.29" ]]; then
  if ! node --check "$APP/index.js" >/dev/null 2>&1 || ! grep -q 'registerMspGuidedApp' "$APP/index.js" || [[ ! -f "$APP/msp-guided-app-v1.js" ]] || [[ ! -f "$APP/ui/msp-guided-app.html" ]]; then
    REPAIR29=true
    echo "v0.14.9.29 is present but incomplete/broken; repair mode enabled."
  else
    echo "v0.14.9.29 already installed; running verification only."
  fi
elif [[ "$CURRENT" != "0.14.9.28" ]]; then
  fail "expected v0.14.9.28 or v0.14.9.29; found ${CURRENT:-unknown}"
fi

echo "[1/8] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/index.js" "$BACKUP/index.js"
cp -a "$APP/version.js" "$BACKUP/version.js"
cp -a "$APP/msp-authz-v1.js" "$BACKUP/msp-authz-v1.js"
[[ -f "$APP/msp-guided-app-v1.js" ]] && cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/msp-guided-app-v1.js" || true
[[ -f "$APP/ui/msp-guided-app.html" ]] && cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/msp-guided-app.html" || true
echo "PASS: $BACKUP"

if [[ "$CURRENT" != "0.14.9.29" || "$REPAIR29" == "true" ]]; then
  echo "[2/8] Download immutable guided-MSP files"
  curl -fsSL "$RAW_BASE/msp-authz-v1.js" -o "$TMP/msp-authz-v1.js"
  curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
  curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP/msp-guided-app.html"
  grep -q 'msp_list_organizations' "$TMP/msp-authz-v1.js" || fail "organization-list tool missing from staged authz module"
  grep -q 'msp_open_guided_setup' "$TMP/msp-guided-app-v1.js" || fail "guided setup tool missing from staged module"
  grep -q 'Vodia MSP Setup' "$TMP/msp-guided-app.html" || fail "guided UI missing expected title"
  echo PASS

  echo "[3/8] Stage index.js and version.js"
  cp -a "$APP/index.js" "$TMP/index.js"
  cp -a "$APP/version.js" "$TMP/version.js"

  python3 - "$TMP/index.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
imp='import { registerMspGuidedApp } from "./msp-guided-app-v1.js";\n'
if imp not in s:
    # Keep a Unix shebang as the very first line. Node only recognizes it there.
    if s.startswith('#!'):
        first, sep, rest = s.partition('\n')
        s = first + '\n' + imp + rest
    else:
        s = imp + s

if 'registerMspGuidedApp(server, {' not in s:
    factory=s.find('export function createVodiaServer')
    if factory < 0:
        raise SystemExit('PATCH ERROR: createVodiaServer not found')
    tail=s[factory:]
    pat=re.compile(r'(registerMspCustomerConnectionTools\(server,\s*\{[\s\S]*?\}\);\s*)',re.M)
    m=pat.search(tail)
    if not m:
        raise SystemExit('PATCH ERROR: customer connection registration anchor not found')
    insert_at=factory+m.end()
    block='''\n  registerMspGuidedApp(server, {\n    z, toolOutputSchema, scopedAudit, scopedSuccess, failure\n  });\n'''
    s=s[:insert_at]+block+s[insert_at:]

if s.count('registerMspGuidedApp(server, {') != 1:
    raise SystemExit('PATCH ERROR: guided app must register exactly once')
p.write_text(s)
PY

  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.28(["\'])',r'\g<1>0.14.9.29\2',s,count=1)
if n != 1 and '0.14.9.29' not in s:
    raise SystemExit('PATCH ERROR: connector version anchor not found')
p.write_text(s)
PY
  echo PASS

  echo "[4/8] Validate staged files"
  [[ "$(head -n 1 "$TMP/index.js")" == '#!/usr/bin/env node' ]] || fail "staged index.js shebang is not first line"
  [[ "$(grep -n '^#!' "$TMP/index.js" | wc -l)" -eq 1 ]] || fail "staged index.js has misplaced/duplicate shebang"
  node --check "$TMP/index.js"
  node --check "$TMP/msp-authz-v1.js"
  node --check "$TMP/msp-guided-app-v1.js"
  grep -q 'CONNECTOR_VERSION.*0.14.9.29' "$TMP/version.js" || fail "version staging failed"
  echo PASS

  echo "[5/8] Install v0.14.9.29 files"
  trap 'rollback $?' ERR
  install -o root -g root -m 0644 "$TMP/index.js" "$APP/index.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  install -o root -g root -m 0644 "$TMP/msp-authz-v1.js" "$APP/msp-authz-v1.js"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  mkdir -p "$APP/ui"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  echo PASS

  echo "[6/8] Restart MCP"
  systemctl restart "$SERVICE"
else
  echo "[2/8]-[6/8] Install skipped: target version already present"
fi

echo "[7/8] Health and registration checks"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 80 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.29"' <<<"$HEALTH" || fail "health does not report v0.14.9.29"
grep -q '"oauthEnabled":true' <<<"$HEALTH" || fail "OAuth is not enabled"

TOKEN="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("MCP_BEARER_TOKEN="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"": v=v[1:-1]
        print(v,end="")
        break
PY
)"
[[ -n "$TOKEN" ]] || fail "trusted-local MCP token unavailable for verification"

TOOLS="$TMP/tools.out"
curl -sS   -H "Authorization: Bearer $TOKEN"   -H 'Content-Type: application/json'   -H 'Accept: application/json, text/event-stream'   --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'   http://127.0.0.1:3100/mcp >"$TOOLS"

grep -q 'msp_open_guided_setup' "$TOOLS" || fail "guided setup tool not registered"
grep -q 'msp_list_organizations' "$TOOLS" || fail "organization list tool not registered"
echo "PASS: guided tools registered"

RES="$TMP/resources.out"
curl -sS   -H "Authorization: Bearer $TOKEN"   -H 'Content-Type: application/json'   -H 'Accept: application/json, text/event-stream'   --data '{"jsonrpc":"2.0","id":3,"method":"resources/list","params":{}}'   http://127.0.0.1:3100/mcp >"$RES" || true
grep -q 'ui://vodia/msp-guided/mcp-app.html' "$RES"   && echo "PASS: guided UI resource registered"   || echo "WARN: resources/list did not expose guided UI URI; verify through MCP Apps client"

echo "[8/8] Complete"
trap - ERR
echo "PASS: Vodia MCP v0.14.9.29 Guided MSP App installed."
echo "Backup retained at: $BACKUP"
echo "Next: reconnect the OAuth MCP client and call msp_open_guided_setup."
