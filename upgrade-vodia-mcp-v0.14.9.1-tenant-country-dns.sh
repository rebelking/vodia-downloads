#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
ADMIN="$APP/admin.js"
VERSION="$APP/version.js"
SERVICE=vodia-mcp
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.1-tenant-country-dns-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
echo "=== Vodia MCP v0.14.9.1 — Tenant Country Code + DNS ==="
echo "[1/8] Preflight"
for file in "$INDEX" "$ADMIN" "$VERSION"; do test -f "$file" || fail "missing $file"; done
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$ADMIN" >/dev/null || fail "current admin.js syntax invalid"
grep -q 'async function planCreateTenantWithDns' "$INDEX" || fail "combined tenant + DNS planner missing"
grep -q 'async function applyCreateTenantWithDns' "$INDEX" || fail "combined tenant + DNS apply helper missing"
grep -q '"plan_create_tenant_with_dns"' "$INDEX" || fail "combined tenant + DNS tool missing"
grep -q 'async function planCreateTenant' "$INDEX" || fail "standalone tenant planner missing"
grep -q '"plan_account_batch"' "$ADMIN" || fail "v0.14.8 account-batch prerequisite missing"
if grep -q 'v0.14.9.1 tenant country-code + DNS validation' "$INDEX"; then fail "v0.14.9.1 patch already installed"; fi
echo PASS

echo "[2/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"

echo "[3/8] Patch tenant workflows"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1: raise SystemExit(f"PATCH ERROR: expected one {label}; found {n}")
    s=s.replace(old,new,1)

helpers=r'''// v0.14.9.1 tenant country-code + DNS validation.
// Mirrors Vodia's portal country_code field: digits only, no leading plus sign.
const VODIA_TENANT_COUNTRY_CODE_PATTERN = /^(?:1|2[078]|2[1234569]\d|3[0123469]|3[578]\d|4[013-9]|42\d|5[1-8]|5[09]\d|6[0-6]|6[7-9]\d|7|8[123469]|8[0578]\d|9[0123458]|9[679]\d)$/;
function normalizeTenantCountryCode(value) {
  const code=String(value ?? "").trim();
  if (!VODIA_TENANT_COUNTRY_CODE_PATTERN.test(code)) throw new Error('country_code must use the Vodia calling-code format: digits only, without "+".');
  return code;
}
async function readTenantSystemInfo(tenant) {
  const wanted=String(tenant||"").trim().toLowerCase();
  for (let page=1; page<=100; page+=1) {
    const list=await vodiaSystemJson({path:`/rest/system/domaininfo?size=100&page=${page}`});
    const rows=Array.isArray(list.data)?list.data:[];
    const row=rows.find((entry)=>{
      const names=[entry?.name,entry?.primary,entry?.display,...(Array.isArray(entry?.alias)?entry.alias:[])].map((v)=>String(v||"").trim().toLowerCase());
      return names.includes(wanted);
    });
    if (row?.id != null) {
      const detail=await vodiaSystemJson({path:`/rest/system/domaininfo?id=${encodeURIComponent(String(row.id))}`});
      const data=Array.isArray(detail.data)?detail.data[0]:detail.data;
      return data && typeof data === "object" ? data : null;
    }
    if (rows.length < 100) break;
  }
  return null;
}
async function setAndVerifyTenantCountryCode(tenant,countryCode) {
  const configPath=`/rest/domain/${encodeURIComponent(tenant)}/config`;
  const response=await vodiaSystemJson({path:configPath});
  const raw=Array.isArray(response.data)?response.data[0]:response.data;
  if (!raw || typeof raw !== "object") throw new Error("tenant config could not be read after tenant creation");
  const allowed=new Set(["primary","alias","admins","country_code","display","license_key","max_extensions","max_attendants","max_callingcards","max_hunts","max_hoots","max_srvflags","max_ivrnodes","max_doors","max_acds","max_conferences","max_colines","max_calls","max_trunk_calls","max_trunk_notify","max_call_duration","max_regs","parm1","parm2","parm3","billing_start","bill_customer","bill_admin","bill_data","bill_plan","voice2text","google_voice2text_key","spamreject","sms_enabled","didr","rec_enabled","cloud_provider_public","lastdigits","cdr_keep","rec_keep","visible"]);
  const body=Object.fromEntries(Object.entries(raw).filter(([key,value])=>allowed.has(key) && value !== undefined));
  body.primary=String(body.primary||tenant); body.alias=Array.isArray(body.alias)&&body.alias.length?body.alias:[tenant]; body.admins=Array.isArray(body.admins)?body.admins:[]; body.country_code=countryCode;
  await vodiaSystemJson({method:"POST",path:configPath,body});
  const detail=await readTenantSystemInfo(tenant);
  const verified=String(detail?.country??"").trim();
  if (verified !== countryCode) throw new Error(`country read-back was '${verified||"empty"}', expected '${countryCode}'`);
  return {country_code:countryCode,verifiedCountry:verified,tenantId:detail?.id??null};
}

'''
once('async function planCreateTenantWithDns(',helpers+'async function planCreateTenantWithDns(','combined planner anchor')

