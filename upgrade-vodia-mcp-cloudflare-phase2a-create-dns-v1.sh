#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
CF="$APP/cloudflare-integration.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
INDEX_BAK="$INDEX.pre-cloudflare-phase2a.$STAMP"
CF_BAK="$CF.pre-cloudflare-phase2a.$STAMP"
HEALTH_TMP="/tmp/vodia-cloudflare-phase2a-health.json"

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Phase 2A patch failed; restoring backups..."
  [[ -f "$INDEX_BAK" ]] && cp -a "$INDEX_BAK" "$INDEX" || true
  [[ -f "$CF_BAK" ]] && cp -a "$CF_BAK" "$CF" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
[[ -f "$CF" ]] || fail "missing $CF"

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2A — guarded DNS A-record creation ==="
printf '%s\n' "Adds plan/apply tooling for DNS A-record creation only."
printf '%s\n' "Writes remain approval-gated, actor-bound, expiring, single-use, conflict-checked, and read-back verified."

echo "[1/8] Preflight"
grep -q '"cloudflare_check_connection"' "$INDEX" || fail "Cloudflare Phase 1 MCP tools are not installed"
grep -q '"plan_create_tenant"' "$INDEX" || fail "guarded tenant planner not found"
grep -q '"apply_tenant_change"' "$INDEX" || fail "guarded tenant apply tool not found"
grep -q 'export async function listSavedCloudflareDnsRecords' "$CF" || fail "Cloudflare DNS read helper missing"
if grep -q '"cloudflare_plan_create_dns_record"' "$INDEX"; then
  echo "Cloudflare Phase 2A tools already appear installed. Exiting without changes."
  exit 0
fi
echo "PASS"

echo "[2/8] Back up live files"
cp -a "$INDEX" "$INDEX_BAK"
cp -a "$CF" "$CF_BAK"
echo "index backup: $INDEX_BAK"
echo "cloudflare backup: $CF_BAK"
trap rollback ERR

echo "[3/8] Extend cloudflare-integration.js with guarded write helper"
python3 - "$CF" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if 'export async function createSavedCloudflareARecord' in s:
    print('Cloudflare write helper already present; skipping module patch.')
    raise SystemExit(0)

# Upgrade the internal Cloudflare request helper to support method/body while
# preserving all existing GET callers.
pattern = re.compile(r'async function cf\(path, token\) \{.*?\n\}', re.S)
m = pattern.search(s)
if not m:
    raise SystemExit('PATCH ERROR: could not find async function cf(path, token)')

new_cf = r'''async function cf(path, token, options = {}) {
  const method = String(options.method || "GET").toUpperCase();
  const hasBody = options.body !== undefined;
  const response = await fetch(`${API_BASE}${path}`, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
      ...(hasBody ? { "Content-Type": "application/json" } : {}),
    },
    ...(hasBody ? { body: JSON.stringify(options.body) } : {}),
    signal: AbortSignal.timeout(12000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.success === false) {
    const message = body?.errors?.map((item) => item.message).filter(Boolean).join("; ") || `Cloudflare returned HTTP ${response.status}`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return body;
}'''

s = s[:m.start()] + new_cf + s[m.end():]

anchor = 'export function disconnectCloudflareIntegration() {'
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: disconnectCloudflareIntegration anchor not found')

