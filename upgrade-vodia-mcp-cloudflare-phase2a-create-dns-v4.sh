#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP Cloudflare Phase 2A installer v4
#
# Goals:
#   - Recover safely from the v3 partial-on-disk state where code patched and
#     syntax-checked successfully but a bad grep-based registration-count check
#     stopped before service restart.
#   - On a clean Phase 1 server, apply the Phase 2A patch with all three live
#     v0.14.7 fixes: import comma handling, structural AWS anchor, and exact
#     registerTool counting.
#   - Always keep a rollback path and verify service health/runtime logs.
#
# No Cloudflare DNS record is created by this installer.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
CF="$APP/cloudflare-integration.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
HEALTH_TMP="/tmp/vodia-cloudflare-phase2a-v4-health.json"
V1_COMMIT="747a1ec34c4e83b9e7d0bff372dbf275651dd4a8"
V1_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${V1_COMMIT}/upgrade-vodia-mcp-cloudflare-phase2a-create-dns-v1.sh"
TMP="$(mktemp /tmp/vodia-cloudflare-phase2a-v4.XXXXXX.sh)"

cleanup(){ rm -f "$TMP" "$HEALTH_TMP" /tmp/vodia-phase2a-v4-errors.txt 2>/dev/null || true; }
trap cleanup EXIT

say_fail(){ echo "FAIL: $*" >&2; }

[[ ${EUID} -eq 0 ]] || { say_fail "Run as root"; exit 1; }
[[ -f "$INDEX" ]] || { say_fail "missing $INDEX"; exit 1; }
[[ -f "$CF" ]] || { say_fail "missing $CF"; exit 1; }
command -v python3 >/dev/null 2>&1 || { say_fail "python3 is required"; exit 1; }
command -v node >/dev/null 2>&1 || { say_fail "node is required"; exit 1; }
command -v wget >/dev/null 2>&1 || { say_fail "wget is required"; exit 1; }

# The latest pre-Phase2A backups are the safest rollback pair for a partial
# install. On a clean server we also take our own v4 snapshots below.
LATEST_INDEX_BAK="$(ls -1t "$INDEX".pre-cloudflare-phase2a.* 2>/dev/null | head -1 || true)"
LATEST_CF_BAK="$(ls -1t "$CF".pre-cloudflare-phase2a.* 2>/dev/null | head -1 || true)"
V4_INDEX_BAK="$INDEX.pre-cloudflare-phase2a-v4.$STAMP"
V4_CF_BAK="$CF.pre-cloudflare-phase2a-v4.$STAMP"
ROLLBACK_INDEX=""
ROLLBACK_CF=""

restore_pair(){
  local idx="${1:-}" cf="${2:-}"
  echo "Restoring known-good Phase 1 files..."
  [[ -n "$idx" && -f "$idx" ]] || { say_fail "rollback index backup missing: $idx"; return 1; }
  [[ -n "$cf" && -f "$cf" ]] || { say_fail "rollback Cloudflare backup missing: $cf"; return 1; }
  cp -a "$idx" "$INDEX"
  cp -a "$cf" "$CF"
  node --check "$INDEX" >/dev/null
  node --check "$CF" >/dev/null
  systemctl restart "$SERVICE"
  for _ in {1..25}; do
    if curl -fsS http://127.0.0.1:3100/health >/dev/null 2>&1; then
      echo "PASS: rollback restored healthy Phase 1 runtime"
      return 0
    fi
    sleep 1
  done
  say_fail "rollback files restored but service health did not return"
  return 1
}

abort_with_rollback(){
  local msg="$1"
  say_fail "$msg"
  if [[ -n "$ROLLBACK_INDEX" && -n "$ROLLBACK_CF" ]]; then
    restore_pair "$ROLLBACK_INDEX" "$ROLLBACK_CF" || true
  fi
  exit 1
}

validate_phase2_disk(){
  node --check "$CF" || return 1
  node --check "$INDEX" || return 1
  grep -q 'export async function createSavedCloudflareARecord' "$CF" || { say_fail "Cloudflare write helper missing"; return 1; }

  python3 - "$INDEX" <<'PY'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()

names = ["cloudflare_plan_create_dns_record", "cloudflare_apply_dns_change"]
for name in names:
    pat = re.compile(r'server\.registerTool\(\s*[\"\']' + re.escape(name) + r'[\"\']')
    count = len(pat.findall(s))
    print(f"{name} exact registration count: {count}")
    if count != 1:
        raise SystemExit(f"VALIDATION ERROR: {name} exact registration count is {count}, expected 1")

# Confirm the new tools live in the existing adminMode block and before the
# first AWS Chime write planner. This prevents a recurrence of the earlier
# nested-helper duplicate-registration bug.
tenant_name = s.find('"plan_create_tenant"')
if tenant_name < 0:
    raise SystemExit("VALIDATION ERROR: plan_create_tenant not found")
admin = s.rfind('if (adminMode) {', 0, tenant_name)
if admin < 0:
    raise SystemExit("VALIDATION ERROR: adminMode block not found")
aws = s.find('"aws_chime_plan_create_voice_connector"', tenant_name)
if aws < 0:
    raise SystemExit("VALIDATION ERROR: AWS Chime planner not found")
for name in names:
    pos = s.find(f'"{name}"', admin)
    if not (admin < pos < aws):
        raise SystemExit(f"VALIDATION ERROR: {name} is not inside the expected adminMode write-tool region")

# Confirm the Cloudflare import block carries the write helper exactly once.
m = re.search(r'import\s*\{(?P<body>.*?)\}\s*from\s*[\"\']\.\/cloudflare-integration\.js[\"\'];', s, re.S)
if not m:
    raise SystemExit("VALIDATION ERROR: Cloudflare import block not found")
import_count = len(re.findall(r'\bcreateSavedCloudflareARecord\b', m.group('body')))
print(f"createSavedCloudflareARecord import count: {import_count}")
if import_count != 1:
    raise SystemExit("VALIDATION ERROR: Cloudflare write helper import count must be 1")

print("PASS: exact registrations, adminMode placement, and import structure verified")
PY
}

