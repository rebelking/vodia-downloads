#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP Phase 2C — customer-friendly tenant creation routing
#
# Goal: make a request like:
#   "Create a tenant called test4.audiomercy.com"
# naturally select the existing combined Phase 2B workflow instead of creating
# separate Cloudflare and Vodia plans.
#
# This patch:
#   - bootstraps Phase 2B first if the combined tools are not installed yet;
#   - marks plan_create_tenant_with_dns as the preferred customer-facing planner;
#   - marks the separate tenant/DNS planners as low-level standalone tools;
#   - adds explicit admin-endpoint routing instructions for natural-language tenant creation;
#   - shortens the one combined exact approval phrase to:
#         APPROVE CREATE <tenant-fqdn>
#   - tells the client not to surface unrelated pending plans, internal plan IDs,
#     or low-level REST details unless troubleshooting is requested.
#
# No DNS record or PBX tenant is created by this installer.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/vodia-phase2c.XXXXXX)"
STAGED_INDEX="$WORK/index.js"
BACKUP="$INDEX.pre-phase2c-customer-routing.$STAMP"
HEALTH_TMP="$WORK/health.json"
LOG_TMP="$WORK/runtime-errors.txt"
PHASE2B_COMMIT="255ad918e41663aa819ac1c5c54979d4da97b280"
PHASE2B_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${PHASE2B_COMMIT}/upgrade-vodia-mcp-cloudflare-phase2b-tenant-dns-orchestrator-v1.sh"
PHASE2B_TMP="$WORK/phase2b.sh"

cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Phase 2C activation failed; restoring pre-Phase2C index.js..."
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

printf '%s\n' "=== Vodia MCP Phase 2C — customer-friendly tenant creation routing ==="
printf '%s\n' "Natural-language tenant creation should use one combined DNS + tenant plan and one approval."
printf '%s\n' "No DNS record or Vodia tenant is created by this installer."

echo "[1/7] Ensure Phase 2B combined workflow exists"
if ! grep -q '"plan_create_tenant_with_dns"' "$INDEX" || ! grep -q '"apply_tenant_dns_change"' "$INDEX"; then
  echo "Phase 2B combined tools are not present; installing pinned Phase 2B first..."
  wget -q -O "$PHASE2B_TMP" "$PHASE2B_URL"
  [[ -s "$PHASE2B_TMP" ]] || fail "could not download pinned Phase 2B installer"
  bash -n "$PHASE2B_TMP"
  chmod 700 "$PHASE2B_TMP"
  bash "$PHASE2B_TMP"
fi
grep -q '"plan_create_tenant_with_dns"' "$INDEX" || fail "Phase 2B planner is still missing"
grep -q '"apply_tenant_dns_change"' "$INDEX" || fail "Phase 2B apply tool is still missing"
grep -q '"cloudflare_plan_create_dns_record"' "$INDEX" || fail "Phase 2A Cloudflare planner is missing"
grep -q '"plan_create_tenant"' "$INDEX" || fail "low-level Vodia tenant planner is missing"
echo "PASS"

if grep -q 'Customer tenant creation routing — Phase 2C' "$INDEX"; then
  echo "Phase 2C customer routing already appears installed. Exiting without changes."
  exit 0
fi

echo "[2/7] Stage current index.js"
cp -a "$INDEX" "$STAGED_INDEX"
echo "PASS"

echo "[3/7] Patch staged customer-routing instructions and tool descriptions"
python3 - "$STAGED_INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if 'Customer tenant creation routing — Phase 2C' in s:
    raise SystemExit('PATCH ERROR: Phase 2C marker already present unexpectedly')

# 1) Make the admin endpoint explicitly prefer the combined tenant+DNS workflow.
needle = '"This is the policy-controlled system-administrator endpoint. '
if needle not in s:
    raise SystemExit('PATCH ERROR: admin endpoint instruction string not found')
route = (
    '"This is the policy-controlled system-administrator endpoint. '
    'Customer tenant creation routing: when an administrator asks in natural language to create a new Vodia tenant/domain and the tenant name is inside the configured Cloudflare zone, use plan_create_tenant_with_dns as the preferred planner and apply_tenant_dns_change after the single exact approval. Do not split that request into cloudflare_plan_create_dns_record plus plan_create_tenant unless the administrator explicitly asks for standalone changes or the combined planner reports that it cannot be used. Present a short customer-facing summary of the tenant and DNS change plus requiredConfirmation. Do not surface internal plan IDs, low-level REST endpoints, record IDs, or unrelated pending plans unless the administrator asks for troubleshooting or implementation details. '
)
s = s.replace(needle, route, 1)

# 2) Shorten the combined exact approval phrase. The plan remains actor-bound,
# expiring, single-use, conflict re-checked, and contains the full DNS/PBX details.
old_confirmation = 'const requiredConfirmation = `CREATE VODIA TENANT WITH DNS ${normalizedTenant} ${resolved.ipv4} DNS-ONLY`;'
new_confirmation = 'const requiredConfirmation = `APPROVE CREATE ${normalizedTenant}`;'
if old_confirmation not in s:
    raise SystemExit('PATCH ERROR: Phase 2B requiredConfirmation line not found')
s = s.replace(old_confirmation, new_confirmation, 1)

