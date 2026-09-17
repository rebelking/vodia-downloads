#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.16-vodia-dns-readiness-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring v0.14.9.15 files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.16 — Vodia DNS readiness + public verification ==="
echo "Prevents stale sys_wildcard alone from being treated as working Vodia DNS."
echo "Vodia-native tenant plans require configured PBX DNS integration, and apply must publicly resolve to the PBX IPv4 before success."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -q '0.14.9.15' "$VERSION" || fail "expected installed base version 0.14.9.15"
for marker in \
  'v0.14.9.15 UI-first tenant plan presentation' \
  'v0.14.9.14 MCP App tenant approval UI' \
  'function dnsChoiceDetectVodiaManagedDns' \
  'async function dnsChoiceReadVodiaSettings' \
  'async function getTenantDnsProviderChoices' \
  'async function getAdminDnsProviderChoices' \
  'async function planCreateTenant(' \
  'async function waitForPublicDnsA' \
  'setAndVerifyTenantDisplayName' \
  'setAndVerifyTenantCountryCode' \
  '"plan_create_tenant"' \
  '"apply_tenant_change"' \
  '"plan_create_tenant_with_dns"' \
  'deleteSavedCloudflareDnsRecordById'; do
  grep -q "$marker" "$INDEX" || fail "required current capability missing: $marker"
done
if grep -q 'v0.14.9.16 Vodia DNS readiness gate' "$INDEX"; then
  echo "v0.14.9.16 already appears installed; exiting without changes."
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

echo "[3/8] Patch Vodia DNS readiness + public verification"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='v0.14.9.16 Vodia DNS readiness gate'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.16 marker already present')

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'PATCH ERROR: expected one {label}; found {n}')
    s=s.replace(old,new,1)

# 1) Detect whether the PBX actually has a DNS integration configured.
old='''  const ipRow = flat.find((row) => /(^|\\.)sys_ip4$/i.test(row.path)) || flat.find((row) => /sys_ip4/i.test(row.path));
  return {
    enabled: wildcards.length > 0,
    wildcards,
    matchedWildcard,
    eligibleForTenant: Boolean(matchedWildcard),
    sysIp4: ipRow ? String(ipRow.value || "").trim() || null : null,
    evidence: candidates.slice(0, 10),
  };'''
new='''  const ipRow = flat.find((row) => /(^|\\.)sys_ip4$/i.test(row.path)) || flat.find((row) => /sys_ip4/i.test(row.path));
  const providerRow = flat.find((row) => /(^|\\.)dns_provider$/i.test(row.path)) || flat.find((row) => /dns_provider/i.test(row.path));
  const accountRow = flat.find((row) => /(^|\\.)dns_account$/i.test(row.path)) || flat.find((row) => /dns_account/i.test(row.path));
  const dnsProvider = providerRow ? String(providerRow.value || "").trim() : "";
  const dnsAccount = accountRow ? String(accountRow.value || "").trim() : "";
  const nativeDnsConfigured = Boolean(dnsProvider || dnsAccount || process.env.VODIA_MCP_ALLOW_UNVERIFIED_VODIA_DNS === "1");
  return {
    enabled: wildcards.length > 0,
    wildcards,
    matchedWildcard,
    eligibleForTenant: Boolean(matchedWildcard),
    sysIp4: ipRow ? String(ipRow.value || "").trim() || null : null,
    dnsProvider: dnsProvider || null,
    dnsAccountConfigured: Boolean(dnsAccount),
    nativeDnsConfigured,
    evidence: candidates.slice(0, 10),
  };'''
once(old,new,'Vodia DNS detection return block')

# 2) Tenant-specific provider discovery must not advertise Vodia DNS from wildcard alone.
once(
'''  // Inspect Vodia first.
  const vodiaDns=await dnsChoiceReadVodiaSettings(normalizedTenant);

  // Then inspect the MCP Cloudflare connection.''',
'''  // Inspect Vodia first.
  const vodiaDns=await dnsChoiceReadVodiaSettings(normalizedTenant);
  const vodiaDnsReady=Boolean(vodiaDns?.readable && vodiaDns?.detected?.nativeDnsConfigured);
  vodiaDns.readiness={
    ready:vodiaDnsReady,
    reason:vodiaDnsReady
      ? "PBX DNS integration is configured."
      : "A managed wildcard is present, but PBX dns_provider/dns_account are empty. Vodia DNS must not be treated as operational until DNS integration is configured or an explicit override is enabled.",
  };

  // Then inspect the MCP Cloudflare connection.''',
'tenant provider readiness insertion')
once(
'if (vodiaDns.readable && vodiaDns.detected.eligibleForTenant) {',
'if (vodiaDns.readable && vodiaDns.detected.eligibleForTenant && vodiaDnsReady) {',
'tenant Vodia provider eligibility')

