#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP Phase 2D — deterministic customer tenant tool surface
#
# Problem solved:
# Even with Phase 2C routing instructions, an MCP client can still choose the
# low-level tenant-only + Cloudflare-only planners because those tools remain
# visible in the mcp-admin tool list.
#
# Phase 2D makes the customer behavior deterministic:
#   - plan_create_tenant_with_dns and apply_tenant_dns_change stay visible.
#   - plan_create_tenant/apply_tenant_change and the Phase 2A Cloudflare
#     write planners are hidden by default from mcp-admin.
#   - engineers can re-enable those low-level write tools by setting:
#         VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS=1
#     and restarting vodia-mcp.
#
# Read-only Cloudflare tools remain visible. Other Vodia/AWS/etc tools are not
# changed. No DNS record or tenant is created by this installer.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/vodia-phase2d.XXXXXX)"
STAGED="$WORK/index.js"
BACKUP="$INDEX.pre-phase2d-customer-tool-surface.$STAMP"
HEALTH="$WORK/health.json"
LOGS="$WORK/runtime-errors.txt"
PHASE2C_COMMIT="7542348777eeba094920fb4ad7967661afff7e67"
PHASE2C_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${PHASE2C_COMMIT}/upgrade-vodia-mcp-phase2c-customer-tenant-routing-v1.sh"
PHASE2C_TMP="$WORK/phase2c.sh"

cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Phase 2D activation failed; restoring pre-Phase2D index.js..."
  [[ -f "$BACKUP" ]] && cp -a "$BACKUP" "$INDEX" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v wget >/dev/null 2>&1 || fail "wget is required"

echo "=== Vodia MCP Phase 2D — deterministic customer tenant tool surface ==="
echo "Normal tenant creation will expose only the combined tenant + DNS write workflow."
echo "No DNS record or tenant is created by this installer."

echo "[1/7] Ensure Phase 2C routing is installed"
if ! grep -q 'Customer tenant creation routing — Phase 2C' "$INDEX"; then
  echo "Phase 2C marker not found; installing pinned Phase 2C first..."
  wget -q -O "$PHASE2C_TMP" "$PHASE2C_URL"
  [[ -s "$PHASE2C_TMP" ]] || fail "could not download pinned Phase 2C installer"
  bash -n "$PHASE2C_TMP"
  chmod 700 "$PHASE2C_TMP"
  bash "$PHASE2C_TMP"
fi
for marker in \
  '"plan_create_tenant_with_dns"' \
  '"apply_tenant_dns_change"' \
  '"plan_create_tenant"' \
  '"apply_tenant_change"' \
  '"cloudflare_plan_create_dns_record"' \
  '"cloudflare_apply_dns_change"'; do
  grep -q "$marker" "$INDEX" || fail "required tool marker missing: $marker"
done
if grep -q 'Customer tenant tool surface — Phase 2D' "$INDEX"; then
  echo "Phase 2D already appears installed. Exiting without changes."
  exit 0
fi
echo "PASS"

echo "[2/7] Stage current index.js"
cp -a "$INDEX" "$STAGED"
echo "PASS"

echo "[3/7] Hide low-level tenant/DNS write tools by default"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if 'Customer tenant tool surface — Phase 2D' in s:
    raise SystemExit('PATCH ERROR: Phase 2D marker already present unexpectedly')

# Helper: find the beginning of the server.registerTool line that owns a tool name.
def reg_line_start(text, tool_name):
    name_idx = text.find(f'"{tool_name}"')
    if name_idx < 0:
        raise SystemExit(f'PATCH ERROR: tool name not found: {tool_name}')
    reg_idx = text.rfind('server.registerTool(', 0, name_idx)
    if reg_idx < 0:
        raise SystemExit(f'PATCH ERROR: registration start not found: {tool_name}')
    line = text.rfind('\n', 0, reg_idx)
    return 0 if line < 0 else line + 1

# We intentionally use stable neighboring tool registrations as boundaries.
# Current order in the adminMode block is:
#   plan_create_tenant / apply_tenant_change
#   plan_create_tenant_with_dns / apply_tenant_dns_change
#   cloudflare_plan_create_dns_record / cloudflare_apply_dns_change
#   aws_chime_plan_create_voice_connector ...
tenant_start = reg_line_start(s, 'plan_create_tenant')
combined_start = reg_line_start(s, 'plan_create_tenant_with_dns')
cf_start = reg_line_start(s, 'cloudflare_plan_create_dns_record')
aws_start = reg_line_start(s, 'aws_chime_plan_create_voice_connector')

if not (tenant_start < combined_start < cf_start < aws_start):
    raise SystemExit(
        'PATCH ERROR: unexpected admin write-tool order; refusing to patch blindly '
        f'({tenant_start}, {combined_start}, {cf_start}, {aws_start})'
    )

tenant_block = s[tenant_start:combined_start]
cf_block = s[cf_start:aws_start]

for required in ['"plan_create_tenant"', '"apply_tenant_change"']:
    if required not in tenant_block:
        raise SystemExit(f'PATCH ERROR: tenant low-level block missing {required}')
for forbidden in ['"plan_create_tenant_with_dns"', '"apply_tenant_dns_change"']:
    if forbidden in tenant_block:
        raise SystemExit(f'PATCH ERROR: combined tool unexpectedly inside tenant low-level block: {forbidden}')