once('async function planCreateTenantWithDns({ actor, tenant, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);',
     'async function planCreateTenantWithDns({ actor, tenant, countryCode, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);','combined planner signature')
once('const requiredConfirmation = `APPROVE CREATE ${normalizedTenant}`;','const requiredConfirmation = `APPROVE CREATE ${normalizedTenant} COUNTRY ${normalizedCountryCode}`;','combined confirmation')
once('    tenant: normalizedTenant,\n    zone,','    tenant: normalizedTenant,\n    countryCode: normalizedCountryCode,\n    zone,','combined stored plan')
once('    tenant: normalizedTenant,\n    expiresAt: expiresAt.toISOString(),','    tenant: normalizedTenant,\n    countryCode: normalizedCountryCode,\n    country_code: normalizedCountryCode,\n    expiresAt: expiresAt.toISOString(),','combined public plan')
once('      tenant: normalizedTenant,\n      endpoint: "POST /rest/system/domains",','      tenant: normalizedTenant,\n      country_code: normalizedCountryCode,\n      endpoint: "POST /rest/system/domains then POST /rest/domain/{tenant}/config",','combined Vodia plan details')

once('    // Final independent verification on both sides. Do not auto-delete DNS once\n    // the tenant is verified present; that would make a successful PBX write worse.',
'''    // The tenant exists; set and verify its Vodia country_code before declaring
    // the combined customer workflow successful. DNS is deliberately retained on
    // a country failure because the PBX tenant already exists.
    let countryResult;
    try { countryResult = await setAndVerifyTenantCountryCode(plan.tenant, plan.countryCode); }
    catch (error) {
      tenantDnsBundlePlans.delete(id);
      throw new Error(`PARTIAL TENANT + DNS CREATION: DNS and tenant '${plan.tenant}' are present, but country_code '${plan.countryCode}' was not verified. Do not create accounts until country is corrected. Cause: ${String(error?.message||error)}`);
    }

    // Final independent verification on both sides. Do not auto-delete DNS once
    // the tenant is verified present; that would make a successful PBX write worse.''','combined country application point')
once('        record: tenantRecord,\n        createRequestWarning: createError ? createError.message : null,','        record: tenantRecord,\n        country_code: countryResult.country_code,\n        countryVerified: true,\n        createRequestWarning: createError ? createError.message : null,','combined result')

once('async function planCreateTenant({ actor, tenant, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);','async function planCreateTenant({ actor, tenant, countryCode, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);','standalone planner signature')
once('const requiredConfirmation = `CREATE VODIA TENANT ${normalized}`;','const requiredConfirmation = `CREATE VODIA TENANT ${normalized} COUNTRY ${normalizedCountryCode}`;','standalone confirmation')
once('''  tenantCreatePlans.set(changeId, {
    changeId,
    actor: String(actor || "unknown"),
    tenant: normalized,
    reason: String(reason || "3CX migration tenant creation"),''','''  tenantCreatePlans.set(changeId, {
    changeId,
    actor: String(actor || "unknown"),
    tenant: normalized,
    countryCode: normalizedCountryCode,
    reason: String(reason || "3CX migration tenant creation"),''','standalone stored plan')
once('''  return {
    changeId,
    operation: "CreateVodiaTenant",
    tenant: normalized,
    reason: String(reason || "3CX migration tenant creation"),''','''  return {
    changeId,
    operation: "CreateVodiaTenant",
    tenant: normalized,
    countryCode: normalizedCountryCode,
    country_code: normalizedCountryCode,
    reason: String(reason || "3CX migration tenant creation"),''','standalone public plan')
