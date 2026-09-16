#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-registration-fix-v3.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  fail "Run as root: sudo bash $0"
fi

printf '%s\n' "=== Vodia MCP Cloudflare registration hotfix v3 ==="

printf '%s\n' "[1/8] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'Cloudflare DNS — Phase 1 MCP exposure' "$INDEX" || fail "Cloudflare MCP block not found"
grep -q 'function registerPbXReadTool' "$INDEX" || fail "registerPbXReadTool helper not found"
grep -q 'createVodiaServer' "$INDEX" || fail "createVodiaServer not found"
node --check "$INDEX"
echo "PASS"

printf '%s\n' "[2/8] Backup current index.js"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

rollback(){
  local rc=$?
  echo "Hotfix v3 failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

printf '%s\n' "[3/8] Relocate Cloudflare block outside registerPbXReadTool"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()
marker_text = "// Cloudflare DNS — Phase 1 MCP exposure (read-only)"
mi = s.find(marker_text)
if mi < 0:
    raise SystemExit("PATCH ERROR: Cloudflare marker not found")

# Small JS brace matcher that skips strings, template literals, and comments.
def matching_brace(text, open_pos):
    if text[open_pos] != '{':
        raise ValueError('open_pos is not a brace')
    depth = 0
    i = open_pos
    state = 'code'
    quote = None
    while i < len(text):
        c = text[i]
        n = text[i+1] if i+1 < len(text) else ''
        if state == 'code':
            if c == '/' and n == '/':
                state = 'line_comment'; i += 2; continue
            if c == '/' and n == '*':
                state = 'block_comment'; i += 2; continue
            if c in ('\"', "'", '`'):
                state = 'string'; quote = c; i += 1; continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i
            i += 1; continue
        if state == 'line_comment':
            if c == '\n': state = 'code'
            i += 1; continue
        if state == 'block_comment':
            if c == '*' and n == '/': state = 'code'; i += 2; continue
            i += 1; continue
        if state == 'string':
            if c == '\\': i += 2; continue
            if c == quote:
                state = 'code'; quote = None; i += 1; continue
            i += 1; continue
    raise ValueError('no matching brace found')

creator_m = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s)
helper_m = re.search(r'(?m)^\s*function\s+registerPbXReadTool\s*\([^)]*\)\s*\{', s)
if not creator_m or not helper_m:
    raise SystemExit('PATCH ERROR: required function declarations not found')
creator_open = s.find('{', creator_m.start(), creator_m.end())
helper_open = s.find('{', helper_m.start(), helper_m.end())
creator_close = matching_brace(s, creator_open)
helper_close = matching_brace(s, helper_open)

if not (creator_open < helper_m.start() < helper_close < creator_close):
    raise SystemExit('PATCH ERROR: registerPbXReadTool is not nested inside createVodiaServer as expected')

# Capture the exact Cloudflare block: separator before marker through the end of
# the fourth Cloudflare server.registerTool(...) statement. The next top-level
# server.registerTool is the original PBX registration statement.
start = s.rfind("// -----------------------------------------------------------------------------", 0, mi)
if start < 0:
    start = mi
rel = s[start:]
positions = [m.start() for m in re.finditer(r'(?m)^\s*server\.registerTool\(', rel)]
if len(positions) < 5:
    raise SystemExit(f'PATCH ERROR: expected at least 5 server.registerTool calls after Cloudflare marker, found {len(positions)}')
end = start + positions[4]
block = s[start:end]

# Remove block from its current scope.
s2 = s[:start] + s[end:]

# Re-find helper after removal and insert immediately AFTER helper function.
helper2 = re.search(r'(?m)^\s*function\s+registerPbXReadTool\s*\([^)]*\)\s*\{', s2)
creator2 = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s2)
if not helper2 or not creator2:
    raise SystemExit('PATCH ERROR: function declarations missing after block removal')
helper2_open = s2.find('{', helper2.start(), helper2.end())
helper2_close = matching_brace(s2, helper2_open)
creator2_open = s2.find('{', creator2.start(), creator2.end())
creator2_close = matching_brace(s2, creator2_open)
if not (creator2_open < helper2.start() < helper2_close < creator2_close):
    raise SystemExit('PATCH ERROR: helper scope changed unexpectedly')

