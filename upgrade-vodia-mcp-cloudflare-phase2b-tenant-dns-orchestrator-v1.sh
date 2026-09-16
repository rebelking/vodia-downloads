#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP Cloudflare Phase 2B — combined tenant + DNS orchestration
#
# Adds one approval-gated workflow that:
#   PLAN:  verify Cloudflare DNS name absent + Vodia tenant absent
#   APPLY: create/verify Cloudflare A record first, create/verify Vodia tenant second,
#          then verify both sides again.
#
# If Vodia creation cannot be verified, the new Cloudflare record is automatically
# deleted and that deletion is verified. If the tenant appears despite an API error,
# DNS is retained and the workflow reports the independently verified success.
#
# This installer patches staged copies first. Live files are replaced only after
# staged JS syntax/registration checks pass. Any restart/runtime failure restores
# the pre-Phase2B files automatically.
#
# No DNS record or PBX tenant is created by this installer.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
CF="$APP/cloudflare-integration.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/vodia-cloudflare-phase2b.XXXXXX)"
STAGED_INDEX="$WORK/index.js"
STAGED_CF="$WORK/cloudflare-integration.js"
INDEX_BAK="$INDEX.pre-cloudflare-phase2b.$STAMP"
CF_BAK="$CF.pre-cloudflare-phase2b.$STAMP"
HEALTH_TMP="$WORK/health.json"
LOG_TMP="$WORK/runtime-errors.txt"

cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Phase 2B activation failed; restoring pre-Phase2B files..."
  [[ -f "$INDEX_BAK" ]] && cp -a "$INDEX_BAK" "$INDEX" || true
  [[ -f "$CF_BAK" ]] && cp -a "$CF_BAK" "$CF" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
[[ -f "$CF" ]] || fail "missing $CF"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2B — combined tenant + DNS orchestrator ==="
printf '%s\n' "Adds one plan + one approval + one apply flow for Cloudflare DNS and Vodia tenant creation."
printf '%s\n' "No DNS record or tenant is created by this installer."

echo "[1/7] Preflight Phase 2A and copy staged files"
grep -q '"cloudflare_plan_create_dns_record"' "$INDEX" || fail "Cloudflare Phase 2A planner is not installed"
grep -q '"cloudflare_apply_dns_change"' "$INDEX" || fail "Cloudflare Phase 2A apply tool is not installed"
grep -q 'export async function createSavedCloudflareARecord' "$CF" || fail "Cloudflare Phase 2A write helper is not installed"
grep -q '"plan_create_tenant"' "$INDEX" || fail "Vodia tenant planner is not installed"
grep -q '"apply_tenant_change"' "$INDEX" || fail "Vodia tenant apply tool is not installed"
if grep -q '"plan_create_tenant_with_dns"' "$INDEX"; then
  echo "Phase 2B tools already appear installed. Exiting without changes."
  exit 0
fi
cp -a "$INDEX" "$STAGED_INDEX"
cp -a "$CF" "$STAGED_CF"
echo "PASS"

echo "[2/7] Patch staged Cloudflare module with verified delete-by-ID rollback helper"
python3 - "$STAGED_CF" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if 'export async function deleteSavedCloudflareDnsRecordById' in s:
    raise SystemExit('PATCH ERROR: Phase 2B Cloudflare delete helper already exists unexpectedly')

anchor = 'export function disconnectCloudflareIntegration() {'
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: disconnectCloudflareIntegration anchor not found')

block = r'''
export async function deleteSavedCloudflareDnsRecordById({ recordId, expectedName = "" } = {}) {
  const { config, token } = cloudflareSavedRow();
  const id = String(recordId || "").trim();
  const expected = normalizeDnsName(expectedName);
  if (!id) throw new Error("Cloudflare DNS record ID is required for rollback.");

  let current;
  try {
    current = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records/${encodeURIComponent(id)}`, token);
  } catch (error) {
    if (Number(error?.status) === 404) {
      return {
        provider: "cloudflare",
        domain: normalizeDnsName(config.domain),
        recordId: id,
        deleted: false,
        verifiedAbsent: true,
        alreadyAbsent: true,
      };
    }
    throw error;
  }

  const record = current?.result || null;
  if (!record?.id) throw new Error(`Cloudflare record ID ${id} could not be read before rollback.`);
  if (expected && normalizeDnsName(record.name) !== expected) {
    throw new Error(`Rollback safety check refused to delete record ${id}: expected '${expected}' but Cloudflare returned '${record.name || "unknown"}'.`);
  }

  await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records/${encodeURIComponent(id)}`, token, { method: "DELETE" });

  if (expected) {
    const query = new URLSearchParams({ name: expected, per_page: "100" });
    const after = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records?${query}`, token);
    if ((after.result || []).some((item) => item?.id === id)) {
      throw new Error(`Cloudflare rollback delete returned success but record ID ${id} is still present.`);
    }
  } else {
    try {
      await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records/${encodeURIComponent(id)}`, token);
      throw new Error(`Cloudflare rollback delete returned success but record ID ${id} is still readable.`);
    } catch (error) {
      if (Number(error?.status) !== 404) throw error;
    }
  }

  return {
    provider: "cloudflare",
    domain: normalizeDnsName(config.domain),
    recordId: id,
    deleted: true,
    verifiedAbsent: true,
    alreadyAbsent: false,
    record: mapDnsRecord(record),
  };
}

'''

