#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v4.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v4 ==="
printf '%s\n' "[1/8] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q '^export function createVodiaServer' "$INDEX" || fail "createVodiaServer declaration not found"
grep -q '^  function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool declaration not found"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare block marker not found"
grep -q '^  registerPbXReadTool(' "$INDEX" || fail "No top-level registerPbXReadTool invocation found"
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[2/8] Backup"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

rollback(){
  local rc=$?
  echo "Hotfix v4 failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

printf '%s\n' "[3/8] Move Cloudflare block outside registerPbXReadTool"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
mi = s.find(marker_text)
if mi < 0:
    raise SystemExit("PATCH ERROR: Cloudflare marker not found")

# Start at the separator immediately above the marker.
start = s.rfind("// -----------------------------------------------------------------------------", 0, mi)
if start < 0:
    start = mi

# The Cloudflare block contains 4 server.registerTool calls. The 5th occurrence
# after the marker is the original PBX helper's own server.registerTool call.
rel = s[start:]
positions = [m.start() for m in re.finditer(r'(?m)^  server\.registerTool\(', rel)]
if len(positions) < 5:
    raise SystemExit(f"PATCH ERROR: expected at least 5 indented server.registerTool calls after Cloudflare block start; found {len(positions)}")
end = start + positions[4]
block = s[start:end].rstrip() + "\n\n"

# Remove the block from inside registerPbXReadTool.
s2 = s[:start] + s[end:]

# Insert it immediately before the first top-level invocation of registerPbXReadTool.
# In this build that is after the helper function has closed and still inside createVodiaServer.
anchor_match = re.search(r'(?m)^  registerPbXReadTool\(', s2)
if not anchor_match:
    raise SystemExit("PATCH ERROR: top-level registerPbXReadTool invocation anchor not found")
insert_at = anchor_match.start()
s3 = s2[:insert_at] + block + s2[insert_at:]
p.write_text(s3)
PY

printf '%s\n' "[4/8] Validate exact placement"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)")
helper_decl = s.find("  function registerPbXReadTool(")
first_top_level_call = re.search(r'(?m)^  registerPbXReadTool\(', s)
if marker < 0 or helper_decl < 0 or not first_top_level_call:
    raise SystemExit("validation failed: required markers missing")
# Marker must be after helper declaration and before first top-level invocation.
# More importantly, it must no longer be between helper declaration and the helper's
# first own server.registerTool call.
helper_server = s.find("  server.registerTool(", helper_decl)
if helper_server < 0:
    raise SystemExit("validation failed: helper server.registerTool not found")
if helper_decl < marker < helper_server:
    raise SystemExit("validation failed: Cloudflare block is still inside registerPbXReadTool")
if not (marker < first_top_level_call.start()):
    raise SystemExit("validation failed: Cloudflare block is not before PBX tool registrations")
for name in (
    "cloudflare_check_connection",
    "cloudflare_get_zone",
    "cloudflare_list_dns_records",
    "cloudflare_get_dns_record",
):
    count = len(re.findall(rf'server\.registerTool\(\s*"{re.escape(name)}"', s, re.S))
    if count != 1:
        raise SystemExit(f"validation failed: {name} registerTool count is {count}, expected 1")
print("PASS: Cloudflare block is outside registerPbXReadTool and each tool is registered once")
PY

printf '%s\n' "[5/8] Validate JavaScript"
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[6/8] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v4-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-v4-health.json || {
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-v4-health.json
echo

printf '%s\n' "[7/8] Trigger fresh MCP server construction locally"
# An unauthenticated request should return 401. We only use it to exercise the HTTP path.
HTTP_CODE="$(curl -sS -o /tmp/vodia-cloudflare-hotfix-v4-mcp.txt -w '%{http_code}' http://127.0.0.1:3100/mcp || true)"
[[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "405" ]] || echo "INFO: local /mcp returned HTTP $HTTP_CODE"
sleep 1
if journalctl -u "$SERVICE" --since "30 seconds ago" --no-pager | grep -q 'Tool cloudflare_check_connection is already registered'; then
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  fail "duplicate Cloudflare registration error still present"
fi
echo "PASS: no duplicate Cloudflare registration error after restart"

printf '%s\n' "[8/8] Hotfix v4 installed"
echo "Backup retained at: $BACKUP"
echo "Reconnect Claude and run: Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
trap - ERR
