#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
ADMIN="$APP/admin.js"
VERSION="$APP/version.js"
SERVICE=vodia-mcp
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9-tenant-country-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"

echo "=== Vodia MCP v0.14.9 — Tenant Country Code ==="
echo "[1/8] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
test -f "$ADMIN" || fail "missing $ADMIN"
test -f "$VERSION" || fail "missing $VERSION"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$ADMIN" >/dev/null || fail "current admin.js syntax invalid"
grep -q '"plan_create_tenant"' "$INDEX" || fail "plan_create_tenant missing"
grep -q '"apply_tenant_change"' "$INDEX" || fail "apply_tenant_change missing"
grep -q 'async function planCreateTenant' "$INDEX" || fail "planCreateTenant helper missing"
grep -q 'async function applyCreateTenant' "$INDEX" || fail "applyCreateTenant helper missing"
grep -q '"plan_account_batch"' "$ADMIN" || fail "v0.14.8 account-batch prerequisite missing"
if grep -q 'v0.14.9 tenant country-code validation' "$INDEX"; then
  fail "tenant country-code patch already installed"
fi
echo PASS

echo "[2/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"

echo "[3/8] Patch tenant plan/apply workflow"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

def replace_once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"PATCH ERROR: expected one {label}; found {count}")
    s = s.replace(old, new, 1)

replace_once(
    'const TENANT_CREATE_PLAN_TTL_MS = 5 * 60 * 1000;',
    '''const TENANT_CREATE_PLAN_TTL_MS = 5 * 60 * 1000;
// v0.14.9 tenant country-code validation. This is the exact format constraint
// captured from Vodia 70.x. Values contain digits only and omit the leading "+".
const VODIA_TENANT_COUNTRY_CODE_PATTERN = /^(?:1|2[078]|2[1234569]\\d|3[0123469]|3[578]\\d|4[013-9]|42\\d|5[1-8]|5[09]\\d|6[0-6]|6[7-9]\\d|7|8[123469]|8[0578]\\d|9[0123458]|9[679]\\d)$/;

function normalizeTenantCountryCode(value) {
  const normalized = String(value ?? "").trim();
  if (!VODIA_TENANT_COUNTRY_CODE_PATTERN.test(normalized)) {
    throw new Error('country_code must match the country calling-code format accepted by Vodia: digits only and no leading "+".');
  }
  return normalized;
}

async function readTenantSystemInfo(tenant) {
  const wanted = String(tenant || "").trim().toLowerCase();
  const pageSize = 100;
  for (let page = 1; page <= 100; page += 1) {
    const list = await vodiaSystemJson({ path: `/rest/system/domaininfo?size=${pageSize}&page=${page}` });
    const rows = Array.isArray(list.data) ? list.data : [];
    const match = rows.find((row) => {
      if (!row || typeof row !== "object") return false;
      const names = [row.name, row.primary, row.display, ...(Array.isArray(row.alias) ? row.alias : [])]
        .map((value) => String(value || "").trim().toLowerCase())
        .filter(Boolean);
      return names.includes(wanted);
    });
    if (match && match.id != null) {
      const detail = await vodiaSystemJson({ path: `/rest/system/domaininfo?id=${encodeURIComponent(String(match.id))}` });
      const value = Array.isArray(detail.data) ? detail.data[0] : detail.data;
      return value && typeof value === "object" ? value : null;
    }
    if (rows.length < pageSize) break;
  }
  return null;
}''',
    'tenant TTL anchor',
)

replace_once(
    'async function planCreateTenant({ actor, tenant, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);',
    'async function planCreateTenant({ actor, tenant, countryCode, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);',
    'planCreateTenant signature',
)

replace_once(
    'const requiredConfirmation = `CREATE VODIA TENANT ${normalized}`;',
    'const requiredConfirmation = `CREATE VODIA TENANT ${normalized} COUNTRY ${normalizedCountryCode}`;',
    'tenant confirmation',
)

replace_once(
    '      tenant: normalized,\n      reason: String(reason || "3CX migration tenant creation"),',
    '      tenant: normalized,\n      countryCode: normalizedCountryCode,\n      reason: String(reason || "3CX migration tenant creation"),',
    'stored tenant plan fields',
)

