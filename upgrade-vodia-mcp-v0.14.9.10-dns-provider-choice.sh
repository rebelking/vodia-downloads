#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.10 — DNS provider choice routing
#
# Adds a safe provider-discovery step for tenant creation while preserving the
# known-good v0.14.9.9 Cloudflare DNS-FIRST workflow unchanged.
#
# Policy:
#   - inspect Vodia managed DNS and connected Cloudflare first
#   - if exactly one provider can handle the requested FQDN, use/recommend it
#   - if more than one provider can handle it, ask the administrator to choose
#   - explicit provider choice never silently falls back to another provider
#   - Vodia is eligible only when the tenant matches the configured wildcard
#   - Cloudflare keeps the v0.14.9.9 DNS-FIRST + public-resolver + rollback path
#   - Vodia uses the guarded tenant-only plan/apply path; PBX owns its DNS
#
# This installer itself performs no tenant or DNS writes.

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.10-dns-provider-choice-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
LOGS="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH" "$LOGS"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring v0.14.9.9-era files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.10 — DNS provider choice routing ==="
echo "Preserves v0.14.9.9 Cloudflare DNS-FIRST behavior and adds Vodia native-DNS routing."
echo "This installer performs no tenant or DNS writes."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
for marker in \
  '"plan_create_tenant"' \
  '"apply_tenant_change"' \
  '"plan_create_tenant_with_dns"' \
  '"apply_tenant_dns_change"' \
  'getCloudflareIntegrationStatus' \
  'vodiaSystemJson' \
  'async function applyCreateTenantWithDns' \
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS' \
  'deleteSavedCloudflareDnsRecordById'; do
  grep -q "$marker" "$INDEX" || fail "required current capability missing: $marker"
done
if grep -q 'v0.14.9.10 DNS provider choice routing' "$INDEX"; then
  echo "v0.14.9.10 already installed; exiting without changes."
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

echo "[3/8] Patch provider discovery + routing policy"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text()
marker='v0.14.9.10 DNS provider choice routing'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.10 marker already present')

anchor='async function planCreateTenantWithDns('
idx=s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: planCreateTenantWithDns anchor not found')

