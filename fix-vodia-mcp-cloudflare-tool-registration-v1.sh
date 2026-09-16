#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix ==="

printf '%s\n' "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
grep -q 'function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool helper not found"
grep -q 'createVodiaServer' "$INDEX" || fail "createVodiaServer not found"
node --check "$INDEX"
printf '%s\n' "PASS"

printf '%s\n' "[2/7] Backup current index.js"
cp -a "$INDEX" "$BACKUP"
printf 'PASS: %s\n' "$BACKUP"

rollback(){
  local rc=$?
  echo "Hotfix failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

printf '%s\n' "[3/7] Move Cloudflare registrations out of registerPbXReadTool"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
mi = s.find(marker)
if mi < 0:
    raise SystemExit("PATCH ERROR: Cloudflare marker not found")

# Include the separator line immediately above the marker when present.
start = s.rfind("// -----------------------------------------------------------------------------", 0, mi)
if start < 0:
    start = mi

# The broken installer inserted the block immediately before the first
# server.registerTool() call, which is inside registerPbXReadTool(). The block
# itself contains exactly four server.registerTool() calls. Therefore the fifth
# occurrence after the marker is the original helper registration call.
positions = [m.start() for m in re.finditer(r'(?m)^server\.registerTool\(', s[start:])]
if len(positions) < 5:
    raise SystemExit(f"PATCH ERROR: expected at least 5 server.registerTool calls after Cloudflare marker; found {len(positions)}")
end = start + positions[4]
block = s[start:end]

# Remove the misplaced block.
s2 = s[:start] + s[end:]

# Find createVodiaServer function and insert the block once, immediately inside
# its body. Support both exported and non-exported function declarations.
m = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s2)
if not m:
    raise SystemExit("PATCH ERROR: createVodiaServer function declaration not found")
insert_at = m.end()

# Keep the block visually separated. It executes once for each new MCP server,
# which is the correct scope for server.registerTool().
s2 = s2[:insert_at] + "\n\n" + block.rstrip() + "\n\n" + s2[insert_at:]

p.write_text(s2)
PY

printf '%s\n' "[4/7] Validate placement and JavaScript"
node --check "$INDEX"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)")
helper = s.find("function registerPbXReadTool")
creator_match = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s)
if marker < 0 or helper < 0 or not creator_match:
    raise SystemExit("placement validation failed: required markers missing")
creator = creator_match.start()
if helper < marker < creator:
    raise SystemExit("placement validation failed: Cloudflare block is still inside/before createVodiaServer")
if marker < creator_match.end():
    raise SystemExit("placement validation failed: Cloudflare block was not moved into createVodiaServer")
for name in (
    'cloudflare_check_connection',
    'cloudflare_get_zone',
    'cloudflare_list_dns_records',
    'cloudflare_get_dns_record',
):
    if s.count(f'"{name}"') != 1:
        raise SystemExit(f"placement validation failed: {name} registration marker count is {s.count(f'\"{name}\"')}, expected 1")
print("PASS: Cloudflare tools are registered once inside createVodiaServer")
PY

printf '%s\n' "[5/7] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-health.json || {
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-health.json
echo

printf '%s\n' "[6/7] Check fresh service log for duplicate registration errors"
sleep 1
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -q 'Tool cloudflare_check_connection is already registered'; then
  # Old requests from before this exact restart can still be inside a wide time window,
  # so only warn here. The real proof is a fresh MCP client connection after install.
  echo "WARN: duplicate-registration text exists in the recent journal window. Reconnect Claude and retest; if a new timestamp appears, collect the latest 40 log lines."
else
  echo "PASS: no duplicate Cloudflare registration error in recent service log"
fi

printf '%s\n' "[7/7] Hotfix installed"
echo "Backup retained at: $BACKUP"
echo "Next: reconnect the Claude MCP connector so it creates a fresh MCP server session and reloads the corrected tool list."
echo "Then test: Check my Cloudflare connection. Do not make any changes."
trap - ERR