for required in ['"cloudflare_plan_create_dns_record"', '"cloudflare_apply_dns_change"']:
    if required not in cf_block:
        raise SystemExit(f'PATCH ERROR: Cloudflare low-level block missing {required}')

flag = 'process.env.VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS === "1"'
wrapped_tenant = (
    '    // Customer tenant tool surface — Phase 2D\n'
    '    // Low-level tenant-only writes are opt-in for engineering/advanced use.\n'
    f'    if ({flag}) {{\n' + tenant_block + '    }\n\n'
)
wrapped_cf = (
    '    // Phase 2D: low-level Cloudflare DNS writes are opt-in. Read tools remain available.\n'
    f'    if ({flag}) {{\n' + cf_block + '    }\n\n'
)

# Replace from the end backward so original indexes remain valid.
s = s[:cf_start] + wrapped_cf + s[aws_start:]
s = s[:tenant_start] + wrapped_tenant + s[combined_start:]

# Strengthen the admin instruction so client behavior matches the runtime surface.
needle = 'Customer tenant creation routing: when an administrator asks in natural language to create a new Vodia tenant/domain and the tenant name is inside the configured Cloudflare zone, use plan_create_tenant_with_dns as the preferred planner and apply_tenant_dns_change after the single exact approval.'
replacement = 'Customer tenant creation routing: when an administrator asks in natural language to create a new Vodia tenant/domain and the tenant name is inside the configured Cloudflare zone, MUST use plan_create_tenant_with_dns and then apply_tenant_dns_change after the single exact approval.'
if needle not in s:
    raise SystemExit('PATCH ERROR: Phase 2C admin routing instruction not found')
s = s.replace(needle, replacement, 1)

p.write_text(s)
PY
node --check "$STAGED"
echo "PASS"

echo "[4/7] Validate staged customer tool surface"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()

flag = 'process.env.VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS === "1"'
if s.count(flag) != 2:
    raise SystemExit(f'VALIDATION ERROR: expected 2 low-level exposure gates, found {s.count(flag)}')
if 'Customer tenant tool surface — Phase 2D' not in s:
    raise SystemExit('VALIDATION ERROR: Phase 2D marker missing')
if 'MUST use plan_create_tenant_with_dns' not in s:
    raise SystemExit('VALIDATION ERROR: mandatory combined routing instruction missing')

# Tool registrations should still exist exactly once in source; runtime gating
# controls visibility without deleting implementation or rollback capability.
def reg_count(name):
    return len(re.findall(r'server\.registerTool\(\s*["\']' + re.escape(name) + r'["\']', s, re.S))

for name in [
    'plan_create_tenant_with_dns', 'apply_tenant_dns_change',
    'plan_create_tenant', 'apply_tenant_change',
    'cloudflare_plan_create_dns_record', 'cloudflare_apply_dns_change'
]:
    count = reg_count(name)
    print(f'{name} source registration count: {count}')
    if count != 1:
        raise SystemExit(f'VALIDATION ERROR: {name} source registration count={count}, expected 1')

# Verify the combined tools are not accidentally inside the low-level opt-in gate.
combined_pos = s.find('"plan_create_tenant_with_dns"')
tenant_gate = s.find('// Customer tenant tool surface — Phase 2D')
cf_gate = s.find('// Phase 2D: low-level Cloudflare DNS writes are opt-in.')
if min(combined_pos, tenant_gate, cf_gate) < 0:
    raise SystemExit('VALIDATION ERROR: expected tool/gate positions missing')
if not (tenant_gate < combined_pos < cf_gate):
    raise SystemExit('VALIDATION ERROR: combined planner is not between the two low-level gated blocks')

print('PASS: combined customer workflow remains visible; low-level tenant/DNS write tools are opt-in only')
PY
echo "PASS"

echo "[5/7] Back up live index.js and activate Phase 2D"
cp -a "$INDEX" "$BACKUP"
cp -a "$STAGED" "$INDEX"
trap rollback ERR
node --check "$INDEX"
echo "backup: $BACKUP"
echo "PASS"

echo "[6/7] Restart Vodia MCP and verify runtime"
systemctl restart "$SERVICE"
: > "$HEALTH"
for _ in {1..25}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || {
  journalctl -u "$SERVICE" -n 100 --no-pager || true
  false
}
cat "$HEALTH"
echo
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register|ERR_MODULE' > "$LOGS"; then
  cat "$LOGS"
  false
fi
echo "PASS"

echo "[7/7] Phase 2D installed"
echo "Default customer-facing write tools for tenant creation:"
echo "  plan_create_tenant_with_dns"
echo "  apply_tenant_dns_change"
echo "Low-level tenant-only and Cloudflare-write tools are hidden by default."
echo "Advanced opt-in (only when deliberately needed):"
echo "  VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS=1"
echo "Expected customer request:"
echo "  Create a tenant called test5.audiomercy.com"
echo "Expected approval:"
echo "  APPROVE CREATE test5.audiomercy.com"
echo "Backup retained: $BACKUP"
echo "Reconnect/start a fresh Claude mcp-admin session so the tool list is refreshed."
trap - ERR