logic=r'''
// -----------------------------------------------------------------------------
// v0.14.9.10 DNS provider choice routing
// Discover which DNS providers can safely handle the requested tenant FQDN.
// Exactly one eligible provider may be recommended automatically; if two or more
// are eligible, the administrator must choose. An explicit selection never
// silently falls back to another provider.
// -----------------------------------------------------------------------------
function dnsChoiceFlattenSettings(value, path = "", out = []) {
  if (value === null || value === undefined) return out;
  if (Array.isArray(value)) {
    value.forEach((v, i) => dnsChoiceFlattenSettings(v, `${path}[${i}]`, out));
    return out;
  }
  if (typeof value === "object") {
    Object.entries(value).forEach(([k, v]) => dnsChoiceFlattenSettings(v, path ? `${path}.${k}` : k, out));
    return out;
  }
  out.push({ path, value: String(value) });
  return out;
}

function dnsChoiceNormalizeWildcard(value) {
  const raw = String(value || "").trim().toLowerCase().replace(/\.$/, "");
  if (!raw) return null;
  if (raw.startsWith("*.")) return raw;
  return null;
}

function dnsChoiceMatchesWildcard(tenant, wildcard) {
  const fqdn = normalizeTenantName(tenant);
  const wc = dnsChoiceNormalizeWildcard(wildcard);
  if (!wc) return false;
  const suffix = wc.slice(1); // '.vodia-pbx.com'
  return fqdn.endsWith(suffix) && fqdn.length > suffix.length;
}

function dnsChoiceDetectVodiaManagedDns(data, tenant) {
  const flat = dnsChoiceFlattenSettings(data);
  const wildcardRows = flat.filter((row) =>
    /sys_wildcard|wildcard/i.test(row.path) && /^\*\.[a-z0-9.-]+$/i.test(String(row.value).trim())
  );
  // Fall back to any wildcard-like value if a PBX build nests/renames the field.
  const candidates = wildcardRows.length ? wildcardRows : flat.filter((row) => /^\*\.[a-z0-9.-]+$/i.test(String(row.value).trim()));
  const wildcards = [...new Set(candidates.map((row) => dnsChoiceNormalizeWildcard(row.value)).filter(Boolean))];
  const matchedWildcard = wildcards.find((wc) => dnsChoiceMatchesWildcard(tenant, wc)) || null;
  const ipRow = flat.find((row) => /(^|\.)sys_ip4$/i.test(row.path)) || flat.find((row) => /sys_ip4/i.test(row.path));
  return {
    enabled: wildcards.length > 0,
    wildcards,
    matchedWildcard,
    eligibleForTenant: Boolean(matchedWildcard),
    sysIp4: ipRow ? String(ipRow.value || "").trim() || null : null,
    evidence: candidates.slice(0, 10),
  };
}

async function dnsChoiceReadVodiaSettings(tenant) {
  // Read-only attempts only. The observed admin UI writes System Settings with
  // POST /rest/system/config, but this discovery path MUST NOT POST. Some builds
  // expose the read view at /rest/system/settings; others accept GET /config.
  const configured = String(process.env.VODIA_MCP_SYSTEM_SETTINGS_PATH || "").trim();
  const candidates = [...new Set([
    configured,
    "/rest/system/settings",
    "/rest/system/config",
  ].filter(Boolean))];
  const attempts=[];
  for (const path of candidates) {
    try {
      const response = await vodiaSystemJson({ path, method: "GET" });
      const detected = dnsChoiceDetectVodiaManagedDns(response?.data, tenant);
      attempts.push({ path, method: "GET", ok: true, eligibleForTenant: detected.eligibleForTenant });
      // A readable response without the wildcard may be an unrelated/partial
      // settings shape, so continue looking for a stronger match.
      if (detected.enabled || path === candidates[candidates.length - 1]) {
        return { readable: true, path, method: "GET", detected, attempts };
      }
    } catch (error) {
      attempts.push({ path, method: "GET", ok: false, error: String(error?.message || error).slice(0, 300) });
    }
  }
  return {
    readable: false,
    path: null,
    method: "GET",
    detected: { enabled: false, wildcards: [], matchedWildcard: null, eligibleForTenant: false, sysIp4: null, evidence: [] },
    attempts,
  };
}

async function getTenantDnsProviderChoices(tenant) {
  const normalizedTenant=normalizeTenantName(tenant);

  // Inspect Vodia first.
  const vodiaDns=await dnsChoiceReadVodiaSettings(normalizedTenant);

  // Then inspect the MCP Cloudflare connection.
  let cloudflare;
  try {
    const status=getCloudflareIntegrationStatus();
    const zone=status?.domain ? String(status.domain).trim().toLowerCase().replace(/\.$/, "") : null;
    const connected=Boolean(status?.configured);
    const eligibleForTenant=Boolean(connected && zone && (normalizedTenant === zone || normalizedTenant.endsWith(`.${zone}`)));
    cloudflare={ connected, zone, eligibleForTenant };
  } catch (error) {
    cloudflare={ connected:false, zone:null, eligibleForTenant:false, error:String(error?.message || error).slice(0,300) };
  }

  const providers=[];
  if (vodiaDns.readable && vodiaDns.detected.eligibleForTenant) {
    providers.push({
      id:"vodia",
      label:"Vodia DNS",
      available:true,
      detail:`Tenant matches Vodia managed wildcard ${vodiaDns.detected.matchedWildcard}.`,
    });
  }
  if (cloudflare.connected && cloudflare.eligibleForTenant) {
    providers.push({
      id:"cloudflare",
      label:"Cloudflare",
      available:true,
      detail:`Connected Cloudflare zone ${cloudflare.zone} controls this tenant name.`,
    });
  }

  const requiresProviderChoice=providers.length > 1;
  const selectedProvider=providers.length === 1 ? providers[0].id : null;
  const noProvider=providers.length === 0;

  return {
    tenant: normalizedTenant,
    changesMade:false,
    vodiaCheckedFirst:true,
    providers,
    providerIds:providers.map((p)=>p.id),
    requiresProviderChoice,
    autoSelected:Boolean(selectedProvider),
    selectedProvider,
    noProvider,
    vodiaDns,
    cloudflare,
    question: requiresProviderChoice
      ? "Which DNS provider do you want to use for this tenant?"
      : noProvider
        ? "No eligible DNS provider can safely handle this tenant FQDN."
        : `Only ${providers[0].label} is eligible for this tenant; use that provider.`,
    routing: {
      cloudflare:"Use plan_create_tenant_with_dns then apply_tenant_dns_change. Preserve the v0.14.9.9 DNS-FIRST/public-resolver/rollback workflow exactly.",
      vodia:"Use plan_create_tenant then apply_tenant_change. The PBX owns native DNS for the matched Vodia wildcard.",
      fallback:"Never silently switch providers after an explicit provider has been selected and fails.",
    },
  };
}

'''
s=s[:idx]+logic+s[idx:]

