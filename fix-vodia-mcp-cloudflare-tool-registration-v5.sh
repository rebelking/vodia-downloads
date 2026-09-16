#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v5.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

echo "=== Vodia MCP Cloudflare registration hotfix v5 ==="

echo "[1/9] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer export not found"
grep -Eq '^[[:space:]]*function registerPbXReadTool\(' "$INDEX" || fail "registerPbXReadTool declaration not found"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
grep -q '"get_system_status"' "$INDEX" || fail "get_system_status anchor not found"
node --check "$INDEX"
echo "PASS"

echo "[2/9] Backup current index.js"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

rollback(){
  local rc=$?
  echo "Hotfix v5 failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

echo "[3/9] Relocate Cloudflare block using the verified v0.14.7 structure"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"

# Verified live structure supplied from the server:
#   export function createVodiaServer(...) {
#     ...
#     function registerPbXReadTool(...) {
#       [Cloudflare block was accidentally inserted here]
#       server.registerTool(name, ...)
#     }
#     ...
#     registerPbXReadTool("get_system_status", ...)

creator = s.find("export function createVodiaServer")
helper = s.find("function registerPbXReadTool", creator)
marker = s.find(marker_text, helper)
if creator < 0 or helper < 0 or marker < 0:
    raise SystemExit("PATCH ERROR: expected verified anchors are missing")

# Start at the separator immediately above the Cloudflare marker if present.
start = s.rfind("// -----------------------------------------------------------------------------", helper, marker)
if start < 0:
    start = marker
# Preserve the indentation that belongs to the surrounding createVodiaServer body.
line_start = s.rfind("\n", 0, start) + 1
start = line_start

# The normal registerPbXReadTool helper body calls server.registerTool with deeper
# indentation (4 spaces in this build). The Cloudflare registrations are at the
# createVodiaServer indentation level (2 spaces). This is the first original
# helper-body registration after the accidental block and is therefore a stable
# end anchor for removing only the Cloudflare block.
helper_body = re.search(r'(?m)^\s{4}server\.registerTool\(', s[marker:])
if not helper_body:
    raise SystemExit("PATCH ERROR: original registerPbXReadTool body anchor not found")
end = marker + helper_body.start()

block = s[start:end]
for name in (
    "cloudflare_check_connection",
    "cloudflare_get_zone",
    "cloudflare_list_dns_records",
    "cloudflare_get_dns_record",
):
    if f'"{name}"' not in block:
        raise SystemExit(f"PATCH ERROR: extracted Cloudflare block is missing {name}")

# Remove the misplaced block.
s2 = s[:start] + s[end:]

# Insert once immediately before the first normal top-level PBX read-tool
# registration. This location is inside createVodiaServer but outside the helper.
target = re.search(r'(?m)^\s{2}registerPbXReadTool\(\s*\n\s{4}"get_system_status"', s2)
if not target:
    raise SystemExit("PATCH ERROR: top-level get_system_status registration anchor not found")
insert_at = target.start()

# Normalize the extracted block to the createVodiaServer indentation level.
# It already has that indentation in the broken file, so preserve it verbatim.
s3 = s2[:insert_at] + block.rstrip() + "\n\n" + s2[insert_at:]
p.write_text(s3)
print("Moved Cloudflare MCP tools outside registerPbXReadTool and before get_system_status.")
PY

echo "[4/9] Validate JavaScript"
node --check "$INDEX"
echo "PASS"

echo "[5/9] Validate exact placement"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
creator = s.find("export function createVodiaServer")
helper = s.find("function registerPbXReadTool", creator)
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)", creator)
first_pbxtool = s.find('registerPbXReadTool(\n    "get_system_status"', helper)
if min(creator, helper, marker, first_pbxtool) < 0:
    raise SystemExit("placement validation failed: required anchors missing")
if marker < helper:
    raise SystemExit("placement validation failed: Cloudflare block appears before helper declaration")
if marker < first_pbxtool:
    # This is expected only if the block is after the helper body; prove it is not
    # still inside the helper by ensuring the helper's own server.registerTool call
    # occurs before the Cloudflare marker.
    original_helper_call = s.find("    server.registerTool(", helper)
    if original_helper_call < 0 or original_helper_call > marker:
        raise SystemExit("placement validation failed: Cloudflare block is still inside registerPbXReadTool")
else:
    raise SystemExit("placement validation failed: Cloudflare block is not before first PBX tool registration")

for name in (
    'cloudflare_check_connection',
    'cloudflare_get_zone',
    'cloudflare_list_dns_records',
    'cloudflare_get_dns_record',
):
    pattern = rf'server\.registerTool\(\s*"{re.escape(name)}"'
    count = len(re.findall(pattern, s, re.S))
    if count != 1:
        raise SystemExit(f"placement validation failed: {name} registerTool count is {count}, expected 1")
print("PASS: Cloudflare tools are outside registerPbXReadTool and registered exactly once")
PY

echo "[6/9] Construct one MCP server in-process"
if ! timeout 20s node --input-type=module -e "import('file://$INDEX').then(m => { m.createVodiaServer(); console.log('PASS: createVodiaServer constructed without duplicate tool registration'); }).catch(e => { console.error(e); process.exit(1); })"; then
  fail "createVodiaServer construction test failed"
fi

echo "[7/9] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v5-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-v5-health.json || {
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-v5-health.json
echo

echo "[8/9] Check fresh service log"
sleep 1
if journalctl -u "$SERVICE" --since "30 seconds ago" --no-pager | grep -q 'Tool cloudflare_check_connection is already registered'; then
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  fail "duplicate Cloudflare registration error still present"
fi
echo "PASS: no duplicate Cloudflare registration error after restart"

echo "[9/9] Hotfix v5 installed"
echo "Backup retained at: $BACKUP"
echo "Reconnect the Claude Vodia MCP connector or start a fresh Claude chat."
echo "Then ask: Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
trap - ERR
