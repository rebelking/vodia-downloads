#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.11 — tenant display name
#
# Adds a required human-readable display_name to both guarded tenant creation paths:
#   - Vodia-native tenant creation
#   - Cloudflare DNS-FIRST + Vodia tenant creation
#
# The display value is written only AFTER the tenant exists. The patch first reads
# the tenant's current /rest/domain/{tenant}/config, preserves the known config
# fields, changes only display, POSTs the merged config, then reads it back and
# requires an exact display match before reporting success.
#
# Existing v0.14.9.10 provider-choice behavior and the v0.14.9.9 Cloudflare
# DNS-FIRST/public-resolver/rollback behavior are preserved.
#
# This installer itself performs no tenant or DNS writes.

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.11-tenant-display-name-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
LOGS="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH" "$LOGS"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring v0.14.9.10 files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.11 — tenant display name ==="
echo "Adds required display_name to Vodia-native and Cloudflare tenant creation."
echo "This installer performs no tenant or DNS writes."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
for marker in \
  'v0.14.9.10 DNS provider choice routing' \
  '"get_tenant_dns_provider_choices"' \
  'async function planCreateTenantWithDns' \
  'async function applyCreateTenantWithDns' \
  'async function planCreateTenant' \
  'setAndVerifyTenantCountryCode' \
  'readTenantSystemInfo' \
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS' \
  'deleteSavedCloudflareDnsRecordById'; do
  grep -q "$marker" "$INDEX" || fail "required current capability missing: $marker"
done
grep -q '0.14.9.10' "$VERSION" || fail "expected installed base version 0.14.9.10"
if grep -q 'v0.14.9.11 tenant display-name support' "$INDEX"; then
  echo "v0.14.9.11 already appears installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/8] Backup + stage"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"

echo "[3/8] Patch tenant display-name planning, write, and verification"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text()
marker='v0.14.9.11 tenant display-name support'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.11 marker already present')

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'PATCH ERROR: expected one {label}; found {n}')
    s=s.replace(old,new,1)