restart_and_verify(){
  local since
  since="$(date '+%Y-%m-%d %H:%M:%S')"
  : > "$HEALTH_TMP"
  systemctl restart "$SERVICE" || return 1
  for _ in {1..25}; do
    if curl -fsS http://127.0.0.1:3100/health > "$HEALTH_TMP" 2>/dev/null; then
      break
    fi
    sleep 1
  done
  [[ -s "$HEALTH_TMP" ]] || {
    journalctl -u "$SERVICE" -n 100 --no-pager || true
    say_fail "service did not return healthy"
    return 1
  }
  cat "$HEALTH_TMP"
  echo

  if journalctl -u "$SERVICE" --since "$since" --no-pager \
      | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register' \
      > /tmp/vodia-phase2a-v4-errors.txt; then
    cat /tmp/vodia-phase2a-v4-errors.txt
    say_fail "runtime registration/syntax error detected"
    return 1
  fi
  return 0
}

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2A installer v4 ==="
printf '%s\n' "Handles both clean Phase 1 installs and the v3 partial-on-disk state."
printf '%s\n' "No DNS records or PBX tenants are created by this installer."
echo

HAS_PLAN=0
HAS_APPLY=0
HAS_HELPER=0
grep -q '"cloudflare_plan_create_dns_record"' "$INDEX" && HAS_PLAN=1 || true
grep -q '"cloudflare_apply_dns_change"' "$INDEX" && HAS_APPLY=1 || true
grep -q 'export async function createSavedCloudflareARecord' "$CF" && HAS_HELPER=1 || true

if (( HAS_PLAN || HAS_APPLY || HAS_HELPER )); then
  echo "[1/5] Partial/already-patched Phase 2A state detected on disk"
  echo "plan marker: $HAS_PLAN | apply marker: $HAS_APPLY | helper marker: $HAS_HELPER"
  [[ -n "$LATEST_INDEX_BAK" && -n "$LATEST_CF_BAK" ]] \
    || { say_fail "partial Phase 2A state exists but pre-Phase2A rollback backups were not found"; exit 1; }
  ROLLBACK_INDEX="$LATEST_INDEX_BAK"
  ROLLBACK_CF="$LATEST_CF_BAK"
  echo "rollback index: $ROLLBACK_INDEX"
  echo "rollback Cloudflare module: $ROLLBACK_CF"

  echo "[2/5] Validate patched files with exact registration checks"
  validate_phase2_disk || abort_with_rollback "partial Phase 2A files failed validation"
  echo "PASS"

  echo "[3/5] Restart Vodia MCP to load the validated Phase 2A code"
  restart_and_verify || abort_with_rollback "validated Phase 2A code failed runtime health checks"
  echo "PASS"

  echo "[4/5] Verify Phase 1 tools remain present"
  for t in cloudflare_check_connection cloudflare_get_zone cloudflare_list_dns_records cloudflare_get_dns_record; do
    grep -q "\"$t\"" "$INDEX" || abort_with_rollback "existing Phase 1 tool missing: $t"
  done
  echo "PASS"

  echo "[5/5] Phase 2A recovery/finalization complete"
  echo "New tools loaded on restart:"
  echo "  cloudflare_plan_create_dns_record"
  echo "  cloudflare_apply_dns_change"
  echo "Rollback pair retained:"
  echo "  $ROLLBACK_INDEX"
  echo "  $ROLLBACK_CF"
  echo "Reconnect/start a fresh Claude MCP session so its tool list refreshes."
  exit 0
fi

# Clean Phase 1 path: snapshot current state before running a corrected v1.
echo "[1/7] Clean Phase 1 state detected; create v4 rollback snapshots"
cp -a "$INDEX" "$V4_INDEX_BAK"
cp -a "$CF" "$V4_CF_BAK"
ROLLBACK_INDEX="$V4_INDEX_BAK"
ROLLBACK_CF="$V4_CF_BAK"
echo "index backup: $ROLLBACK_INDEX"
echo "Cloudflare backup: $ROLLBACK_CF"
echo "PASS"