block = r'''
function cloudflareSavedRow() {
  const database = db();
  const row = database.prepare("SELECT config_json, secret_blob FROM integrations WHERE provider='cloudflare'").get();
  database.close();
  if (!row) throw new Error("Cloudflare is not configured.");
  const config = JSON.parse(row.config_json || "{}");
  if (!config.zoneId || !config.domain) throw new Error("Saved Cloudflare zone metadata is incomplete.");
  return { config, token: open(row.secret_blob) };
}

function normalizeDnsName(value) {
  return String(value || "").trim().toLowerCase().replace(/\.$/, "");
}

function isIpv4(value) {
  const parts = String(value || "").trim().split(".");
  if (parts.length !== 4) return false;
  return parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) >= 0 && Number(part) <= 255 && String(Number(part)) === part);
}

function mapDnsRecord(record) {
  if (!record) return null;
  return {
    id: record.id,
    type: record.type,
    name: record.name,
    content: record.content,
    ttl: record.ttl,
    proxied: record.proxied ?? null,
    comment: record.comment || null,
  };
}

export async function createSavedCloudflareARecord({ name, ipv4, ttl = 1, proxied = false, comment = "" } = {}) {
  const { config, token } = cloudflareSavedRow();
  const zoneName = normalizeDnsName(config.domain);
  const fqdn = normalizeDnsName(name);
  const address = String(ipv4 || "").trim();
  const normalizedTtl = Number(ttl || 1);

  if (!fqdn) throw new Error("DNS record name is required.");
  if (!(fqdn === zoneName || fqdn.endsWith(`.${zoneName}`))) {
    throw new Error(`DNS name '${fqdn}' is outside the configured Cloudflare zone '${zoneName}'.`);
  }
  if (!isIpv4(address)) throw new Error(`'${address}' is not a valid IPv4 address.`);
  if (!Number.isInteger(normalizedTtl) || normalizedTtl < 1 || normalizedTtl > 86400) {
    throw new Error("TTL must be 1 (Auto) or an integer from 60 through 86400 seconds.");
  }
  if (normalizedTtl !== 1 && normalizedTtl < 60) throw new Error("TTL values other than Auto must be at least 60 seconds.");

  const existingQuery = new URLSearchParams({ name: fqdn, per_page: "100" });
  const existing = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records?${existingQuery}`, token);
  const exactExisting = (existing.result || []).filter((record) => normalizeDnsName(record?.name) === fqdn);
  if (exactExisting.length) {
    throw new Error(`DNS name '${fqdn}' now has ${exactExisting.length} existing record(s); refusing creation.`);
  }

  let createdId = null;
  try {
    const created = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records`, token, {
      method: "POST",
      body: {
        type: "A",
        name: fqdn,
        content: address,
        ttl: normalizedTtl,
        proxied: Boolean(proxied),
        ...(String(comment || "").trim() ? { comment: String(comment).trim().slice(0, 500) } : {}),
      },
    });
    createdId = created?.result?.id || null;
    if (!createdId) throw new Error("Cloudflare accepted the create request but returned no DNS record ID.");

    const verifyQuery = new URLSearchParams({ type: "A", name: fqdn, per_page: "100" });
    const verify = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records?${verifyQuery}`, token);
    const record = (verify.result || []).find((item) => item?.id === createdId);
    if (!record) throw new Error(`Cloudflare created record ID ${createdId}, but read-back could not find it.`);
    if (normalizeDnsName(record.name) !== fqdn || String(record.content || "") !== address || record.type !== "A") {
      throw new Error("Cloudflare DNS read-back did not match the requested A record.");
    }
    if (Boolean(record.proxied) !== Boolean(proxied)) {
      throw new Error("Cloudflare DNS read-back proxy state did not match the requested value.");
    }

    return {
      provider: "cloudflare",
      domain: zoneName,
      created: true,
      verified: true,
      record: mapDnsRecord(record),
    };
  } catch (error) {
    if (createdId) {
      try {
        await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records/${encodeURIComponent(createdId)}`, token, { method: "DELETE" });
        error.message = `${error.message} Automatic rollback deleted Cloudflare record ID ${createdId}.`;
      } catch (rollbackError) {
        error.message = `${error.message} ROLLBACK WARNING: Cloudflare record ID ${createdId} may remain: ${rollbackError.message}`;
      }
    }
    throw error;
  }
}

'''

s = s[:idx] + block + s[idx:]
p.write_text(s)
PY

echo "PASS"

echo "[4/8] Patch index.js with actor-bound expiring plan/apply tools"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if '"cloudflare_plan_create_dns_record"' in s:
    print('Phase 2A MCP tools already present; skipping index patch.')
    raise SystemExit(0)