# 3) Administrator-first provider discovery gets the same readiness gate.
once(
'''  const probeTenant="provider-choice.invalid";
  const vodiaDns=await dnsChoiceReadVodiaSettings(probeTenant);

  let cloudflare;''',
'''  const probeTenant="provider-choice.invalid";
  const vodiaDns=await dnsChoiceReadVodiaSettings(probeTenant);
  const vodiaDnsReady=Boolean(vodiaDns?.readable && vodiaDns?.detected?.nativeDnsConfigured);
  vodiaDns.readiness={
    ready:vodiaDnsReady,
    reason:vodiaDnsReady
      ? "PBX DNS integration is configured."
      : "Vodia managed wildcard exists but PBX DNS integration is not configured; do not offer Vodia DNS.",
  };

  let cloudflare;''',
'admin provider readiness insertion')
once(
'if (vodiaDns?.readable && vodiaDns?.detected?.enabled && wildcards.length) {',
'if (vodiaDns?.readable && vodiaDns?.detected?.enabled && wildcards.length && vodiaDnsReady) {',
'admin Vodia provider eligibility')

# 4) Hard-stop standalone Vodia-native planning if readiness is not verified.
plan_anchor='''async function planCreateTenant({ actor, tenant, countryCode, displayName, reason } = {}) {
  const normalized = normalizeTenantName(tenant);
  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);
  const normalizedDisplayName = resolveTenantDisplayName(normalized, displayName);'''
plan_new=plan_anchor+'''
  const dnsProviderCheck = await getTenantDnsProviderChoices(normalized);
  if (!Array.isArray(dnsProviderCheck?.providerIds) || !dnsProviderCheck.providerIds.includes("vodia")) {
    const why = dnsProviderCheck?.vodiaDns?.readiness?.reason || "Vodia DNS readiness could not be verified.";
    throw new Error(`VODIA_DNS_NOT_READY: ${why} Tenant '${normalized}' was NOT planned for creation.`);
  }
  const expectedDnsIpv4 = String(dnsProviderCheck?.vodiaDns?.detected?.sysIp4 || "").trim();
  if (!expectedDnsIpv4) throw new Error("VODIA_DNS_NOT_READY: PBX sys_ip4 is empty; cannot verify public DNS after tenant creation.");'''
once(plan_anchor,plan_new,'standalone Vodia planner readiness gate')

# Freeze expected DNS IPv4 into stored/public plan by adding it next to displayName.
stand_start=s.index('async function planCreateTenant(')
stand_end=s.find('\nasync function ',stand_start+20)
if stand_end < 0:
    raise SystemExit('PATCH ERROR: standalone planner boundary not found')
stand=s[stand_start:stand_end]
needle='displayName: normalizedDisplayName,'
count=stand.count(needle)
if count != 2:
    raise SystemExit(f'PATCH ERROR: expected two standalone displayName plan fields; found {count}')
stand=stand.replace(needle,needle+'\n    expectedDnsIpv4,')
if stand.count('display_name: normalizedDisplayName,') != 1:
    raise SystemExit('PATCH ERROR: standalone public display_name field not found exactly once')
stand=stand.replace('display_name: normalizedDisplayName,','display_name: normalizedDisplayName,\n    expected_dns_ipv4: expectedDnsIpv4,',1)
s=s[:stand_start]+stand+s[stand_end:]

