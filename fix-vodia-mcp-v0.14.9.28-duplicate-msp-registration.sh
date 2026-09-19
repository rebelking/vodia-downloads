#!/usr/bin/env bash
# Hotfix v0.14.9.28: move MSP tool registration out of registerPbXReadTool()
# and into createVodiaServer() exactly once.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.28-duplicate-msp-registration-$STAMP"
TMP="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc="${1:-1}"
  echo "Hotfix failed; restoring $BACKUP/index.js" >&2
  cp -a "$BACKUP/index.js" "$INDEX" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
grep -q '0.14.9.28 MSP OAuth customer isolation' "$INDEX" || fail "v0.14.9.28 MSP marker not found"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer not found"
grep -q 'function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool not found"

echo "[1/6] Backup"
mkdir -p "$BACKUP"
cp -a "$INDEX" "$BACKUP/index.js"
echo "PASS: $BACKUP"

echo "[2/6] Stage registration fix — NO LIVE CHANGES"
cp -a "$INDEX" "$TMP"
python3 - "$TMP" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

marker='// v0.14.9.28 MSP OAuth customer isolation'
block_re=re.compile(
    r'\n[ \t]*// v0\.14\.9\.28 MSP OAuth customer isolation\n'
    r'[ \t]*registerMspAuthzTools\(server, \{\n'
    r'[\s\S]*?'
    r'[ \t]*registerMspCustomerConnectionTools\(server, \{\n'
    r'[\s\S]*?'
    r'[ \t]*\}\);\n',
    re.M
)
matches=list(block_re.finditer(s))
if not matches:
    raise SystemExit("PATCH ERROR: MSP registration block not found")

# Remove all existing copies, then insert exactly once in createVodiaServer.
s=block_re.sub('\n', s)

factory=s.find('export function createVodiaServer')
if factory < 0:
    raise SystemExit("PATCH ERROR: createVodiaServer not found")

# Only search after createVodiaServer so we do not hit the helper function definition.
m=re.search(r'^([ \t]*)registerPbXReadTool\(', s[factory:], re.M)
if not m:
    raise SystemExit("PATCH ERROR: registerPbXReadTool call inside createVodiaServer not found")
call=factory+m.start()
indent=m.group(1)

block=(
    f'{indent}// v0.14.9.28 MSP OAuth customer isolation\n'
    f'{indent}registerMspAuthzTools(server, {{\n'
    f'{indent}  z, toolOutputSchema, scopedAudit, scopedSuccess, failure,\n'
    f'{indent}}});\n'
    f'{indent}registerMspCustomerConnectionTools(server, {{\n'
    f'{indent}  z, toolOutputSchema, scopedAudit, scopedSuccess, failure,\n'
    f'{indent}}});\n\n'
)
s=s[:call]+block+s[call:]

if s.count(marker) != 1:
    raise SystemExit(f"PATCH ERROR: expected exactly one MSP marker, found {s.count(marker)}")
p.write_text(s)
PY

node --check "$TMP" >/dev/null || fail "staged index.js syntax invalid"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
factory=s.find('export function createVodiaServer')
helper=s.find('function registerPbXReadTool')
marker=s.find('// v0.14.9.28 MSP OAuth customer isolation')
if min(factory,helper,marker) < 0:
    raise SystemExit("VALIDATION ERROR: expected anchors missing")
if marker < factory:
    raise SystemExit("VALIDATION ERROR: MSP registration is still outside/before createVodiaServer")
if s.count('registerMspAuthzTools(server, {') != 1:
    raise SystemExit("VALIDATION ERROR: registerMspAuthzTools must be called exactly once")
if s.count('registerMspCustomerConnectionTools(server, {') != 1:
    raise SystemExit("VALIDATION ERROR: registerMspCustomerConnectionTools must be called exactly once")
print("PASS: MSP tool registration staged exactly once inside createVodiaServer")
PY

echo "[3/6] Install staged index"
install -o root -g root -m 0644 "$TMP" "$INDEX"
trap 'rollback $?' ERR
echo PASS

echo "[4/6] Restart and health"
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health >"$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "health failed after hotfix"
grep -q '"version":"0.14.9.28"' "$HEALTH" || fail "health did not report v0.14.9.28"
cat "$HEALTH"; echo
echo PASS

echo "[5/6] Verify no duplicate registration exception"
TOKEN="$(python3 - /etc/vodia-mcp.env <<'PY'
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
[[ -n "$TOKEN" ]] || fail "MCP_BEARER_TOKEN missing"

RESP="$(curl -sS -w '\nHTTP_STATUS:%{http_code}\n'   -H "Authorization: Bearer $TOKEN"   -H 'Content-Type: application/json'   -H 'Accept: application/json, text/event-stream'   --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vodia-hotfix-check","version":"1.0"}}}'   http://127.0.0.1:3100/mcp || true)"
echo "$RESP"
grep -q 'HTTP_STATUS:200' <<<"$RESP" || fail "MCP initialize still failing"
grep -q 'serverInfo' <<<"$RESP" || fail "MCP initialize response missing serverInfo"
echo PASS

echo "[6/6] Complete"
trap - ERR
echo "PASS: duplicate MSP tool registration fixed."
echo "Backup retained at: $BACKUP"