# Add the new module helper to the existing Cloudflare import block.
imp_re = re.compile(r'import \{(?P<body>.*?)\} from "\./cloudflare-integration\.js";', re.S)
m = imp_re.search(s)
if not m:
    raise SystemExit('PATCH ERROR: Cloudflare import block not found')
body = m.group('body')
if 'createSavedCloudflareARecord' not in body:
    body = body.rstrip() + ',\n  createSavedCloudflareARecord,\n'
    repl = 'import {' + body + '} from "./cloudflare-integration.js";'
    s = s[:m.start()] + repl + s[m.end():]

# Insert plan/apply implementation before the existing tenant planner so it is
# top-level and not nested inside createVodiaServer helpers.
anchor = 'async function planCreateTenant({ actor, tenant, reason } = {}) {'
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: planCreateTenant anchor not found')

logic = r'''
const CLOUDFLARE_DNS_CREATE_PLAN_TTL_MS = 5 * 60 * 1000;
const cloudflareDnsCreatePlans = new Map();

function normalizeCloudflarePlanName(value) {
  return String(value || "").trim().toLowerCase().replace(/\.$/, "");
}

function validateIpv4ForPlan(value) {
  const text = String(value || "").trim();
  const parts = text.split(".");
  if (parts.length !== 4) throw new Error(`'${text}' is not a valid IPv4 address.`);
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part) || Number(part) < 0 || Number(part) > 255 || String(Number(part)) !== part) {
      throw new Error(`'${text}' is not a valid IPv4 address.`);
    }
  }
  return text;
}

async function planCloudflareCreateDnsRecord({ actor, name, ipv4, ttl = 1, proxied = false, comment = "", reason = "" } = {}) {
  const status = getCloudflareIntegrationStatus();
  if (!status?.configured || !status?.domain) throw new Error("Cloudflare is not configured.");

  const zone = normalizeCloudflarePlanName(status.domain);
  const fqdn = normalizeCloudflarePlanName(name);
  const address = validateIpv4ForPlan(ipv4);
  const normalizedTtl = Number(ttl || 1);

  if (!fqdn) throw new Error("DNS record name is required.");
  if (!(fqdn === zone || fqdn.endsWith(`.${zone}`))) {
    throw new Error(`DNS name '${fqdn}' is outside configured zone '${zone}'.`);
  }
  if (!Number.isInteger(normalizedTtl) || normalizedTtl < 1 || normalizedTtl > 86400 || (normalizedTtl !== 1 && normalizedTtl < 60)) {
    throw new Error("TTL must be 1 (Auto) or an integer from 60 through 86400 seconds.");
  }

  const before = await listSavedCloudflareDnsRecords({ name: fqdn });
  const exact = (Array.isArray(before?.records) ? before.records : []).filter(
    (record) => normalizeCloudflarePlanName(record?.name) === fqdn
  );
  if (exact.length) throw new Error(`DNS name '${fqdn}' already has ${exact.length} record(s).`);

  const changeId = `cfdns-${globalThis.crypto?.randomUUID?.() || Date.now()}`;
  const expiresAt = new Date(Date.now() + CLOUDFLARE_DNS_CREATE_PLAN_TTL_MS);
  const dnsOnly = !Boolean(proxied);
  const requiredConfirmation = `CREATE CLOUDFLARE A ${fqdn} ${address} ${dnsOnly ? "DNS-ONLY" : "PROXIED"}`;

  cloudflareDnsCreatePlans.set(changeId, {
    changeId,
    actor: String(actor || "unknown"),
    operation: "create_a",
    zone,
    name: fqdn,
    ipv4: address,
    ttl: normalizedTtl,
    proxied: Boolean(proxied),
    comment: String(comment || "").trim().slice(0, 500),
    reason: String(reason || "").trim().slice(0, 1000),
    expiresAt,
    requiredConfirmation,
    used: false,
  });

  return {
    changeId,
    operation: "CreateCloudflareARecord",
    zone,
    type: "A",
    name: fqdn,
    content: address,
    ttl: normalizedTtl,
    ttlDisplay: normalizedTtl === 1 ? "Auto" : normalizedTtl,
    proxied: Boolean(proxied),
    dnsOnly,
    comment: String(comment || "").trim().slice(0, 500) || null,
    reason: String(reason || "").trim().slice(0, 1000) || null,
    expiresAt: expiresAt.toISOString(),
    requiredConfirmation,
    changesCloudflare: false,
    preflight: { exactNameConflict: false, existingExactRecordCount: 0 },
  };
}

async function applyCloudflareDnsCreate({ actor, changeId, confirmation } = {}) {
  const id = String(changeId || "").trim();
  const plan = cloudflareDnsCreatePlans.get(id);
  if (!plan) throw new Error("Cloudflare DNS plan was not found, expired, or was already used.");
  if (plan.used) throw new Error("Cloudflare DNS plan was already used.");
  if (Date.now() > plan.expiresAt.getTime()) {
    cloudflareDnsCreatePlans.delete(id);
    throw new Error("Cloudflare DNS plan expired. Prepare it again.");
  }
  if (String(actor || "unknown") !== plan.actor) {
    throw new Error("Cloudflare DNS plan belongs to a different administrator identity.");
  }
  if (String(confirmation || "") !== plan.requiredConfirmation) {
    throw new Error("Confirmation does not exactly match requiredConfirmation.");
  }

  const current = getCloudflareIntegrationStatus();
  if (!current?.configured || normalizeCloudflarePlanName(current.domain) !== plan.zone) {
    throw new Error("Cloudflare integration zone changed after planning; refusing write.");
  }

  const before = await listSavedCloudflareDnsRecords({ name: plan.name });
  const exact = (Array.isArray(before?.records) ? before.records : []).filter(
    (record) => normalizeCloudflarePlanName(record?.name) === plan.name
  );
  if (exact.length) {
    cloudflareDnsCreatePlans.delete(id);
    throw new Error(`DNS name '${plan.name}' now has ${exact.length} record(s); refusing write.`);
  }

  plan.used = true;
  try {
    const result = await createSavedCloudflareARecord({
      name: plan.name,
      ipv4: plan.ipv4,
      ttl: plan.ttl,
      proxied: plan.proxied,
      comment: plan.comment,
    });
    cloudflareDnsCreatePlans.delete(id);
    return {
      changeId: id,
      operation: "CreateCloudflareARecord",
      zone: plan.zone,
      verified: Boolean(result?.verified),
      record: result?.record || null,
      changesMade: true,
    };
  } catch (error) {
    cloudflareDnsCreatePlans.delete(id);
    throw error;
  }
}

'''