# 5) After tenant/country/display are successfully written, require public DNS A resolution.
apply_anchor='''  try { await setAndVerifyTenantDisplayName(plan.tenant, plan.displayName); }
  catch (error) { tenantCreatePlans.delete(id); throw new Error(`PARTIAL TENANT CREATION: '${plan.tenant}' was created and country_code '${plan.countryCode}' was applied, but display_name '${plan.displayName}' was not verified. Cause: ${String(error?.message||error)}`); }

'''
apply_new=apply_anchor+'''  let publicDns;
  try {
    publicDns = await waitForPublicDnsA(plan.tenant, plan.expectedDnsIpv4, {
      timeoutMs: Number(process.env.VODIA_MCP_VODIA_DNS_VERIFY_TIMEOUT_MS || process.env.VODIA_MCP_DNS_PROPAGATION_TIMEOUT_MS || 120000),
      intervalMs: Number(process.env.VODIA_MCP_DNS_PROPAGATION_INTERVAL_MS || 3000),
      consecutiveSuccesses: Number(process.env.VODIA_MCP_DNS_PROPAGATION_SUCCESSES || 2),
    });
  } catch (error) {
    tenantCreatePlans.delete(id);
    const cause=String(error?.message||error).replace(/\\s*Vodia tenant creation was NOT attempted\\.?/gi, "").trim();
    throw new Error(`PARTIAL TENANT CREATION: '${plan.tenant}' exists and its tenant settings were verified, but public DNS did not resolve to PBX IPv4 '${plan.expectedDnsIpv4}'. Do not treat this tenant as ready for phones, ACME, or Teams. Cause: ${cause}`);
  }

'''
once(apply_anchor,apply_new,'standalone post-create public DNS verification')

# Add DNS verification to successful apply metadata.
once(
'''    display_name: plan.displayName,
    displayVerified: true,
    verified: true,''',
'''    display_name: plan.displayName,
    displayVerified: true,
    publicDnsVerified: true,
    publicDns,
    verified: true,''',
'standalone apply success metadata')

# Marker for future installers and inspections.
factory='export function createVodiaServer('
if s.count(factory) != 1:
    raise SystemExit(f'PATCH ERROR: createVodiaServer anchor count={s.count(factory)}')
s=s.replace(factory,'// v0.14.9.16 Vodia DNS readiness gate\n'+factory,1)

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.16\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/8] Static safety validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
required=[
 'v0.14.9.16 Vodia DNS readiness gate',
 'nativeDnsConfigured',
 'dnsProvider:',
 'dnsAccountConfigured:',
 'VODIA_DNS_NOT_READY:',
 'expectedDnsIpv4',
 'publicDns = await waitForPublicDnsA(plan.tenant, plan.expectedDnsIpv4',
 'publicDnsVerified: true',
 'VODIA_MCP_VODIA_DNS_VERIFY_TIMEOUT_MS',
 'v0.14.9.15 UI-first tenant plan presentation',
 'v0.14.9.14 MCP App tenant approval UI',
 'ui://vodia/tenant-approval/mcp-app.html',
 'deleteSavedCloudflareDnsRecordById',
 'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
]
for item in required:
    if item not in s:
        raise SystemExit(f'VALIDATION ERROR: missing {item}')
if s.count('_meta: { ui: { resourceUri: TENANT_APPROVAL_UI_URI }, "ui/resourceUri": TENANT_APPROVAL_UI_URI },') != 2:
    raise SystemExit('VALIDATION ERROR: MCP App tenant UI metadata count changed')
if s.count('if (vodiaDns.readable && vodiaDns.detected.eligibleForTenant && vodiaDnsReady) {') != 1:
    raise SystemExit('VALIDATION ERROR: tenant Vodia readiness gate missing')
if s.count('if (vodiaDns?.readable && vodiaDns?.detected?.enabled && wildcards.length && vodiaDnsReady) {') != 1:
    raise SystemExit('VALIDATION ERROR: admin Vodia readiness gate missing')
print('PASS: stale wildcard alone no longer enables Vodia DNS')
print('PASS: PBX dns_provider/dns_account readiness is checked')
print('PASS: standalone Vodia tenant plan is blocked when native DNS is not ready')
print('PASS: successful native apply now requires public A resolution to PBX sys_ip4')
print('PASS: Cloudflare DNS-FIRST/public resolver/rollback path preserved')
print('PASS: MCP App approval UI and UI-first response guidance preserved')
PY
echo PASS

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
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.16' "$HEALTH" || fail "health endpoint did not report v0.14.9.16"
echo PASS

echo "[8/8] Complete"
echo "PASS: v0.14.9.16 installed"
echo "PASS: Vodia DNS is not offered from sys_wildcard alone"
echo "PASS: native tenant plan requires configured PBX DNS integration"
echo "PASS: native tenant apply must publicly resolve to PBX sys_ip4 before success"
echo "PASS: unresolved DNS returns PARTIAL TENANT CREATION instead of false success"
echo "PASS: Cloudflare workflow, approval guards, country/display verification, and MCP App UI remain preserved"
echo "Optional emergency override only: VODIA_MCP_ALLOW_UNVERIFIED_VODIA_DNS=1"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session after installation."
trap - ERR