s = s[:idx] + block + s[idx:]
p.write_text(s)
PY
node --check "$STAGED_CF"
echo "PASS"

echo "[3/7] Patch staged index.js with one-plan/one-approval orchestrator"
python3 - "$STAGED_INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if '"plan_create_tenant_with_dns"' in s or '"apply_tenant_dns_change"' in s:
    raise SystemExit('PATCH ERROR: Phase 2B tool marker already present unexpectedly')

# Add rollback helper to the existing Cloudflare import block safely.
imp_re = re.compile(r'import\s*\{(?P<body>.*?)\}\s*from\s*"\./cloudflare-integration\.js";', re.S)
m = imp_re.search(s)
if not m:
    raise SystemExit('PATCH ERROR: Cloudflare import block not found')
body = m.group('body')
if 'deleteSavedCloudflareDnsRecordById' not in body:
    body = body.rstrip()
    body = re.sub(r',\s*$', '', body)
    body = body + ',\n  deleteSavedCloudflareDnsRecordById,\n'
    repl = 'import {' + body + '} from "./cloudflare-integration.js";'
    s = s[:m.start()] + repl + s[m.end():]

# Add top-level bundle planning/apply logic immediately before Phase 2A planner.
anchor = 'async function planCloudflareCreateDnsRecord('
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: Phase 2A planCloudflareCreateDnsRecord anchor not found')