s = s[:idx] + logic + s[idx:]

# Insert the tool registrations inside the existing adminMode block, immediately
# before the first AWS Chime write planner. This is safely outside
# registerPbXReadTool(), avoiding the duplicate-registration bug fixed earlier.
anchor2 = '    server.registerTool(\n      "aws_chime_plan_create_voice_connector",'
idx2 = s.find(anchor2)
if idx2 < 0:
    raise SystemExit('PATCH ERROR: AWS Chime planner anchor not found inside adminMode block')

tools = r'''    server.registerTool(
      "cloudflare_plan_create_dns_record",
      {
        title: "Plan Cloudflare DNS A record creation",
        description: "Prepare an expiring, actor-bound plan to create one Cloudflare A record in the configured zone. Performs a live exact-name conflict check and makes no DNS change. For PBX/SIP/Teams hostnames, proxied should normally remain false (DNS only).",
        inputSchema: {
          name: z.string().min(3).max(253),
          ipv4: z.string().min(7).max(15),
          ttl: z.number().int().min(1).max(86400).optional(),
          proxied: z.boolean().optional(),
          comment: z.string().max(500).optional(),
          reason: z.string().max(1000).optional(),
        },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
      },
      async ({ name, ipv4, ttl, proxied, comment, reason }) => {
        scopedAudit("cloudflare_plan_create_dns_record", { name, ipv4, ttl, proxied, reason });
        try {
          const data = await planCloudflareCreateDnsRecord({ actor, name, ipv4, ttl, proxied, comment, reason });
          return scopedSuccess(
            data,
            { provider: "Cloudflare", operation: "PLAN_CREATE_DNS_A_RECORD", name: data.name },
            `Prepared Cloudflare A record creation for '${data.name}'. No DNS changes were made. Review the exact record and use the required confirmation to apply.`
          );
        } catch (error) {
          return failure(error, "Cloudflare DNS creation plan");
        }
      }
    );

    server.registerTool(
      "cloudflare_apply_dns_change",
      {
        title: "Apply planned Cloudflare DNS change",
        description: "Apply one unchanged, unexpired Cloudflare DNS A-record creation plan after exact confirmation. Re-checks for conflicts immediately before write, creates the record, reads it back, verifies its values, and automatically attempts rollback if verification fails.",
        inputSchema: {
          change_id: z.string().min(1),
          confirmation: z.string().min(1),
        },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true },
      },
      async ({ change_id, confirmation }) => {
        scopedAudit("cloudflare_apply_dns_change", {
          change_id,
          confirmation: "[REDACTED_CONFIRMATION]",
        });
        try {
          const data = await applyCloudflareDnsCreate({ actor, changeId: change_id, confirmation });
          scopedAudit("cloudflare_dns_change_applied", {
            operationId: "CreateCloudflareARecord",
            status: data.verified ? "verified" : "unverified",
            record_id: data?.record?.id || null,
            name: data?.record?.name || null,
            type: data?.record?.type || "A",
          });
          return scopedSuccess(
            data,
            { provider: "Cloudflare", operation: "APPLY_CREATE_DNS_A_RECORD", recordId: data?.record?.id || null },
            `Created and verified Cloudflare A record '${data?.record?.name || ""}'.`
          );
        } catch (error) {
          return failure(error, "Cloudflare DNS creation apply");
        }
      }
    );

'''

