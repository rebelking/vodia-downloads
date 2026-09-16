#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v8.$STAMP"
ARMED=0

restore(){
  echo "Restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
}

fail(){
  echo "FAIL: $*" >&2
  if (( ARMED )); then
    restore
  fi
  exit 1
}

rollback(){
  local rc=$?
  if (( ARMED )); then
    restore
  fi
  exit "$rc"
}

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v8 ==="

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
ARMED=1
trap rollback ERR

printf '%s\n' "[3/8] Relocate Cloudflare block safely and idempotently"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
marker = s.find(marker_text)
helper_decl = s.find("function registerPbXReadTool(")
if marker < 0 or helper_decl < 0:
    raise SystemExit("PATCH ERROR: required Cloudflare/helper markers not found")

# Find the first real registerPbXReadTool(...) call after the helper declaration.
call_match = re.search(r'(?m)^[ \t]*registerPbXReadTool\(', s[helper_decl + 1:])
if not call_match:
    raise SystemExit("PATCH ERROR: no registerPbXReadTool call found after helper declaration")
first_call = helper_decl + 1 + call_match.start()

# Idempotency guard: if Cloudflare block is already between the helper body and
# the first top-level PBX tool registration, the fix has already been applied.
if helper_decl < marker < first_call:
    print("Cloudflare registration fix already appears applied; leaving source unchanged.")
    raise SystemExit(0)

# Broken layout: Cloudflare block is inside registerPbXReadTool(). Determine the
# exact end by locating the fifth server.registerTool() after the block start:
# four belong to Cloudflare, the fifth is the helper's own registration call.
start = s.rfind("// -----------------------------------------------------------------------------", helper_decl, marker)
if start < 0:
    start = marker

rel = s[start:]
server_regs = [m.start() for m in re.finditer(r'(?m)^[ \t]*server\.registerTool\(', rel)]
if len(server_regs) < 5:
    raise SystemExit(f"PATCH ERROR: expected at least five server.registerTool calls after Cloudflare marker, found {len(server_regs)}")
end = start + server_regs[4]
block = s[start:end]

# Remove the misplaced Cloudflare block, restoring the helper implementation.
s2 = s[:start] + s[end:]
helper2 = s2.find("function registerPbXReadTool(")
if helper2 < 0:
    raise SystemExit("PATCH ERROR: helper disappeared after block removal")

# Find first real PBX read-tool call again in the modified source.
call2 = re.search(r'(?m)^[ \t]*registerPbXReadTool\(', s2[helper2 + 1:])
if not call2:
    raise SystemExit("PATCH ERROR: no PBX read-tool call found after block removal")
insert_at = helper2 + 1 + call2.start()

# Sanity-check that the helper still contains exactly one server.registerTool()
# before the first top-level read-tool call.
helper_region = s2[helper2:insert_at]
helper_regs = len(re.findall(r'(?m)^[ \t]*server\.registerTool\(', helper_region))
if helper_regs != 1:
    raise SystemExit(f"PATCH ERROR: helper contains {helper_regs} server.registerTool calls after removal; expected 1")

s3 = s2[:insert_at] + block.rstrip() + "\n\n" + s2[insert_at:]
p.write_text(s3)
print("Moved Cloudflare tool registrations outside registerPbXReadTool().")
PY

printf '%s\n' "[4/8] Validate source placement and JavaScript"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)")
helper = s.find("function registerPbXReadTool(")
call = re.search(r'(?m)^[ \t]*registerPbXReadTool\(', s[helper + 1:] if helper >= 0 else '')
if marker < 0 or helper < 0 or not call:
    raise SystemExit("validation failed: expected markers not found")
first_call = helper + 1 + call.start()
if not (helper < marker < first_call):
    raise SystemExit(f"validation failed: expected helper < cloudflare block < first PBX tool call, got helper={helper}, marker={marker}, first_call={first_call}")
helper_region = s[helper:marker]
helper_regs = len(re.findall(r'(?m)^[ \t]*server\.registerTool\(', helper_region))
if helper_regs != 1:
    raise SystemExit(f"validation failed: helper contains {helper_regs} server.registerTool calls before Cloudflare block; expected 1")
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
print("PASS: Cloudflare block is outside registerPbXReadTool, helper is intact, and each Cloudflare tool is registered once")
PY
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[5/8] Restart Vodia MCP under systemd"
RESTART_TS="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart "$SERVICE"
rm -f /tmp/vodia-cloudflare-hotfix-v8-health.json
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v8-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! test -s /tmp/vodia-cloudflare-hotfix-v8-health.json; then
  journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager || true
  fail "health endpoint did not become ready"
fi
cat /tmp/vodia-cloudflare-hotfix-v8-health.json
echo

printf '%s\n' "[6/8] Check post-restart logs for duplicate registration errors"
if journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager | grep -q 'already registered'; then
  journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager || true
  fail "duplicate tool registration error appeared after restart"
fi
echo "PASS: no duplicate-registration error since this restart"

printf '%s\n' "[7/8] MCP session verification status"
echo "PENDING: authenticated MCP session test is still required."
echo "Reason: /mcp rejects unauthenticated requests before constructing the per-session MCP server."
echo "Reconnect Claude (or another authorized MCP client), then test the Cloudflare tool."

printf '%s\n' "[8/8] Hotfix v8 installed"
echo "Backup retained at: $BACKUP"
echo "After reconnecting Claude, run:"
echo "  Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
echo "Then immediately verify logs with:"
echo "  journalctl -u vodia-mcp --since '$RESTART_TS' --no-pager | grep -iE 'already registered|cloudflare_check_connection|Error:' || true"
ARMED=0
trap - ERR