# Add a dedicated display helper immediately before the combined planner. We do
# not replace the proven country-code helper. This keeps the current country flow
# intact and adds one narrow config update after country verification.
anchor='async function planCreateTenantWithDns('
if s.count(anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one combined planner anchor; found {s.count(anchor)}')

helper=r'''// v0.14.9.11 tenant display-name support.
function normalizeTenantDisplayName(value) {
  const display=String(value ?? "").trim();
  if (!display) throw new Error("display_name is required and must not be blank.");
  if (display.length > 255) throw new Error("display_name must be 255 characters or fewer.");
  return display;
}
async function setAndVerifyTenantDisplayName(tenant, displayName) {
  const expected=normalizeTenantDisplayName(displayName);
  const configPath=`/rest/domain/${encodeURIComponent(tenant)}/config`;

  // Match the Vodia admin UI behavior safely: read the current config first,
  // preserve the known writable fields, and change only the display value.
  const response=await vodiaSystemJson({path:configPath});
  const raw=Array.isArray(response.data)?response.data[0]:response.data;
  if (!raw || typeof raw !== "object") throw new Error("tenant config could not be read before setting display_name");

  const allowed=new Set(["primary","alias","admins","country_code","display","license_key","max_extensions","max_attendants","max_callingcards","max_hunts","max_hoots","max_srvflags","max_ivrnodes","max_doors","max_acds","max_conferences","max_colines","max_calls","max_trunk_calls","max_trunk_notify","max_call_duration","max_regs","parm1","parm2","parm3","billing_start","bill_customer","bill_admin","bill_data","bill_plan","voice2text","google_voice2text_key","spamreject","sms_enabled","didr","rec_enabled","cloud_provider_public","lastdigits","cdr_keep","rec_keep","visible"]);
  const body=Object.fromEntries(Object.entries(raw).filter(([key,value])=>allowed.has(key) && value !== undefined));
  body.primary=String(body.primary||tenant);
  body.alias=Array.isArray(body.alias)&&body.alias.length?body.alias:[tenant];
  body.admins=Array.isArray(body.admins)?body.admins:[];
  body.display=expected;

  await vodiaSystemJson({method:"POST",path:configPath,body});

  // Verify against the same domain config endpoint that carries the display field.
  const verifyResponse=await vodiaSystemJson({path:configPath});
  const verifyRaw=Array.isArray(verifyResponse.data)?verifyResponse.data[0]:verifyResponse.data;
  const verifiedDisplay=String(verifyRaw?.display ?? "").trim();
  if (verifiedDisplay !== expected) {
    throw new Error(`display read-back was '${verifiedDisplay||"empty"}', expected '${expected}'`);
  }
  return {display_name:expected,verifiedDisplay};
}

'''
s=s.replace(anchor,helper+anchor,1)

# ---- Combined Cloudflare + Vodia planner ----
once(
'async function planCreateTenantWithDns({ actor, tenant, countryCode, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);',
'async function planCreateTenantWithDns({ actor, tenant, countryCode, displayName, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = normalizeTenantDisplayName(displayName);',
'combined planner signature')

once(
'const requiredConfirmation = `APPROVE CREATE ${normalizedTenant} COUNTRY ${normalizedCountryCode}`;',
'const requiredConfirmation = `APPROVE CREATE ${normalizedTenant} COUNTRY ${normalizedCountryCode} NAME ${normalizedDisplayName}`;',
'combined confirmation')

# Freeze display name into both the stored plan and public plan. The countryCode
# key occurs once in the stored plan and once in the returned plan in the current base.
combined_start=s.index('async function planCreateTenantWithDns')
combined_end=s.index('async function applyCreateTenantWithDns',combined_start)
combined=s[combined_start:combined_end]
cc_count=combined.count('countryCode: normalizedCountryCode,')
if cc_count != 2:
    raise SystemExit(f'PATCH ERROR: expected two combined countryCode plan fields; found {cc_count}')
combined=combined.replace('countryCode: normalizedCountryCode,','countryCode: normalizedCountryCode,\n    displayName: normalizedDisplayName,')
public_country='country_code: normalizedCountryCode,'
if combined.count(public_country) != 1:
    raise SystemExit(f'PATCH ERROR: expected one combined public country_code field; found {combined.count(public_country)}')
combined=combined.replace(public_country,public_country+'\n    display_name: normalizedDisplayName,',1)
s=s[:combined_start]+combined+s[combined_end:]

# After the already-proven country update, apply and verify display. If this fails,
# tenant + DNS remain present and the result is explicitly partial; no DNS rollback
# is attempted after a successful PBX tenant write.
combined_apply_marker='''    // Final independent verification on both sides. Do not auto-delete DNS once
    // the tenant is verified present; that would make a successful PBX write worse.'''
if combined_apply_marker not in s:
    raise SystemExit('PATCH ERROR: combined post-country verification marker not found')
combined_display_apply='''    let displayResult;
    try {
      displayResult = await setAndVerifyTenantDisplayName(plan.tenant, plan.displayName);
    } catch (error) {
      tenantDnsBundlePlans.delete(id);
      throw new Error(`PARTIAL TENANT + DNS CREATION: DNS and tenant '${plan.tenant}' are present and country_code '${plan.countryCode}' was applied, but display_name '${plan.displayName}' was not verified. Do not create accounts until the tenant display name is corrected. Cause: ${String(error?.message||error)}`);
    }

'''
s=s.replace(combined_apply_marker,combined_display_apply+combined_apply_marker,1)

once(
'        country_code: countryResult.country_code,\n        countryVerified: true,',
'        country_code: countryResult.country_code,\n        countryVerified: true,\n        display_name: displayResult.display_name,\n        displayVerified: true,',
'combined result metadata')

# ---- Standalone Vodia-native planner ----
once(
'async function planCreateTenant({ actor, tenant, countryCode, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);',
'async function planCreateTenant({ actor, tenant, countryCode, displayName, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = normalizeTenantDisplayName(displayName);',
'standalone planner signature')

once(
'const requiredConfirmation = `CREATE VODIA TENANT ${normalized} COUNTRY ${normalizedCountryCode}`;',
'const requiredConfirmation = `CREATE VODIA TENANT ${normalized} COUNTRY ${normalizedCountryCode} NAME ${normalizedDisplayName}`;',
'standalone confirmation')

stand_start=s.index('async function planCreateTenant(')
# Use applyCreateTenant or the next function as block boundary.
stand_end=s.find('\nasync function ',stand_start+20)
if stand_end < 0:
    raise SystemExit('PATCH ERROR: standalone planner boundary not found')
stand=s[stand_start:stand_end]
cc_count=stand.count('countryCode: normalizedCountryCode,')
if cc_count != 2:
    raise SystemExit(f'PATCH ERROR: expected two standalone countryCode plan fields; found {cc_count}')
stand=stand.replace('countryCode: normalizedCountryCode,','countryCode: normalizedCountryCode,\n    displayName: normalizedDisplayName,')
if stand.count('country_code: normalizedCountryCode,') != 1:
    raise SystemExit(f'PATCH ERROR: expected one standalone public country_code field; found {stand.count("country_code: normalizedCountryCode,")}')
stand=stand.replace('country_code: normalizedCountryCode,','country_code: normalizedCountryCode,\n    display_name: normalizedDisplayName,',1)
s=s[:stand_start]+stand+s[stand_end:]

stand_country_apply='''  try { await setAndVerifyTenantCountryCode(plan.tenant, plan.countryCode); }
  catch (error) { tenantCreatePlans.delete(id); throw new Error(`PARTIAL TENANT CREATION: '${plan.tenant}' was created, but country_code '${plan.countryCode}' was not verified. Cause: ${String(error?.message||error)}`); }

'''
if stand_country_apply not in s:
    raise SystemExit('PATCH ERROR: standalone country application point not found')
stand_display_apply='''  try { await setAndVerifyTenantDisplayName(plan.tenant, plan.displayName); }
  catch (error) { tenantCreatePlans.delete(id); throw new Error(`PARTIAL TENANT CREATION: '${plan.tenant}' was created and country_code '${plan.countryCode}' was applied, but display_name '${plan.displayName}' was not verified. Cause: ${String(error?.message||error)}`); }

'''
s=s.replace(stand_country_apply,stand_country_apply+stand_display_apply,1)

once(
'    country_code: plan.countryCode,\n    countryVerified: true,\n    verified: true,',
'    country_code: plan.countryCode,\n    countryVerified: true,\n    display_name: plan.displayName,\n    displayVerified: true,\n    verified: true,',
'standalone result metadata')

# ---- MCP tool schemas / handlers ----
# Combined planner schema and handler.
once(
'''          country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
          ipv4: z.string().min(7).max(15).optional(),''',
'''          country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
          display_name: z.string().min(1).max(255),
          ipv4: z.string().min(7).max(15).optional(),''',
'combined display schema')
once(
'async ({ tenant, country_code, ipv4, ttl, comment, reason }) => {\n        scopedAudit("plan_create_tenant_with_dns", { tenant, country_code, ipv4, ttl, reason });',
'async ({ tenant, country_code, display_name, ipv4, ttl, comment, reason }) => {\n        scopedAudit("plan_create_tenant_with_dns", { tenant, country_code, display_name, ipv4, ttl, reason });',
'combined handler')
once(
'planCreateTenantWithDns({ actor, tenant, countryCode: country_code, ipv4, ttl, comment, reason })',
'planCreateTenantWithDns({ actor, tenant, countryCode: country_code, displayName: display_name, ipv4, ttl, comment, reason })',
'combined planner call')
once(
'{ operation: "PLAN_CREATE_TENANT_WITH_DNS", tenant: data.tenant, country_code: data.country_code },',
'{ operation: "PLAN_CREATE_TENANT_WITH_DNS", tenant: data.tenant, country_code: data.country_code, display_name: data.display_name },',
'combined plan metadata')

# Standalone planner schema and handler.
once(
'''        country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
        reason: z.string().max(1000).optional(),''',
'''        country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
        display_name: z.string().min(1).max(255),
        reason: z.string().max(1000).optional(),''',
'standalone display schema')
once(
'async ({ tenant, country_code, reason }) => {\n      scopedAudit("plan_create_tenant", { tenant, country_code, reason });',
'async ({ tenant, country_code, display_name, reason }) => {\n      scopedAudit("plan_create_tenant", { tenant, country_code, display_name, reason });',
'standalone handler')
once(
'planCreateTenant({ actor, tenant, countryCode: country_code, reason })',
'planCreateTenant({ actor, tenant, countryCode: country_code, displayName: display_name, reason })',
'standalone planner call')
once(
'{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant, country_code: data.country_code },',
'{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant, country_code: data.country_code, display_name: data.display_name },',
'standalone plan metadata')

# Strengthen tool descriptions without depending on exact older wording.
s=s.replace(
  'Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record.',
  'Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record. Requires a human-readable display_name for the Vodia tenant.',
  1
)

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.11\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/8] Static safety validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
required=[
  'v0.14.9.11 tenant display-name support',
  'function normalizeTenantDisplayName(',
  'async function setAndVerifyTenantDisplayName(',
  'body.display=expected;',
  'display read-back was',
  'display_name: z.string().min(1).max(255)',
  'displayVerified: true',
  'v0.14.9.10 DNS provider choice routing',
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
  'deleteSavedCloudflareDnsRecordById',
]
for x in required:
    if x not in s: raise SystemExit(f'VALIDATION ERROR: missing {x!r}')