s = s[:idx2] + tools + s[idx2:]
p.write_text(s)
PY

echo "PASS"

echo "[5/8] Validate JavaScript and registration boundaries"
node --check "$CF"
node --check "$INDEX"
[[ "$(grep -c '"cloudflare_plan_create_dns_record"' "$INDEX")" -eq 1 ]] || fail "cloudflare_plan_create_dns_record registration count is not 1"
[[ "$(grep -c '"cloudflare_apply_dns_change"' "$INDEX")" -eq 1 ]] || fail "cloudflare_apply_dns_change registration count is not 1"
# Confirm Phase 1 tools are still present once by registration name.
for t in cloudflare_check_connection cloudflare_get_zone cloudflare_list_dns_records cloudflare_get_dns_record; do
  [[ "$(grep -c "\"$t\"" "$INDEX")" -ge 1 ]] || fail "missing existing tool $t"
done
echo "PASS"

echo "[6/8] Restart service"
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
  fail "service did not return healthy after patch"
}
cat "$HEALTH_TMP"
echo

echo "[7/8] Check startup logs for duplicate registration/runtime errors"
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register' >/tmp/vodia-phase2a-errors.txt; then
  cat /tmp/vodia-phase2a-errors.txt
  fail "runtime error detected after restart"
fi
echo "PASS"

echo "[8/8] Phase 2A installed"
echo "New tools:"
echo "  cloudflare_plan_create_dns_record"
echo "  cloudflare_apply_dns_change"
echo "Safety behavior: plan -> exact approval -> conflict re-check -> create -> read-back verify -> automatic rollback on verification failure"
echo "Default for PBX/SIP hostnames: proxied=false (DNS only)"
echo "Backups retained:"
echo "  $INDEX_BAK"
echo "  $CF_BAK"
echo "Reconnect/start a fresh Claude MCP session so the new tools are loaded."
trap - ERR