replace_once(
    '    tenant: normalized,\n    reason: String(reason || "3CX migration tenant creation"),',
    '    tenant: normalized,\n    countryCode: normalizedCountryCode,\n    country_code: normalizedCountryCode,\n    reason: String(reason || "3CX migration tenant creation"),',
    'public tenant plan fields',
)

replace_once(
    '''    await vodiaSystemJson({
      method: "POST",
      path: "/rest/system/domains",
      body: [plan.tenant],
    });

    // Independently verify via the list endpoint.''',
    '''    await vodiaSystemJson({
      method: "POST",
      path: "/rest/system/domains",
      body: [plan.tenant],
    });

    // Vodia creates the domain first. The portal stores its calling code in a
    // second request to /rest/domain/{tenant}/config. Treat both writes as one
    // guarded workflow and report a clear partial result if configuration fails.
    try {
      const configPath = `/rest/domain/${encodeURIComponent(plan.tenant)}/config`;
      const beforeConfigResponse = await vodiaSystemJson({ path: configPath });
      const rawConfig = Array.isArray(beforeConfigResponse.data) ? beforeConfigResponse.data[0] : beforeConfigResponse.data;
      if (!rawConfig || typeof rawConfig !== "object") {
        throw new Error("tenant config could not be read after domain creation");
      }

      const writableFields = new Set([
        "primary", "alias", "admins", "country_code", "display", "license_key",
        "max_extensions", "max_attendants", "max_callingcards", "max_hunts", "max_hoots",
        "max_srvflags", "max_ivrnodes", "max_doors", "max_acds", "max_conferences",
        "max_colines", "max_calls", "max_trunk_calls", "max_trunk_notify",
        "max_call_duration", "max_regs", "parm1", "parm2", "parm3", "billing_start",
        "bill_customer", "bill_admin", "bill_data", "bill_plan", "voice2text",
        "google_voice2text_key", "spamreject", "sms_enabled", "didr", "rec_enabled",
        "cloud_provider_public", "lastdigits", "cdr_keep", "rec_keep", "visible",
      ]);
      const configBody = Object.fromEntries(
        Object.entries(rawConfig).filter(([key, value]) => writableFields.has(key) && value !== undefined)
      );
      configBody.primary = String(configBody.primary || plan.tenant);
      configBody.alias = Array.isArray(configBody.alias) && configBody.alias.length ? configBody.alias : [plan.tenant];
      configBody.admins = Array.isArray(configBody.admins) ? configBody.admins : [];
      configBody.country_code = plan.countryCode;

      await vodiaSystemJson({ method: "POST", path: configPath, body: configBody });

      // Independent system-level verification. The write field is country_code;
      // /rest/system/domaininfo returns it as country, as verified by portal HAR.
      const systemInfo = await readTenantSystemInfo(plan.tenant);
      const verifiedCountry = String(systemInfo?.country ?? "").trim();
      if (verifiedCountry !== plan.countryCode) {
        throw new Error(`country read-back was '${verifiedCountry || "empty"}', expected '${plan.countryCode}'`);
      }
    } catch (error) {
      tenantCreatePlans.delete(id);
      throw new Error(
        `PARTIAL TENANT CREATION: '${plan.tenant}' was created, but country_code '${plan.countryCode}' was not verified. ` +
        `Use the guarded tenant-settings workflow to set and verify country_code before creating accounts. Cause: ${String(error?.message || error)}`
      );
    }

    // Independently verify the tenant name via the list endpoint.''',
    'tenant create/config block',
)

replace_once(
    '      tenant: plan.tenant,\n      verified: true,',
    '      tenant: plan.tenant,\n      countryCode: plan.countryCode,\n      country_code: plan.countryCode,\n      countryVerified: true,\n      verified: true,',
    'tenant apply result',
)

replace_once(
    '''        inputSchema: {
          tenant: z.string().min(3).max(253),
          reason: z.string().max(1000).optional(),
        },''',
    '''        inputSchema: {
          tenant: z.string().min(3).max(253),
          country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),
          reason: z.string().max(1000).optional(),
        },''',
    'plan_create_tenant schema',
)

