#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v7.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v7 ==="

printf '%s\n' "[1/8] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer declaration not found"
grep -q 'function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool declaration not found"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
node --check "$INDEX"
printf '%s\n' "PASS"

printf '%s\n' "[2/8] Backup current index.js"
cp -a "$INDEX" "$BACKUP"
printf 'PASS: %s\n' "$BACKUP"

rollback(){
  local rc=$?
  echo "Hotfix v7 failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

printf '%s\n' "[3/8] Relocate Cloudflare block using verified live structure"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
marker = s.find(marker_text)
if marker < 0:
    raise SystemExit("PATCH ERROR: Cloudflare block marker not found")

helper_decl = s.find("function registerPbXReadTool(")
if helper_decl < 0:
    raise SystemExit("PATCH ERROR: registerPbXReadTool declaration not found")

# The broken phase-1 installer inserted the Cloudflare block immediately inside
# registerPbXReadTool(). The block contains exactly four server.registerTool()
# registrations. The fifth server.registerTool() after the marker is the
# original helper implementation, which gives us the exact block boundary.
start = s.rfind("// -----------------------------------------------------------------------------", 0, marker)
if start < helper_decl:
    start = marker

rel = s[start:]
server_regs = [m.start() for m in re.finditer(r'(?m)^[ \t]*server\.registerTool\(', rel)]
if len(server_regs) < 5:
    raise SystemExit(f"PATCH ERROR: expected at least five server.registerTool calls after Cloudflare marker, found {len(server_regs)}")
end = start + server_regs[4]
block = s[start:end]

# Remove the misplaced block, restoring the original helper body.
s2 = s[:start] + s[end:]

# Insert the Cloudflare block immediately before the first normal PBX read-tool
# registration. This keeps the block inside createVodiaServer() but outside the
# registerPbXReadTool() helper.
call_match = re.search(r'(?m)^[ \t]*registerPbXReadTool\(\s*\n?[ \t]*"get_system_status"', s2)
if not call_match:
    search_from = s2.find("function registerPbXReadTool(")
    call_match = re.search(r'(?m)^[ \t]*registerPbXReadTool\(', s2[search_from:])
    if not call_match:
        raise SystemExit("PATCH ERROR: no registerPbXReadTool call found after helper declaration")
    insert_at = search_from + call_match.start()
else:
    insert_at = call_match.start()

s3 = s2[:insert_at] + block.rstrip() + "\n\n" + s2[insert_at:]
p.write_text(s3)
PY

printf '%s\n' "[4/8] Validate source placement"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)")
helper = s.find("function registerPbXReadTool(")
first_call = re.search(r'(?m)^[ \t]*registerPbXReadTool\(\s*\n?[ \t]*"get_system_status"', s)
if marker < 0 or helper < 0 or not first_call:
    raise SystemExit("validation failed: expected markers not found")
if not (helper < marker < first_call.start()):
    raise SystemExit(f"validation failed: expected helper < cloudflare block < first PBX tool call, got helper={helper}, marker={marker}, first_call={first_call.start()}")
for name in (
    'cloudflare_check_connection',
    'cloudflare_get_zone',
    'cloudflare_list_dns_records',
    'cloudflare_get_dns_record',
):
    pattern = rf'server\.registerTool\(\s*"{re.escape(name)}"'
    count = len(re.findall(pattern, s, re.S))
    if count != 1:
        raise SystemExit(f"validation failed: {name} registerTool count is {count}, expected 1")
print("PASS: Cloudflare block is outside registerPbXReadTool and each tool is registered once")
PY

printf '%s\n' "[5/8] Validate JavaScript"
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[6/8] Restart Vodia MCP under its real systemd environment"
systemctl restart "$SERVICE"
rm -f /tmp/vodia-cloudflare-hotfix-v7-health.json
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v7-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-v7-health.json || {
  journalctl -u "$SERVICE" -n 80 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-v7-health.json
echo

printf '%s\n' "[7/8] Check fresh logs"
sleep 1
if journalctl -u "$SERVICE" --since "30 seconds ago" --no-pager | grep -q 'Tool cloudflare_check_connection is already registered'; then
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "duplicate Cloudflare registration error still present after restart"
fi
echo "PASS: no duplicate Cloudflare registration error after restart"

printf '%s\n' "[8/8] Hotfix v7 installed"
echo "Backup retained at: $BACKUP"
echo "Reconnect Claude MCP or start a fresh Claude chat, then run:"
echo "  Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
trap - ERR
