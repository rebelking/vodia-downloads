#!/usr/bin/env bash
# Vodia MCP Cloudflare registration hotfix v9.2
#
# Moves the Cloudflare Phase 1 tool block out of registerPbXReadTool().
#
# v9.2 is based on the verified live v0.14.7 layout:
#   registerPbXReadTool() helper
#     -> misplaced Cloudflare block (4 server.registerTool calls)
#     -> helper's own server.registerTool call
#   Microsoft 365 / Entra / Graph Phase 1 section
#   first PBX read-tool registrations
#
# The key change from v9.1 is that helper integrity is bounded by the Microsoft
# Phase 1 section, not by the first registerPbXReadTool() call. The live file has
# several Microsoft server.registerTool() calls between those two points, which
# made v9.1's validation count too many registrations.
#
# Usage:
#   sudo bash fix-vodia-mcp-cloudflare-tool-registration-v9.2.sh --check
#   sudo bash fix-vodia-mcp-cloudflare-tool-registration-v9.2.sh

set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v9.2.$STAMP"
ARMED=0
MODE="apply"

case "${1:-}" in
  "")      ;;
  --check) MODE="check" ;;
  *)       echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

restore(){
  trap - ERR
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

# exit 0 = patched, exit 10 = already applied, anything else = error
patch_file(){
  python3 - "$1" <<'PY'
from pathlib import Path
import re, sys

MARKER = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
AFTER = "// Microsoft 365 / Entra / Graph — Phase 1 (read-only)"
SEP = "// -----------------------------------------------------------------------------"
REG = re.compile(r'(?m)^[ \t]*server\.registerTool\(')

p = Path(sys.argv[1])
s = p.read_text()

marker = s.find(MARKER)
helper = s.find("function registerPbXReadTool(")
after = s.find(AFTER)

if marker < 0 or helper < 0 or after < 0:
    sys.exit("PATCH ERROR: required helper/Cloudflare/Microsoft anchors not found")
if s.find(MARKER, marker + 1) >= 0:
    sys.exit("PATCH ERROR: Cloudflare marker appears more than once")
if s.find(AFTER, after + 1) >= 0:
    sys.exit("PATCH ERROR: Microsoft Phase 1 marker appears more than once")
if not (helper < marker < after):
    sys.exit(f"PATCH ERROR: unexpected anchor order helper={helper} marker={marker} microsoft={after}")

regs_before_marker = len(REG.findall(s, helper, marker))
regs_marker_to_microsoft = len(REG.findall(s, marker, after))

# Desired fixed layout: helper's own registration precedes Cloudflare, and the
# Cloudflare section contains exactly its four registrations before Microsoft.
if regs_before_marker == 1 and regs_marker_to_microsoft == 4:
    print("Already applied: helper ends before the four-tool Cloudflare section.")
    sys.exit(10)

# Known broken layout: Cloudflare begins before the helper's own registerTool.
if regs_before_marker != 0:
    sys.exit(
        f"PATCH ERROR: unknown layout: {regs_before_marker} server.registerTool calls "
        "between helper declaration and Cloudflare marker"
    )

start = s.rfind(SEP, helper, marker)
if start < 0:
    sys.exit("PATCH ERROR: Cloudflare section separator not found")
start = s.rfind("\n", 0, start) + 1

regs_after_start = [m.start() for m in REG.finditer(s, start)]
if len(regs_after_start) < 5:
    sys.exit(
        f"PATCH ERROR: expected at least five server.registerTool calls after "
        f"Cloudflare section start, found {len(regs_after_start)}"
    )

# First four are Cloudflare. Fifth is the helper's own registration.
end = regs_after_start[4]
if end >= after:
    sys.exit("PATCH ERROR: computed Cloudflare block end reaches/passes Microsoft section")

block = s[start:end]
if len(REG.findall(block)) != 4:
    sys.exit("PATCH ERROR: extracted Cloudflare block does not contain exactly four registrations")

# Remove misplaced block.
s2 = s[:start] + s[end:]
helper2 = s2.find("function registerPbXReadTool(")
after2 = s2.find(AFTER)
if helper2 < 0 or after2 < 0 or not (helper2 < after2):
    sys.exit("PATCH ERROR: helper/Microsoft anchors invalid after block removal")

# The verified live structure contains exactly one registration in the helper
# before the Microsoft section starts.
helper_regs = len(REG.findall(s2, helper2, after2))
if helper_regs != 1:
    sys.exit(
        f"PATCH ERROR: helper-to-Microsoft region contains {helper_regs} "
        "server.registerTool calls after removal; expected 1"
    )

# Insert Cloudflare immediately before the Microsoft section separator. This is
# outside registerPbXReadTool() while remaining inside createVodiaServer().
after_start = s2.rfind(SEP, helper2, after2)
if after_start < 0:
    sys.exit("PATCH ERROR: Microsoft section separator not found after block removal")
after_start = s2.rfind("\n", 0, after_start) + 1

s3 = s2[:after_start] + block.rstrip() + "\n\n" + s2[after_start:]
p.write_text(s3)
print("Moved Cloudflare tool registrations after registerPbXReadTool() and before Microsoft Phase 1.")
PY
}

validate_file(){
  python3 - "$1" <<'PY'
from pathlib import Path
import re, sys

MARKER = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
AFTER = "// Microsoft 365 / Entra / Graph — Phase 1 (read-only)"
REG = re.compile(r'(?m)^[ \t]*server\.registerTool\(')

s = Path(sys.argv[1]).read_text()
helper = s.find("function registerPbXReadTool(")
marker = s.find(MARKER)
after = s.find(AFTER)

if helper < 0 or marker < 0 or after < 0:
    sys.exit("validation failed: required anchors not found")
if not (helper < marker < after):
    sys.exit(f"validation failed: order helper={helper} marker={marker} microsoft={after}")

before = len(REG.findall(s, helper, marker))
cloudflare_region = len(REG.findall(s, marker, after))
if before != 1:
    sys.exit(f"validation failed: helper-before-Cloudflare region has {before} registrations; expected 1")
if cloudflare_region != 4:
    sys.exit(f"validation failed: Cloudflare-to-Microsoft region has {cloudflare_region} registrations; expected 4")

for name in (
    "cloudflare_check_connection",
    "cloudflare_get_zone",
    "cloudflare_list_dns_records",
    "cloudflare_get_dns_record",
):
    count = len(re.findall(rf'server\.registerTool\(\s*["\']{re.escape(name)}["\']', s))
    if count != 1:
        sys.exit(f"validation failed: {name} registered {count} times; expected 1")

print("PASS: helper intact, Cloudflare outside helper, four Cloudflare tools registered once")
PY
}

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0 ${1:-}"

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v9.2 ($MODE) ==="

printf '%s\n' "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer declaration not found"
grep -q 'function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool declaration not found"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
grep -q 'Microsoft 365 / Entra / Graph — Phase 1' "$INDEX" || fail "Microsoft Phase 1 anchor not found"
node --check "$INDEX"
echo "PASS"

if [[ $MODE == check ]]; then
  TMPDIR_V92="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_V92"' EXIT
  cp -a "$INDEX" "$TMPDIR_V92/index.js"
  [[ -f "$APP/package.json" ]] && cp -a "$APP/package.json" "$TMPDIR_V92/"

  printf '%s\n' "[2/7] Patch temp copy"
  if patch_file "$TMPDIR_V92/index.js"; then
    rc=0
  else
    rc=$?
  fi

  if (( rc == 10 )); then
    echo "Nothing to do. Live file already has the fix."
    exit 0
  elif (( rc != 0 )); then
    fail "patch step failed on temp copy (rc=$rc); live file untouched"
  fi

  printf '%s\n' "[3/7] Validate temp copy"
  validate_file "$TMPDIR_V92/index.js"
  node --check "$TMPDIR_V92/index.js"
  echo "PASS"

  printf '%s\n' "[4/7] Diff (live -> patched)"
  diff -u "$INDEX" "$TMPDIR_V92/index.js" | head -n 240 || true
  echo
  echo "CHECK ONLY: no files changed, service not restarted."
  echo "Run without --check to apply."
  exit 0
fi

printf '%s\n' "[2/7] Backup current index.js"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"
ARMED=1
trap rollback ERR

printf '%s\n' "[3/7] Relocate Cloudflare block"
if patch_file "$INDEX"; then
  rc=0
else
  rc=$?
fi

if (( rc == 10 )); then
  ARMED=0
  trap - ERR
  rm -f "$BACKUP"
  echo "Nothing to do. No restart performed."
  exit 0
elif (( rc != 0 )); then
  fail "patch step failed (rc=$rc)"
fi

printf '%s\n' "[4/7] Validate source placement and JavaScript"
validate_file "$INDEX"
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[5/7] Restart Vodia MCP under systemd"
RESTART_TS="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart "$SERVICE"

HEALTH="/tmp/vodia-cloudflare-hotfix-v9.2-health.json"
rm -f "$HEALTH"
for _ in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >"$HEALTH" 2>/dev/null; then
    break
  fi
  sleep 1
done

if ! test -s "$HEALTH"; then
  journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager || true
  fail "health endpoint did not become ready"
fi
cat "$HEALTH"
echo

printf '%s\n' "[6/7] Check post-restart logs"
sleep 1
POST_LOGS="$(journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager 2>/dev/null || true)"
if grep -q 'already registered' <<<"$POST_LOGS"; then
  printf '%s\n' "$POST_LOGS"
  fail "duplicate tool registration error appeared after restart"
fi
echo "PASS: no duplicate-registration error since restart"

printf '%s\n' "[7/7] Hotfix v9.2 installed"
ARMED=0
trap - ERR
echo "Backup retained at: $BACKUP"
echo
echo "PENDING: authenticated MCP session verification is still required."
echo "Reconnect the Vodia connector in Claude, then ask:"
echo "  Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
echo
echo "Then check logs:"
echo "  journalctl -u $SERVICE --since '$RESTART_TS' --no-pager | grep -iE 'already registered|cloudflare|Error:' || true"
echo
echo "Manual rollback if needed:"
echo "  cp -a '$BACKUP' '$INDEX' && systemctl restart $SERVICE"