# 3) Strengthen the combined planner description so tool selection is obvious.
old_combined = 'description: "Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record. Checks both sides, creates no changes, defaults the DNS record to DNS-only, and returns one exact confirmation phrase. If ipv4 is omitted, it attempts safe discovery from the configured PBX hostname\'s Cloudflare A record; otherwise supply a verified PBX IPv4.",'
new_combined = 'description: "PREFERRED customer-facing planner for natural-language requests to create a new Vodia tenant/domain when Cloudflare manages that zone. Use this instead of separate tenant and DNS planners. It checks both sides, creates no changes, discovers the PBX IPv4 when possible, defaults DNS to DNS-only/TTL Auto, and returns one concise exact approval phrase.",'
if old_combined not in s:
    raise SystemExit('PATCH ERROR: combined planner description not found')
s = s.replace(old_combined, new_combined, 1)

# 4) Demote the individual planners to explicit standalone/low-level use.
old_tenant = 'description: "Create an expiring guarded plan for one new Vodia tenant/domain. Performs a live duplicate pre-check and makes no PBX change.",'
new_tenant = 'description: "Low-level tenant-only planner. Use for a standalone Vodia tenant creation only when managed DNS is intentionally out of scope or the combined plan_create_tenant_with_dns workflow cannot be used. Performs a live duplicate pre-check and makes no PBX change.",'
if old_tenant not in s:
    raise SystemExit('PATCH ERROR: low-level Vodia tenant planner description not found')
s = s.replace(old_tenant, new_tenant, 1)

old_cf = 'description: "Prepare an expiring, actor-bound plan to create one Cloudflare A record in the configured zone. Performs a live exact-name conflict check and makes no DNS change. For PBX/SIP/Teams hostnames, proxied should normally remain false (DNS only).",'
new_cf = 'description: "Low-level standalone Cloudflare A-record planner. Do not use this for a normal natural-language Vodia tenant creation when plan_create_tenant_with_dns is available. Use it for DNS-only changes. Performs a live exact-name conflict check and makes no DNS change; PBX/SIP/Teams hostnames should remain DNS-only.",'
if old_cf not in s:
    raise SystemExit('PATCH ERROR: low-level Cloudflare planner description not found')
s = s.replace(old_cf, new_cf, 1)

# Add a durable marker immediately before createVodiaServer for validation and
# future upgrades/inspectors.
factory = 'export function createVodiaServer('
idx = s.find(factory)
if idx < 0:
    raise SystemExit('PATCH ERROR: createVodiaServer anchor not found')
marker = '// Customer tenant creation routing — Phase 2C\n// Prefer one combined plan/approval for natural-language tenant creation.\n'
s = s[:idx] + marker + s[idx:]

p.write_text(s)
PY
node --check "$STAGED_INDEX"
echo "PASS"

echo "[4/7] Validate staged routing policy"
python3 - "$STAGED_INDEX" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()

def reg_count(name):
    return len(re.findall(r'server\.registerTool\(\s*["\']' + re.escape(name) + r'["\']', s, re.S))

for name in ['plan_create_tenant_with_dns','apply_tenant_dns_change','plan_create_tenant','cloudflare_plan_create_dns_record']:
    c = reg_count(name)
    print(f"{name} exact registration count: {c}")
    if c != 1:
        raise SystemExit(f"VALIDATION ERROR: {name} registration count is {c}, expected 1")

required = [
    'Customer tenant creation routing — Phase 2C',
    'use plan_create_tenant_with_dns as the preferred planner',
    'Do not split that request into cloudflare_plan_create_dns_record plus plan_create_tenant',
    'Do not surface internal plan IDs',
    'const requiredConfirmation = `APPROVE CREATE ${normalizedTenant}`;',
    'PREFERRED customer-facing planner for natural-language requests',
    'Low-level tenant-only planner.',
    'Low-level standalone Cloudflare A-record planner.',
]
for text in required:
    if text not in s:
        raise SystemExit(f"VALIDATION ERROR: missing routing marker: {text}")

if 'CREATE VODIA TENANT WITH DNS ${normalizedTenant} ${resolved.ipv4} DNS-ONLY' in s:
    raise SystemExit('VALIDATION ERROR: old verbose combined confirmation is still active')

print('PASS: combined workflow is preferred and customer approval phrase is concise')
PY
echo "PASS"

echo "[5/7] Back up live index.js and activate staged Phase 2C"
cp -a "$INDEX" "$BACKUP"
cp -a "$STAGED_INDEX" "$INDEX"
trap rollback ERR
node --check "$INDEX"
echo "backup: $BACKUP"
echo "PASS"

echo "[6/7] Restart Vodia MCP and verify runtime"
systemctl restart "$SERVICE"
: > "$HEALTH_TMP"
for _ in {1..25}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH_TMP" 2>/dev/null; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH_TMP" ]] || {
  journalctl -u "$SERVICE" -n 100 --no-pager || true
  false
}
cat "$HEALTH_TMP"
echo
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register|ERR_MODULE' > "$LOG_TMP"; then
  cat "$LOG_TMP"
  false
fi
echo "PASS"

echo "[7/7] Phase 2C installed"
echo "Preferred customer request:"
echo "  Create a tenant called test4.audiomercy.com"
echo "Expected MCP behavior:"
echo "  plan_create_tenant_with_dns -> ONE concise plan -> ONE approval -> apply_tenant_dns_change -> verify both"
echo "Expected approval phrase:"
echo "  APPROVE CREATE test4.audiomercy.com"
echo "Standalone tools remain available for explicit tenant-only or DNS-only work."
echo "Unrelated pending plans should not be surfaced during this workflow."
echo "Backup retained: $BACKUP"
echo "Reconnect/start a fresh Claude mcp-admin session so the updated server instructions and tool descriptions are loaded."
trap - ERR