logic = r'''
const TENANT_DNS_BUNDLE_PLAN_TTL_MS = 5 * 60 * 1000;
const tenantDnsBundlePlans = new Map();

function findTenantRecordForBundle(data, normalizedName) {
  const wanted = String(normalizedName || "").trim().toLowerCase();
  const inspect = (value, fallbackId = null) => {
    if (!value || typeof value !== "object") return null;
    const candidates = [value.name, value.domain, value.alias, value.hostname]
      .flatMap((item) => Array.isArray(item) ? item : [item])
      .filter(Boolean)
      .map((item) => String(item).trim().toLowerCase());
    if (!candidates.includes(wanted)) return null;
    return {
      id: value.id ?? value.domain_id ?? fallbackId ?? null,
      name: value.name || normalizedName,
      alias: value.alias ?? null,
    };
  };

  if (Array.isArray(data)) {
    for (const item of data) {
      const found = inspect(item, null);
      if (found) return found;
    }
  } else if (data && typeof data === "object") {
    for (const [key, value] of Object.entries(data)) {
      const found = inspect(value, key);
      if (found) return found;
      if (typeof value === "string" && String(value).trim().toLowerCase() === wanted) {
        return { id: key, name: normalizedName, alias: null };
      }
    }
  }
  return null;
}

async function discoverBundleIpv4(ipv4, zone) {
  if (String(ipv4 || "").trim()) {
    return { ipv4: validateIpv4ForPlan(ipv4), source: "explicit" };
  }

  const candidates = [process.env.PBX_BASE_URL, process.env.VODIA_BASE_URL, process.env.VODIA_URL]
    .map((item) => String(item || "").trim())
    .filter(Boolean);

  for (const raw of candidates) {
    let hostname = "";
    try { hostname = new URL(raw).hostname.toLowerCase(); }
    catch { continue; }
    if (!hostname || !(hostname === zone || hostname.endsWith(`.${zone}`))) continue;
    const result = await listSavedCloudflareDnsRecords({ name: hostname, type: "A" });
    const exact = (Array.isArray(result?.records) ? result.records : []).filter(
      (record) => normalizeCloudflarePlanName(record?.name) === hostname && String(record?.type || "").toUpperCase() === "A"
    );
    const unique = [...new Set(exact.map((record) => String(record?.content || "").trim()).filter(Boolean))];
    if (unique.length === 1) {
      return { ipv4: validateIpv4ForPlan(unique[0]), source: `cloudflare:${hostname}` };
    }
  }

  throw new Error("PBX public IPv4 could not be discovered safely. Supply ipv4 after verifying the PBX A record.");
}

async function planCreateTenantWithDns({ actor, tenant, ipv4, ttl = 1, comment = "", reason = "" } = {}) {
  const normalizedTenant = normalizeTenantName(tenant);
  const status = getCloudflareIntegrationStatus();
  if (!status?.configured || !status?.domain) throw new Error("Cloudflare is not configured.");
  const zone = normalizeCloudflarePlanName(status.domain);
  if (!(normalizedTenant === zone || normalizedTenant.endsWith(`.${zone}`))) {
    throw new Error(`Tenant '${normalizedTenant}' is outside configured Cloudflare zone '${zone}'.`);
  }

  const resolved = await discoverBundleIpv4(ipv4, zone);
  const normalizedTtl = Number(ttl || 1);
  if (!Number.isInteger(normalizedTtl) || normalizedTtl < 1 || normalizedTtl > 86400 || (normalizedTtl !== 1 && normalizedTtl < 60)) {
    throw new Error("TTL must be 1 (Auto) or an integer from 60 through 86400 seconds.");
  }

  const pbxBefore = await vodiaSystemJson({ path: "/rest/system/domains" });
  const visible = extractVisibleTenantNames(pbxBefore.data);
  if (visible.includes(normalizedTenant)) throw new Error(`Tenant '${normalizedTenant}' already exists.`);

  const dnsBefore = await listSavedCloudflareDnsRecords({ name: normalizedTenant });
  const dnsExact = (Array.isArray(dnsBefore?.records) ? dnsBefore.records : []).filter(
    (record) => normalizeCloudflarePlanName(record?.name) === normalizedTenant
  );
  if (dnsExact.length) throw new Error(`DNS name '${normalizedTenant}' already has ${dnsExact.length} record(s).`);

  const changeId = `tenantdns-${globalThis.crypto?.randomUUID?.() || Date.now()}`;
  const expiresAt = new Date(Date.now() + TENANT_DNS_BUNDLE_PLAN_TTL_MS);
  const requiredConfirmation = `CREATE VODIA TENANT WITH DNS ${normalizedTenant} ${resolved.ipv4} DNS-ONLY`;
  const finalComment = String(comment || `Vodia tenant ${normalizedTenant}`).trim().slice(0, 500);

  tenantDnsBundlePlans.set(changeId, {
    changeId,
    actor: String(actor || "unknown"),
    tenant: normalizedTenant,
    zone,
    ipv4: resolved.ipv4,
    ipv4Source: resolved.source,
    ttl: normalizedTtl,
    proxied: false,
    comment: finalComment,
    reason: String(reason || "").trim().slice(0, 1000),
    expiresAt,
    requiredConfirmation,
    used: false,
  });

  return {
    changeId,
    operation: "CreateVodiaTenantWithCloudflareDns",
    tenant: normalizedTenant,
    expiresAt: expiresAt.toISOString(),
    requiredConfirmation,
    changesMade: false,
    sequence: ["create_cloudflare_dns", "verify_cloudflare_dns", "create_vodia_tenant", "verify_vodia_tenant", "final_verify_both"],
    cloudflare: {
      zone,
      type: "A",
      name: normalizedTenant,
      content: resolved.ipv4,
      ipv4Source: resolved.source,
      ttl: normalizedTtl,
      ttlDisplay: normalizedTtl === 1 ? "Auto" : normalizedTtl,
      proxied: false,
      dnsOnly: true,
      comment: finalComment || null,
      preflight: { exactNameConflict: false, existingExactRecordCount: 0 },
    },
    vodia: {
      tenant: normalizedTenant,
      endpoint: "POST /rest/system/domains",
      preflight: { tenantExists: false, visibleTenantCount: visible.length },
    },
    rollbackPolicy: "If Vodia creation cannot be independently verified, delete and verify removal of the just-created Cloudflare record. If Vodia is verified present, do not auto-delete DNS.",
  };
}

async function applyCreateTenantWithDns({ actor, changeId, confirmation } = {}) {
  const id = String(changeId || "").trim();
  const plan = tenantDnsBundlePlans.get(id);
  if (!plan) throw new Error("Tenant + DNS plan was not found, expired, or was already used.");
  if (plan.used) throw new Error("Tenant + DNS plan was already used.");
  if (Date.now() > plan.expiresAt.getTime()) {
    tenantDnsBundlePlans.delete(id);
    throw new Error("Tenant + DNS plan expired. Prepare it again.");
  }
  if (String(actor || "unknown") !== plan.actor) {
    throw new Error("Tenant + DNS plan belongs to a different administrator identity.");
  }
  if (String(confirmation || "") !== plan.requiredConfirmation) {
    throw new Error("Confirmation does not exactly match requiredConfirmation.");
  }

  const currentCf = getCloudflareIntegrationStatus();
  if (!currentCf?.configured || normalizeCloudflarePlanName(currentCf.domain) !== plan.zone) {
    throw new Error("Cloudflare integration zone changed after planning; refusing combined write.");
  }

  // Re-check both targets immediately before the first write.
  const dnsBefore = await listSavedCloudflareDnsRecords({ name: plan.tenant });
  const exactBefore = (Array.isArray(dnsBefore?.records) ? dnsBefore.records : []).filter(
    (record) => normalizeCloudflarePlanName(record?.name) === plan.tenant
  );
  if (exactBefore.length) {
    tenantDnsBundlePlans.delete(id);
    throw new Error(`DNS name '${plan.tenant}' now has ${exactBefore.length} record(s); refusing combined write.`);
  }
  const pbxBefore = await vodiaSystemJson({ path: "/rest/system/domains" });
  if (extractVisibleTenantNames(pbxBefore.data).includes(plan.tenant)) {
    tenantDnsBundlePlans.delete(id);
    throw new Error(`Tenant '${plan.tenant}' now exists; refusing combined write.`);
  }

  plan.used = true;
  let cfRecord = null;

  try {
    const cfResult = await createSavedCloudflareARecord({
      name: plan.tenant,
      ipv4: plan.ipv4,
      ttl: plan.ttl,
      proxied: false,
      comment: plan.comment,
    });
    cfRecord = cfResult?.record || null;
    if (!cfResult?.verified || !cfRecord?.id) {
      throw new Error("Cloudflare creation did not return a verified record ID.");
    }

    // One last PBX conflict check after DNS succeeds but before tenant write.
    const preCreate = await vodiaSystemJson({ path: "/rest/system/domains" });
    if (extractVisibleTenantNames(preCreate.data).includes(plan.tenant)) {
      const rollback = await deleteSavedCloudflareDnsRecordById({ recordId: cfRecord.id, expectedName: plan.tenant });
      tenantDnsBundlePlans.delete(id);
      throw new Error(`Tenant '${plan.tenant}' appeared after DNS creation; Vodia write was skipped. Cloudflare rollback verified: ${Boolean(rollback?.verifiedAbsent)}.`);
    }

    let createError = null;
    try {
      await vodiaSystemJson({
        method: "POST",
        path: "/rest/system/domains",
        body: [plan.tenant],
      });
    } catch (error) {
      createError = error;
    }

    let pbxAfter = null;
    let tenantVerified = false;
    for (let attempt = 1; attempt <= 6; attempt++) {
      try {
        pbxAfter = await vodiaSystemJson({ path: "/rest/system/domains" });
        tenantVerified = extractVisibleTenantNames(pbxAfter.data).includes(plan.tenant);
        if (tenantVerified) break;
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, 750));
    }

    if (!tenantVerified) {
      let rollbackResult = null;
      let rollbackError = null;
      try {
        rollbackResult = await deleteSavedCloudflareDnsRecordById({ recordId: cfRecord.id, expectedName: plan.tenant });
      } catch (error) {
        rollbackError = error;
      }
      tenantDnsBundlePlans.delete(id);
      const root = createError
        ? `Vodia tenant creation failed: ${createError.message}`
        : `Vodia tenant '${plan.tenant}' could not be independently verified after creation.`;
      if (rollbackError) {
        throw new Error(`${root} ROLLBACK WARNING: Cloudflare record ${cfRecord.id} may remain: ${rollbackError.message}`);
      }
      throw new Error(`${root} Cloudflare rollback PASS: record ${cfRecord.id} was removed and verified absent=${Boolean(rollbackResult?.verifiedAbsent)}.`);
    }

    // Final independent verification on both sides. Do not auto-delete DNS once
    // the tenant is verified present; that would make a successful PBX write worse.
    const dnsAfter = await listSavedCloudflareDnsRecords({ name: plan.tenant, type: "A" });
    const finalRecord = (Array.isArray(dnsAfter?.records) ? dnsAfter.records : []).find(
      (record) => record?.id === cfRecord.id
        && normalizeCloudflarePlanName(record?.name) === plan.tenant
        && String(record?.content || "") === plan.ipv4
        && String(record?.type || "").toUpperCase() === "A"
        && Boolean(record?.proxied) === false
    );
    if (!finalRecord) {
      tenantDnsBundlePlans.delete(id);
      throw new Error(`Vodia tenant '${plan.tenant}' is verified present, but final Cloudflare verification failed for record ${cfRecord.id}. No automatic PBX rollback was attempted.`);
    }

    const tenantRecord = findTenantRecordForBundle(pbxAfter?.data, plan.tenant);
    tenantDnsBundlePlans.delete(id);
    return {
      changeId: id,
      operation: "CreateVodiaTenantWithCloudflareDns",
      verified: true,
      changesMade: true,
      cloudflare: {
        verified: true,
        zone: plan.zone,
        record: finalRecord,
      },
      vodia: {
        verified: true,
        tenant: plan.tenant,
        tenantId: tenantRecord?.id ?? null,
        record: tenantRecord,
        createRequestWarning: createError ? createError.message : null,
      },
      rollback: {
        cloudflareRecordId: finalRecord.id,
        note: "No automatic rollback is pending. Tenant and DNS are both verified present.",
      },
    };
  } catch (error) {
    tenantDnsBundlePlans.delete(id);
    throw error;
  }
}

'''

