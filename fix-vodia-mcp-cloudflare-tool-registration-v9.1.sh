#!/usr/bin/env bash
# Vodia MCP Cloudflare registration hotfix v9.1
#
# Moves the Cloudflare tool block out of registerPbXReadTool() so the four
# cloudflare_* tools are registered once per MCP server instead of once per
# PBX read tool.
#
# Usage:
#   sudo bash fix-vodia-mcp-cloudflare-tool-registration-v9.1.sh --check   # dry run, no changes
#   sudo bash fix-vodia-mcp-cloudflare-tool-registration-v9.1.sh         # apply + restart
#
# Changes in v9.1:
#   - patch_file is called in an `if` context so rc=10 ("already applied")
#     no longer trips the ERR trap (set +e does not suppress ERR under set -E).
#   - restore() disarms the ERR trap first so a failing restore cannot recurse.
#
# Changes from v8 (v9):
#   - Idempotency guard also requires the helper's own server.registerTool()
#     to sit before the Cloudflare marker (v8's guard matched the broken layout).
#   - Unknown layouts abort instead of being cut.
#   - Post-restart log check reads journalctl into a variable first
#     (avoids SIGPIPE + pipefail false PASS).
#   - --check mode patches a temp copy, validates it, shows the diff, exits.

set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v9.1.$STAMP"
ARMED=0
MODE="apply"

case "${1:-}" in
  "")        ;;
  --check)   MODE="check" ;;
  *)         echo "Usage: $0 [--check]" >&2; exit 2 ;;
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

# ---------------------------------------------------------------------------
# Patch: exit 0 = patched, exit 10 = already applied, anything else = error
# ---------------------------------------------------------------------------
patch_file(){
  python3 - "$1" <<'PY'
from pathlib import Path
import re, sys

MARKER = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
SEP = "// -----------------------------------------------------------------------------"
REG = re.compile(r'(?m)^[ \t]*server\.registerTool\(')
CALL = re.compile(r'(?m)^[ \t]*registerPbXReadTool\(')

p = Path(sys.argv[1])
s = p.read_text()

marker = s.find(MARKER)
helper = s.find("function registerPbXReadTool(")
if marker < 0 or helper < 0:
    sys.exit("PATCH ERROR: Cloudflare marker or helper declaration not found")
if s.find(MARKER, marker + 1) >= 0:
    sys.exit("PATCH ERROR: Cloudflare marker appears more than once")

m = CALL.search(s, helper + 1)
if not m:
    sys.exit("PATCH ERROR: no registerPbXReadTool(...) call after helper declaration")
first_call = m.start()

if not (helper < marker < first_call):
    sys.exit(f"PATCH ERROR: unexpected layout (helper={helper}, marker={marker}, first_call={first_call})")

regs_before_marker = len(REG.findall(s, helper, marker))

# Fixed layout: helper body (with its one registerTool) comes before the block.
if regs_before_marker == 1:
    print("Already applied: Cloudflare block sits after the helper body.")
    sys.exit(10)

# Anything other than the known broken layout: stop.
if regs_before_marker != 0:
    sys.exit(f"PATCH ERROR: unexpected layout ({regs_before_marker} registerTool calls between helper and marker)")

# Broken layout: block is the first thing inside the helper body.
start = s.rfind(SEP, helper, marker)
if start < 0:
    start = marker
start = s.rfind("\n", 0, start) + 1   # include the line's leading indentation

regs_after = [r.start() for r in REG.finditer(s, start)]
if len(regs_after) < 5:
    sys.exit(f"PATCH ERROR: expected >=5 server.registerTool calls after block start, found {len(regs_after)}")
end = regs_after[4]            # 4 Cloudflare tools, 5th is the helper's own
if end > first_call:
    sys.exit("PATCH ERROR: computed block end runs past the first PBX read-tool call")
block = s[start:end]

if len(REG.findall(block)) != 4:
    sys.exit("PATCH ERROR: extracted block does not contain exactly 4 registerTool calls")

s2 = s[:start] + s[end:]

helper2 = s2.find("function registerPbXReadTool(")
m2 = CALL.search(s2, helper2 + 1)
if helper2 < 0 or not m2:
    sys.exit("PATCH ERROR: helper or first PBX call missing after block removal")
insert_at = m2.start()

if len(REG.findall(s2, helper2, insert_at)) != 1:
    sys.exit("PATCH ERROR: helper does not contain exactly 1 server.registerTool after removal")

s3 = s2[:insert_at] + block.rstrip() + "\n\n" + s2[insert_at:]
p.write_text(s3)
print("Moved Cloudflare tool registrations outside registerPbXReadTool().")
PY
}