replace_once(
    '      async ({ tenant, reason }) => {\n        scopedAudit("plan_create_tenant", { tenant, reason });',
    '      async ({ tenant, country_code, reason }) => {\n        scopedAudit("plan_create_tenant", { tenant, country_code, reason });',
    'plan_create_tenant handler',
)

replace_once(
    'const data = await planCreateTenant({ actor, tenant, reason });',
    'const data = await planCreateTenant({ actor, tenant, countryCode: country_code, reason });',
    'planCreateTenant call',
)

replace_once(
    '{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant },',
    '{ operation: "PLAN_CREATE_TENANT", tenant: data.tenant, country_code: data.country_code },',
    'tenant plan metadata',
)

replace_once(
    'changed_fields: ["tenant"],',
    'changed_fields: ["tenant", "country_code"],',
    'tenant audit fields',
)

replace_once(
    '{ operation: "APPLY_CREATE_TENANT", tenant: data.tenant },',
    '{ operation: "APPLY_CREATE_TENANT", tenant: data.tenant, country_code: data.country_code },',
    'tenant apply metadata',
)

replace_once(
    "`Created and verified Vodia tenant '${data.tenant}'.`",
    "`Created and verified Vodia tenant '${data.tenant}' with country code '${data.country_code}'.`",
    'tenant success message',
)

p.write_text(s)
PY
echo PASS

echo "[4/8] Patch version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])', r'\g<1>0.14.9\2', s, count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
echo PASS

echo "[5/8] Static validation"
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
grep -q 'v0.14.9 tenant country-code validation' "$TMP_INDEX" || fail "country patch marker missing"
grep -q 'VODIA_TENANT_COUNTRY_CODE_PATTERN' "$TMP_INDEX" || fail "country validation missing"
grep -q 'country_code: z.string().regex' "$TMP_INDEX" || fail "country input missing"
grep -q 'COUNTRY ${normalizedCountryCode}' "$TMP_INDEX" || fail "country confirmation binding missing"
grep -q 'PARTIAL TENANT CREATION' "$TMP_INDEX" || fail "partial-state handling missing"
grep -q 'countryVerified: true' "$TMP_INDEX" || fail "country verification result missing"
grep -q '0.14.9' "$TMP_VERSION" || fail "version marker missing"
echo PASS

if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then
  echo "PATCH-ONLY PASS: source patch and static validation completed; nothing was installed or restarted."
  exit 0
fi

echo "[6/8] Install"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
if ! node --check "$INDEX" >/dev/null || ! node --check "$VERSION" >/dev/null; then
  cp -a "$BACKUP_DIR/index.js" "$INDEX"
  cp -a "$BACKUP_DIR/version.js" "$VERSION"
  fail "live syntax failed; backup restored"
fi
echo PASS

echo "[7/8] Restart + health"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP_DIR/index.js" "$INDEX"
  cp -a "$BACKUP_DIR/version.js" "$VERSION"
  systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP_DIR/index.js" "$INDEX"
  cp -a "$BACKUP_DIR/version.js" "$VERSION"
  systemctl restart "$SERVICE" || true
  fail "service unhealthy; backup restored"
fi
HEALTH="$(curl -fsS http://127.0.0.1:3100/health || true)"
[[ -n "$HEALTH" ]] || echo "WARN: local /health check unavailable; service itself is active"
echo PASS

echo "[8/8] Verify markers"
grep -n -E 'VODIA_TENANT_COUNTRY_CODE_PATTERN|country_code: z.string|PARTIAL TENANT CREATION|countryVerified' "$INDEX" | head -30
grep -n '0.14.9' "$VERSION" || true

echo
echo "=== v0.14.9 INSTALL PASS ==="
echo "Backup: $BACKUP_DIR"
echo "PBX writes performed by installer: 0"
echo "Updated admin tools: plan_create_tenant, apply_tenant_change"
echo "Required tenant input: country_code (digits only, no +)"
echo "Apply sequence: create tenant -> set country_code -> verify tenant + country"
echo
echo "Rollback:"
echo "  cp -a '$BACKUP_DIR/index.js' '$INDEX'"
echo "  cp -a '$BACKUP_DIR/version.js' '$VERSION'"
echo "  systemctl restart '$SERVICE'"