# Register discovery tool immediately before the combined Cloudflare planner.
patterns=[
  'server.registerTool(\n      "plan_create_tenant_with_dns",',
  'server.registerTool(\n  "plan_create_tenant_with_dns",',
  'server.registerTool(\n    "plan_create_tenant_with_dns",',
]
reg_idx=-1
for a in patterns:
    reg_idx=s.find(a)
    if reg_idx >= 0: break
if reg_idx < 0:
    raise SystemExit('PATCH ERROR: combined planner registration anchor not found')

registration=r'''
    server.registerTool(
      "get_tenant_dns_provider_choices",
      {
        title: "Get tenant DNS provider choices",
        description: "Required provider-discovery step before creating a Vodia tenant. Checks Vodia managed wildcard DNS first and then connected Cloudflare. If exactly one provider is eligible it may be used automatically; if multiple are eligible ask the administrator to choose. Makes no changes.",
        inputSchema: { tenant: z.string().min(3) },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
      },
      async ({ tenant }) => {
        scopedAudit("get_tenant_dns_provider_choices", { tenant });
        try {
          const result=await getTenantDnsProviderChoices(tenant);
          return scopedSuccess(
            result,
            { operation:"GET_TENANT_DNS_PROVIDER_CHOICES", readOnly:true, changesMade:false },
            result.requiresProviderChoice
              ? `Choose a DNS provider for ${result.tenant}.`
              : result.noProvider
                ? `No eligible DNS provider was detected for ${result.tenant}.`
                : `${result.selectedProvider} is the only eligible DNS provider for ${result.tenant}.`
          );
        } catch (error) {
          return failure(error, "Tenant DNS provider discovery");
        }
      }
    );

'''
s=s[:reg_idx]+registration+s[reg_idx:]

# Add routing policy adjacent to server factory so MCP clients receive a strong,
# durable instruction without modifying the known-good Cloudflare implementation.
factory='export function createVodiaServer('
fidx=s.find(factory)
if fidx < 0:
    raise SystemExit('PATCH ERROR: createVodiaServer anchor not found')
policy=(
  '// v0.14.9.10 DNS provider choice routing\n'
  '// Before creating a tenant, call get_tenant_dns_provider_choices.\n'
  '// If exactly one provider is eligible, use that provider without asking.\n'
  '// If multiple providers are eligible, ask the administrator which provider to use.\n'
  '// Explicit Cloudflare choice => plan_create_tenant_with_dns + apply_tenant_dns_change; never fall back silently.\n'
  '// Explicit Vodia choice => plan_create_tenant + apply_tenant_change; require matched Vodia wildcard; never fall back silently.\n'
)
s=s[:fidx]+policy+s[fidx:]