# ---------------------------------------------------------------------------
# Validate the fixed layout
# ---------------------------------------------------------------------------
validate_file(){
  python3 - "$1" <<'PY'
from pathlib import Path
import re, sys

MARKER = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
REG = re.compile(r'(?m)^[ \t]*server\.registerTool\(')
CALL = re.compile(r'(?m)^[ \t]*registerPbXReadTool\(')

s = Path(sys.argv[1]).read_text()
marker = s.find(MARKER)
helper = s.find("function registerPbXReadTool(")
m = CALL.search(s, helper + 1) if helper >= 0 else None
if marker < 0 or helper < 0 or not m:
    sys.exit("validation failed: expected markers not found")

if not (helper < marker < m.start()):
    sys.exit(f"validation failed: order helper={helper} marker={marker} first_call={m.start()}")

n = len(REG.findall(s, helper, marker))
if n != 1:
    sys.exit(f"validation failed: helper has {n} server.registerTool calls before Cloudflare block; expected 1")

for name in ("cloudflare_check_connection", "cloudflare_get_zone",
             "cloudflare_list_dns_records", "cloudflare_get_dns_record"):
    c = len(re.findall(rf'server\.registerTool\(\s*["\']{re.escape(name)}["\']', s))
    if c != 1:
        sys.exit(f"validation failed: {name} registered {c} times; expected 1")

print("PASS: block outside helper, helper intact, each Cloudflare tool registered once")
PY
}

# ---------------------------------------------------------------------------
[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0 ${1:-}"

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v9.1 ($MODE) ==="

printf '%s\n' "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer declaration not found"
grep -q 'function registerPbXReadTool' "$INDEX"      || fail "registerPbXReadTool declaration not found"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
node --check "$INDEX"
echo "PASS"

# --- dry run ---------------------------------------------------------------
if [[ $MODE == check ]]; then
  TMPDIR_V9="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_V9"' EXIT
  # Keep .js next to package.json semantics irrelevant for --check; syntax only.
  cp -a "$INDEX" "$TMPDIR_V9/index.js"
  [[ -f "$APP/package.json" ]] && cp -a "$APP/package.json" "$TMPDIR_V9/"

  printf '%s\n' "[2/7] Patch temp copy"
  if patch_file "$TMPDIR_V9/index.js"; then
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
  validate_file "$TMPDIR_V9/index.js"
  node --check "$TMPDIR_V9/index.js"
  echo "PASS"

  printf '%s\n' "[4/7] Diff (live -> patched)"
  diff -u "$INDEX" "$TMPDIR_V9/index.js" | head -n 200 || true
  echo
  echo "CHECK ONLY: no files changed, service not restarted."
  echo "Run without --check to apply."
  exit 0
fi

# --- apply -----------------------------------------------------------------
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
  ARMED=0; trap - ERR
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

HEALTH="/tmp/vodia-cloudflare-hotfix-v9.1-health.json"
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
cat "$HEALTH"; echo

printf '%s\n' "[6/7] Check post-restart logs"
sleep 1
POST_LOGS="$(journalctl -u "$SERVICE" --since "$RESTART_TS" --no-pager 2>/dev/null || true)"
if grep -q 'already registered' <<<"$POST_LOGS"; then
  printf '%s\n' "$POST_LOGS"
  fail "duplicate tool registration error appeared after restart"
fi
echo "PASS: no duplicate-registration error since restart"

printf '%s\n' "[7/7] Hotfix v9.1 installed"
ARMED=0
trap - ERR
echo "Backup retained at: $BACKUP"
echo
echo "PENDING: /mcp needs an authenticated session to build the per-session server."
echo "Reconnect the Vodia connector in Claude, then ask:"
echo "  Use Vodia MCP and run cloudflare_check_connection. Do not make any changes."
echo
echo "Then check logs:"
echo "  journalctl -u $SERVICE --since '$RESTART_TS' --no-pager | grep -iE 'already registered|cloudflare|Error:' || true"
echo
echo "Manual rollback if needed:"
echo "  cp -a '$BACKUP' '$INDEX' && systemctl restart $SERVICE"