s = s[:idx] + logic + s[idx:]

# Register the combined tools inside the existing adminMode block immediately
# before the Phase 2A Cloudflare planner registration.
name_idx = s.find('"cloudflare_plan_create_dns_record"')
if name_idx < 0:
    raise SystemExit('PATCH ERROR: cloudflare_plan_create_dns_record registration not found')
admin_idx = s.rfind('if (adminMode) {', 0, name_idx)
if admin_idx < 0:
    raise SystemExit('PATCH ERROR: adminMode block not found before Cloudflare Phase 2A tools')
reg_idx = s.rfind('server.registerTool(', admin_idx, name_idx)
if reg_idx < 0:
    raise SystemExit('PATCH ERROR: server.registerTool anchor for Cloudflare Phase 2A planner not found')
line_start = s.rfind('\n', admin_idx, reg_idx)
insert_at = admin_idx if line_start < 0 else line_start + 1

tools = r'''    server.registerTool(
      "plan_create_tenant_with_dns",
      {
        title: "Plan Vodia tenant + Cloudflare DNS creation",
        description: "Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record. Checks both sides, creates no changes, defaults the DNS record to DNS-only, and returns one exact confirmation phrase. If ipv4 is omitted, it attempts safe discovery from the configured PBX hostname's Cloudflare A record; otherwise supply a verified PBX IPv4.",
        inputSchema: {
          tenant: z.string().min(3).max(253),
          ipv4: z.string().min(7).max(15).optional(),
          ttl: z.number().int().min(1).max(86400).optional(),
          comment: z.string().max(500).optional(),
          reason: z.string().max(1000).optional(),
        },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
      },
      async ({ tenant, ipv4, ttl, comment, reason }) => {
        scopedAudit("plan_create_tenant_with_dns", { tenant, ipv4, ttl, reason });
        try {
          const data = await planCreateTenantWithDns({ actor, tenant, ipv4, ttl, comment, reason });
          return scopedSuccess(
            data,
            { operation: "PLAN_CREATE_TENANT_WITH_DNS", tenant: data.tenant },
            `Prepared one combined Cloudflare DNS + Vodia tenant plan for '${data.tenant}'. No changes were made.`
          );
        } catch (error) {
          return failure(error, "tenant + DNS combined plan");
        }
      }
    );

    server.registerTool(
      "apply_tenant_dns_change",
      {
        title: "Apply planned Vodia tenant + Cloudflare DNS creation",
        description: "Apply one unchanged, unexpired combined plan after the exact single confirmation. Creates and verifies Cloudflare DNS first, then creates and verifies the Vodia tenant, then verifies both sides. If Vodia cannot be verified, the newly created Cloudflare record is automatically deleted and that rollback is verified.",
        inputSchema: {
          change_id: z.string().min(1),
          confirmation: z.string().min(1),
        },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
      },
      async ({ change_id, confirmation }) => {
        scopedAudit("apply_tenant_dns_change", {
          change_id,
          confirmation: "[REDACTED_CONFIRMATION]",
        });
        try {
          const data = await applyCreateTenantWithDns({ actor, changeId: change_id, confirmation });
          scopedAudit("tenant_dns_change_applied", {
            operationId: "CreateVodiaTenantWithCloudflareDns",
            status: data.verified ? "verified" : "unverified",
            tenant: data?.vodia?.tenant || null,
            tenant_id: data?.vodia?.tenantId || null,
            record_id: data?.cloudflare?.record?.id || null,
            actor,
          });
          return scopedSuccess(
            data,
            {
              operation: "APPLY_CREATE_TENANT_WITH_DNS",
              tenant: data?.vodia?.tenant || null,
              recordId: data?.cloudflare?.record?.id || null,
            },
            `Created and verified Cloudflare DNS and Vodia tenant '${data?.vodia?.tenant || ""}' under one approved plan.`
          );
        } catch (error) {
          return failure(error, "tenant + DNS combined apply");
        }
      }
    );

'''