echo "[2/7] Download pinned Phase 2A v1 installer"
wget -q -O "$TMP" "$V1_URL" || abort_with_rollback "could not download pinned v1 installer"
[[ -s "$TMP" ]] || abort_with_rollback "downloaded v1 installer is empty"
echo "PASS"

echo "[3/7] Apply live-layout corrections to installer"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

# Fix 1: Cloudflare import appender must tolerate a pre-existing trailing comma.
old = """if 'createSavedCloudflareARecord' not in body:\n    body = body.rstrip() + ',\\n  createSavedCloudflareARecord,\\n'\n    repl = 'import {' + body + '} from \"./cloudflare-integration.js\";'\n"""
new = """if 'createSavedCloudflareARecord' not in body:\n    body = body.rstrip()\n    if body.endswith(','):\n        body = body[:-1].rstrip()\n    body = body + ',\\n  createSavedCloudflareARecord,\\n'\n    repl = 'import {' + body + '} from \"./cloudflare-integration.js\";'\n"""
if old not in s:
    raise SystemExit('PATCH ERROR: v1 Cloudflare import appender not found')
s = s.replace(old, new, 1)

# Fix 2: locate AWS Chime planner structurally, not by exact whitespace.
start = s.find("anchor2 = '    server.registerTool(")
end = s.find("tools = r'''    server.registerTool(", start)
if start < 0 or end < 0 or end <= start:
    raise SystemExit('PATCH ERROR: v1 AWS Chime anchor block not found')
replacement = r'''tenant_tool_idx = s.find('"plan_create_tenant"')
if tenant_tool_idx < 0:
    raise SystemExit('PATCH ERROR: plan_create_tenant tool not found')
admin_idx = s.rfind('if (adminMode) {', 0, tenant_tool_idx)
if admin_idx < 0:
    raise SystemExit('PATCH ERROR: adminMode block not found before plan_create_tenant')
aws_name_idx = s.find('"aws_chime_plan_create_voice_connector"', tenant_tool_idx)
if aws_name_idx < 0:
    raise SystemExit('PATCH ERROR: aws_chime_plan_create_voice_connector tool not found')
idx2 = s.rfind('server.registerTool(', admin_idx, aws_name_idx)
if idx2 < 0:
    raise SystemExit('PATCH ERROR: AWS Chime server.registerTool not found')
line_start = s.rfind('\n', admin_idx, idx2)
idx2 = admin_idx if line_start < 0 else line_start + 1

'''
s = s[:start] + replacement + s[end:]

# Fix 3: the tool name also appears in scopedAudit(), so grep-counting the raw
# string is not a registration count. Validate exact server.registerTool calls.
old_check = '''[[ "$(grep -c '\"cloudflare_plan_create_dns_record\"' "$INDEX")" -eq 1 ]] || fail "cloudflare_plan_create_dns_record registration count is not 1"\n[[ "$(grep -c '\"cloudflare_apply_dns_change\"' "$INDEX")" -eq 1 ]] || fail "cloudflare_apply_dns_change registration count is not 1"\n'''
new_check = '''python3 - "$INDEX" <<'PYREG'\nimport re, sys\nfrom pathlib import Path\ns = Path(sys.argv[1]).read_text()\nfor name in ("cloudflare_plan_create_dns_record", "cloudflare_apply_dns_change"):\n    count = len(re.findall(r'server\\.registerTool\\(\\s*[\\"\\\']' + re.escape(name) + r'[\\"\\\']', s))\n    print(f"{name} exact registration count: {count}")\n    if count != 1:\n        raise SystemExit(f"{name} exact registration count is {count}, expected 1")\nPYREG\n'''
if old_check not in s:
    raise SystemExit('PATCH ERROR: v1 registration-count check block not found')
s = s.replace(old_check, new_check, 1)

p.write_text(s)
PY

echo "PASS"

echo "[4/7] Validate corrected installer shell syntax"
bash -n "$TMP" || abort_with_rollback "corrected installer shell syntax failed"
echo "PASS"

echo "[5/7] Run corrected Phase 2A installer with outer rollback protection"
chmod 700 "$TMP"
if ! bash "$TMP"; then
  abort_with_rollback "Phase 2A installer failed; v4 restored the pre-install snapshots"
fi
echo "PASS"

echo "[6/7] Independently revalidate final disk state"
validate_phase2_disk || abort_with_rollback "final Phase 2A disk state failed independent v4 validation"
echo "PASS"

echo "[7/7] Confirm service/runtime health"
restart_and_verify || abort_with_rollback "final Phase 2A runtime validation failed"
echo "PASS"
echo
echo "Cloudflare Phase 2A v4 installed successfully."
echo "New tools:"
echo "  cloudflare_plan_create_dns_record"
echo "  cloudflare_apply_dns_change"
echo "Rollback snapshots retained:"
echo "  $ROLLBACK_INDEX"
echo "  $ROLLBACK_CF"
echo "Reconnect/start a fresh Claude MCP session so the new tools are discovered."
