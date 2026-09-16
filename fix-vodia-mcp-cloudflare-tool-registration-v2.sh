#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v2.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v2 ==="

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
  echo "Hotfix v2 failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

printf '%s\n' "[3/7] Relocate Cloudflare tool registrations"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
mi = s.find(marker_text)
if mi < 0:
    raise SystemExit("PATCH ERROR: Cloudflare marker not found")

creator = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s)
if not creator:
    raise SystemExit("PATCH ERROR: createVodiaServer function declaration not found")

# If the marker is already inside createVodiaServer, leave placement unchanged.
if mi > creator.end():
    print("Cloudflare block already appears after createVodiaServer declaration; leaving placement unchanged.")
else:
    start = s.rfind("// -----------------------------------------------------------------------------", 0, mi)
    if start < 0:
        start = mi

    # The Cloudflare block contains four server.registerTool() calls. The next
    # top-level server.registerTool() after those belongs to the original file.
    rel = s[start:]
    positions = [m.start() for m in re.finditer(r'(?m)^server\.registerTool\(', rel)]
    if len(positions) < 5:
        raise SystemExit(f"PATCH ERROR: expected at least 5 server.registerTool calls after Cloudflare marker; found {len(positions)}")
    end = start + positions[4]
    block = s[start:end]
    s2 = s[:start] + s[end:]

    creator2 = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s2)
    if not creator2:
        raise SystemExit("PATCH ERROR: createVodiaServer disappeared after block removal")
    insert_at = creator2.end()
    s = s2[:insert_at] + "\n\n" + block.rstrip() + "\n\n" + s2[insert_at:]
    p.write_text(s)
    print("Moved Cloudflare block into createVodiaServer.")
PY

printf '%s\n' "[4/7] Validate placement and JavaScript"
node --check "$INDEX"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
marker = s.find(marker_text)
creator = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s)
if marker < 0 or not creator:
    raise SystemExit("placement validation failed: required markers missing")
if marker < creator.end():
    raise SystemExit("placement validation failed: Cloudflare block is not inside createVodiaServer")

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
print("PASS: each Cloudflare MCP tool is registered exactly once inside createVodiaServer")
PY

printf '%s\n' "[5/7] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v2-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-v2-health.json || {
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-v2-health.json
echo

printf '%s\n' "[6/7] Verify tool registration with a fresh MCP server construction check"
# Syntax and placement are deterministic; now ensure no duplicate-registration
# error has appeared after this restart before a client reconnects.
sleep 1
if journalctl -u "$SERVICE" --since "30 seconds ago" --no-pager | grep -q 'Tool cloudflare_check_connection is already registered'; then
  journalctl -u "$SERVICE" -n 40 --no-pager || true
  fail "duplicate Cloudflare registration error still present after restart"
fi
echo "PASS: no duplicate Cloudflare registration error after restart"

printf '%s\n' "[7/7] Hotfix v2 installed"
echo "Backup retained at: $BACKUP"
echo "Reconnect the Claude MCP connector or start a fresh Claude chat so it reloads the tool list."
echo "Then test: Check my Cloudflare connection. Do not make any changes."
trap - ERR