once('  // Independently verify via the list endpoint.','''  try { await setAndVerifyTenantCountryCode(plan.tenant, plan.countryCode); }
  catch (error) { tenantCreatePlans.delete(id); throw new Error(`PARTIAL TENANT CREATION: '${plan.tenant}' was created, but country_code '${plan.countryCode}' was not verified. Cause: ${String(error?.message||error)}`); }

  // Independently verify via the list endpoint.''','standalone country application point')
once('    tenant: plan.tenant,\n    verified: true,','    tenant: plan.tenant,\n    country_code: plan.countryCode,\n    countryVerified: true,\n    verified: true,','standalone result')

once('''        inputSchema: {
          tenant: z.string().min(3).max(253),
          ipv4: z.string().min(7).max(15).optional(),''','''        inputSchema: {
          tenant: z.string().min(3).max(253),
          country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
          ipv4: z.string().min(7).max(15).optional(),''','combined tool schema')
once('async ({ tenant, ipv4, ttl, comment, reason }) => {\n        scopedAudit("plan_create_tenant_with_dns", { tenant, ipv4, ttl, reason });','async ({ tenant, country_code, ipv4, ttl, comment, reason }) => {\n        scopedAudit("plan_create_tenant_with_dns", { tenant, country_code, ipv4, ttl, reason });','combined handler')
once('planCreateTenantWithDns({ actor, tenant, ipv4, ttl, comment, reason })','planCreateTenantWithDns({ actor, tenant, countryCode: country_code, ipv4, ttl, comment, reason })','combined call')
once('{ operation: "PLAN_CREATE_TENANT_WITH_DNS", tenant: data.tenant },','{ operation: "PLAN_CREATE_TENANT_WITH_DNS", tenant: data.tenant, country_code: data.country_code },','combined metadata')
once('''      inputSchema: {
        tenant: z.string().min(3).max(253),
        reason: z.string().max(1000).optional(),''','''      inputSchema: {
        tenant: z.string().min(3).max(253),
        country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
        reason: z.string().max(1000).optional(),''','standalone tool schema')
once('async ({ tenant, reason }) => {\n      scopedAudit("plan_create_tenant", { tenant, reason });','async ({ tenant, country_code, reason }) => {\n      scopedAudit("plan_create_tenant", { tenant, country_code, reason });','standalone handler')
once('planCreateTenant({ actor, tenant, reason })','planCreateTenant({ actor, tenant, countryCode: country_code, reason })','standalone call')
once('{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant },','{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant, country_code: data.country_code },','standalone metadata')
s=s.replace("`Created and verified Cloudflare DNS and Vodia tenant '${data?.vodia?.tenant || \"\"}' under one approved plan.`", "`Created and verified Cloudflare DNS and Vodia tenant '${data?.vodia?.tenant || \"\"}' with country code '${data?.vodia?.country_code || \"\"}'.`",1)
p.write_text(s)
PY
echo PASS

echo "[4/8] Patch version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.1\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
echo PASS

echo "[5/8] Static validation"
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
grep -q 'v0.14.9.1 tenant country-code + DNS validation' "$TMP_INDEX" || fail "marker missing"
grep -q 'country_code: z.string().regex' "$TMP_INDEX" || fail "country inputs missing"
grep -q 'PARTIAL TENANT + DNS CREATION' "$TMP_INDEX" || fail "combined partial handling missing"
grep -q 'countryVerified: true' "$TMP_INDEX" || fail "verification result missing"
echo PASS
if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then echo "PATCH-ONLY PASS: nothing installed or restarted"; exit 0; fi

echo "[6/8] Install"
cp -a "$TMP_INDEX" "$INDEX"; cp -a "$TMP_VERSION" "$VERSION"
if ! node --check "$INDEX" >/dev/null || ! node --check "$VERSION" >/dev/null; then cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; fail "live syntax failed; backup restored"; fi
echo PASS
echo "[7/8] Restart + health"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; systemctl restart "$SERVICE" || true; fail "restart failed; backup restored"; fi
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; systemctl restart "$SERVICE" || true; fail "service unhealthy; backup restored"; }
curl -fsS http://127.0.0.1:3100/health >/dev/null || echo "WARN: /health unavailable; service active"
echo PASS
echo "[8/8] Verify"
grep -n -E 'country_code: z.string|PARTIAL TENANT \+ DNS CREATION|countryVerified' "$INDEX" | head -30
grep -n '0.14.9.1' "$VERSION" || true
echo "=== v0.14.9.1 INSTALL PASS ==="
echo "Backup: $BACKUP_DIR"
echo "PBX writes performed by installer: 0"