if s.count('display_name: z.string().min(1).max(255)') != 2:
    raise SystemExit('VALIDATION ERROR: display_name must be required on exactly the two tenant planner schemas')
if s.count('async function setAndVerifyTenantDisplayName(') != 1:
    raise SystemExit('VALIDATION ERROR: display helper definition count must be 1')
if s.count('await setAndVerifyTenantDisplayName(') != 2:
    raise SystemExit('VALIDATION ERROR: display helper must be applied by both tenant creation paths')

# Provider-choice tool must remain singular after the previous duplicate fix.
choice_count=len(re.findall(r'server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']',s,re.S))
if choice_count != 1:
    raise SystemExit(f'VALIDATION ERROR: provider-choice registration count={choice_count}, expected 1')

# Display helper must read the current config before POSTing and read it back after.
hstart=s.index('async function setAndVerifyTenantDisplayName(')
hend=s.index('async function planCreateTenantWithDns(',hstart)
h=s[hstart:hend]
first_get=h.find('const response=await vodiaSystemJson({path:configPath});')
post=h.find('await vodiaSystemJson({method:"POST",path:configPath,body});')
verify_get=h.find('const verifyResponse=await vodiaSystemJson({path:configPath});')
if min(first_get,post,verify_get) < 0 or not (first_get < post < verify_get):
    raise SystemExit('VALIDATION ERROR: display update is not GET current config -> POST merged config -> GET verify')

# Preserve known-good Cloudflare order and require display only after the PBX tenant POST.
apply_start=s.index('async function applyCreateTenantWithDns')
apply_end=s.find('\nasync function ',apply_start+10)
apply=s[apply_start:] if apply_end < 0 else s[apply_start:apply_end]
pos_cf=apply.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=apply.find('waitForPublicDnsA(plan.tenant, plan.ipv4)')
pos_pbx=apply.find('method: "POST",\n        path: "/rest/system/domains"')
pos_country=apply.find('setAndVerifyTenantCountryCode(plan.tenant, plan.countryCode)')
pos_display=apply.find('setAndVerifyTenantDisplayName(plan.tenant, plan.displayName)')
if min(pos_cf,pos_dns,pos_pbx,pos_country,pos_display) < 0 or not (pos_cf < pos_dns < pos_pbx < pos_country < pos_display):
    raise SystemExit(f'VALIDATION ERROR: combined order changed ({pos_cf}, {pos_dns}, {pos_pbx}, {pos_country}, {pos_display})')

print('PASS: display_name required and frozen into both tenant plans')
print('PASS: display update preserves current tenant config and verifies exact read-back')
print('PASS: combined order = Cloudflare -> public DNS -> tenant -> country -> display')
print('PASS: provider-choice registration remains exactly one')
print('PASS: v0.14.9.9 Cloudflare DNS-FIRST/public-resolver/rollback path preserved')
PY
echo PASS

if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then
  echo "PATCH-ONLY PASS: staged patch validated; nothing installed or restarted"
  exit 0
fi

echo "[6/8] Install"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
node --check "$INDEX" >/dev/null
node --check "$VERSION" >/dev/null
echo PASS

echo "[7/8] Restart + health"
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager || true; false; }
cat "$HEALTH"; echo
if ! grep -q '"version":"0.14.9.11"' "$HEALTH"; then
  echo "Health did not report v0.14.9.11"
  false
fi
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register|ERR_MODULE' > "$LOGS"; then
  cat "$LOGS"
  false
fi
echo PASS

echo "[8/8] Complete"
echo "PASS: v0.14.9.11 installed"
echo "PASS: tenant planners now require display_name"
echo "PASS: tenant country_code is still applied and verified"
echo "PASS: tenant display_name is applied and verified by config read-back"
echo "PASS: Cloudflare DNS-FIRST + public resolver gate + rollback preserved"
echo "PASS: Vodia/Cloudflare provider-choice routing preserved"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session so the updated schemas are loaded."
trap - ERR