s = s[:insert_at] + tools + s[insert_at:]
p.write_text(s)
PY
node --check "$STAGED_INDEX"
echo "PASS"

echo "[4/7] Validate staged registrations and safety boundaries"
python3 - "$STAGED_INDEX" "$STAGED_CF" <<'PY'
from pathlib import Path
import re, sys
idx = Path(sys.argv[1]).read_text()
cf = Path(sys.argv[2]).read_text()

def count_reg(name):
    return len(re.findall(r'server\.registerTool\(\s*["\']' + re.escape(name) + r'["\']', idx, re.S))

checks = {
    'plan_create_tenant_with_dns': count_reg('plan_create_tenant_with_dns'),
    'apply_tenant_dns_change': count_reg('apply_tenant_dns_change'),
    'cloudflare_plan_create_dns_record': count_reg('cloudflare_plan_create_dns_record'),
    'cloudflare_apply_dns_change': count_reg('cloudflare_apply_dns_change'),
}
for name, count in checks.items():
    print(f"{name} exact registration count: {count}")
    if count != 1:
        raise SystemExit(f"VALIDATION ERROR: {name} registration count is {count}, expected 1")

if idx.count('deleteSavedCloudflareDnsRecordById') < 2:
    raise SystemExit('VALIDATION ERROR: delete rollback helper is not imported and used')