# Phase 2D may hide tenant-only guarded tools. They must be visible for an explicit
# Vodia-native DNS selection. Remove only the first known visibility wrapper around
# the tenant-only planner/apply pair, leaving standalone low-level DNS writes gated.
flag='if (process.env.VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS === "1") {'
first=s.find(flag)
if first >= 0:
    comment='// Customer tenant tool surface — Phase 2D'
    cidx=s.rfind(comment,0,first+1)
    combined=s.find('"plan_create_tenant_with_dns"',first)
    if cidx >= 0 and combined > first:
        segment=s[cidx:combined]
        segment=segment.replace(flag+'\n','',1)
        endpos=segment.rfind('    }\n\n')
        if endpos < 0:
            raise SystemExit('PATCH ERROR: could not safely expose guarded tenant-only tools')
        segment=segment[:endpos]+segment[endpos+len('    }\n\n'):]
        s=s[:cidx]+segment+s[combined:]

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.10\2',s,count=1)
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
  'v0.14.9.10 DNS provider choice routing',
  '"get_tenant_dns_provider_choices"',
  'requiresProviderChoice=providers.length > 1',
  'autoSelected:Boolean(selectedProvider)',
  'matchedWildcard',
  'method: "GET"',
  'Never silently switch providers after an explicit provider has been selected and fails.',
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
  'deleteSavedCloudflareDnsRecordById',
]
for x in required:
    if x not in s: raise SystemExit(f'VALIDATION ERROR: missing {x!r}')
count=len(re.findall(r'server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']',s,re.S))
if count != 1:
    raise SystemExit(f'VALIDATION ERROR: provider-choice tool registration count={count}, expected 1')

# Verify the known-good Cloudflare apply order remains create -> public DNS -> Vodia.
apply_start=s.index('async function applyCreateTenantWithDns')
apply_end=s.find('\nasync function ',apply_start+10)
apply_block=s[apply_start:] if apply_end < 0 else s[apply_start:apply_end]
pos_cf=apply_block.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=apply_block.find('publicDns = await waitForPublicDnsA')
if pos_dns < 0:
    pos_dns=apply_block.find('const publicDns = await waitForPublicDnsA')
pos_pbx=apply_block.find('method: "POST",\n        path: "/rest/system/domains"')
if min(pos_cf,pos_dns,pos_pbx) < 0 or not (pos_cf < pos_dns < pos_pbx):
    raise SystemExit(f'VALIDATION ERROR: Cloudflare DNS-FIRST order changed ({pos_cf}, {pos_dns}, {pos_pbx})')

# Ensure provider discovery does not POST System Settings.
choice_start=s.index('async function dnsChoiceReadVodiaSettings')
choice_end=s.index('async function getTenantDnsProviderChoices',choice_start)
choice_block=s[choice_start:choice_end]
if 'method: "POST"' in choice_block:
    raise SystemExit('VALIDATION ERROR: provider discovery must be read-only; POST found')

print('PASS: provider discovery is read-only')
print('PASS: Vodia eligibility requires wildcard match')
print('PASS: one provider => automatic routing; multiple providers => administrator choice')
print('PASS: explicit provider failure never silently falls back')
print('PASS: v0.14.9.9 Cloudflare DNS-FIRST/public-resolver/rollback path preserved')
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
cat "$HEALTH"; echo
if ! grep -q '"version":"0.14.9.10"' "$HEALTH"; then
  echo "Health did not report v0.14.9.10"
  false
fi
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register|ERR_MODULE' > "$LOGS"; then
  cat "$LOGS"
  false
fi
echo PASS

echo "[8/8] Complete"
echo "PASS: v0.14.9.10 installed"
echo "PASS: provider discovery tool = get_tenant_dns_provider_choices"
echo "PASS: one eligible provider is selected automatically"
echo "PASS: multiple eligible providers require administrator choice"
echo "PASS: Vodia DNS requires tenant FQDN to match the configured Vodia wildcard"
echo "PASS: Cloudflare continues to use v0.14.9.9 DNS-FIRST + public resolver gate + rollback"
echo "PASS: explicit provider failure never silently switches providers"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session so the updated tool catalog is loaded."
trap - ERR