insert_at = helper2_close + 1
patched = s2[:insert_at] + "\n\n" + block.rstrip() + "\n\n" + s2[insert_at:]
p.write_text(patched)
print('Moved Cloudflare registrations immediately after registerPbXReadTool, still inside createVodiaServer.')
PY

printf '%s\n' "[4/8] Validate exact scope"
node --check "$INDEX"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
marker = s.find("// Cloudflare DNS — Phase 1 MCP exposure (read-only)")
if marker < 0:
    raise SystemExit('validation failed: marker missing')

def simple_match(text, open_pos):
    depth=0; i=open_pos; state='code'; q=None
    while i < len(text):
        c=text[i]; n=text[i+1] if i+1 < len(text) else ''
        if state=='code':
            if c=='/' and n=='/': state='lc'; i+=2; continue
            if c=='/' and n=='*': state='bc'; i+=2; continue
            if c in ('\"',"'",'`'): state='s'; q=c; i+=1; continue
            if c=='{': depth+=1
            elif c=='}':
                depth-=1
                if depth==0: return i
            i+=1; continue
        if state=='lc':
            if c=='\n': state='code'
            i+=1; continue
        if state=='bc':
            if c=='*' and n=='/': state='code'; i+=2; continue
            i+=1; continue
        if state=='s':
            if c=='\\': i+=2; continue
            if c==q: state='code'; q=None
            i+=1; continue
    raise SystemExit('validation failed: unmatched brace')

creator = re.search(r'(?m)^(?:export\s+)?(?:async\s+)?function\s+createVodiaServer\s*\([^)]*\)\s*\{', s)
helper = re.search(r'(?m)^\s*function\s+registerPbXReadTool\s*\([^)]*\)\s*\{', s)
if not creator or not helper:
    raise SystemExit('validation failed: function declarations missing')
co=s.find('{',creator.start(),creator.end()); cc=simple_match(s,co)
ho=s.find('{',helper.start(),helper.end()); hc=simple_match(s,ho)
if not (co < ho < hc < marker < cc):
    raise SystemExit(f'validation failed: expected createVodiaServer > helper > Cloudflare ordering, got co={co}, ho={ho}, hc={hc}, marker={marker}, cc={cc}')
for name in ('cloudflare_check_connection','cloudflare_get_zone','cloudflare_list_dns_records','cloudflare_get_dns_record'):
    count=len(re.findall(rf'server\.registerTool\(\s*"{re.escape(name)}"', s, re.S))
    if count != 1:
        raise SystemExit(f'validation failed: {name} registration count={count}, expected 1')
print('PASS: Cloudflare registrations are outside registerPbXReadTool and inside createVodiaServer')
PY

printf '%s\n' "[5/8] Show registration locations"
grep -nE 'function registerPbXReadTool|Cloudflare DNS — Phase 1 MCP exposure|"cloudflare_check_connection"|function createVodiaServer' "$INDEX" | head -n 20

printf '%s\n' "[6/8] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-hotfix-v3-health.json 2>/dev/null; then break; fi
  sleep 1
done
test -s /tmp/vodia-cloudflare-hotfix-v3-health.json || {
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
}
cat /tmp/vodia-cloudflare-hotfix-v3-health.json
echo

printf '%s\n' "[7/8] Clear proof window and wait for MCP request"
echo "PASS: service restarted. The duplicate error can only be proven gone when a client creates a fresh MCP session."
echo "Reconnect Claude now, then run the verification command shown below."

printf '%s\n' "[8/8] Hotfix v3 installed"
echo "Backup retained at: $BACKUP"
echo "After reconnecting Claude, verify with:"
echo "  journalctl -u vodia-mcp --since '2 minutes ago' --no-pager | grep -E 'cloudflare_check_connection|already registered|Error:' || true"
echo "Expected: Cloudflare tool activity may appear, but NO 'already registered' error."
trap - ERR