if cf.count('export async function deleteSavedCloudflareDnsRecordById') != 1:
    raise SystemExit('VALIDATION ERROR: Cloudflare delete rollback helper export count is not 1')
if 'CREATE VODIA TENANT WITH DNS' not in idx:
    raise SystemExit('VALIDATION ERROR: combined exact confirmation phrase is missing')
if 'proxied: false' not in idx:
    raise SystemExit('VALIDATION ERROR: DNS-only safety default is missing')
if 'Cloudflare rollback PASS' not in idx:
    raise SystemExit('VALIDATION ERROR: verified Cloudflare compensation path is missing')
print('PASS: one-plan/one-approval orchestration and rollback path validated')
PY

echo "PASS"

echo "[5/7] Back up live Phase 2A files and activate staged Phase 2B files"
cp -a "$INDEX" "$INDEX_BAK"
cp -a "$CF" "$CF_BAK"
cp -a "$STAGED_INDEX" "$INDEX"
cp -a "$STAGED_CF" "$CF"
trap rollback ERR
node --check "$INDEX"
node --check "$CF"
echo "index backup: $INDEX_BAK"
echo "cloudflare backup: $CF_BAK"
echo "PASS"

echo "[6/7] Restart service and verify runtime"
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

echo "[7/7] Phase 2B installed"
echo "New customer-facing tools:"
echo "  plan_create_tenant_with_dns"
echo "  apply_tenant_dns_change"
echo "Workflow: preflight both -> one plan -> one exact approval -> DNS create/verify -> tenant create/verify -> final verify both"
echo "Compensation: if tenant cannot be verified, newly created DNS record is deleted and deletion is verified"
echo "PBX/SIP DNS remains DNS-only (proxied=false)"
echo "Backups retained:"
echo "  $INDEX_BAK"
echo "  $CF_BAK"
echo "Reconnect/start a fresh Claude mcp-admin session so it refreshes the tool list."
trap - ERR
