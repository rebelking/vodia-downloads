#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP Phase 2E — explicit DNS provider choice before tenant creation
#
# Behavior:
#   1) Inspect Vodia System Settings first for the managed *.vodia-pbx.com DNS option.
#   2) Inspect DNS providers connected to the MCP (currently Cloudflare integration).
#   3) Present only providers that are actually available.
#   4) NEVER auto-select a DNS provider. The administrator must explicitly choose.
#   5) After selection:
#        - vodia      -> use guarded tenant-only plan/apply; PBX handles its managed DNS.
#        - cloudflare -> use existing guarded combined tenant + Cloudflare DNS workflow.
#
# This installer itself performs no PBX or DNS writes.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/vodia-phase2e.XXXXXX)"
STAGED="$WORK/index.js"
BACKUP="$INDEX.pre-phase2e-dns-provider-choice.$STAMP"
HEALTH="$WORK/health.json"
LOGS="$WORK/runtime-errors.txt"

cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Phase 2E activation failed; restoring pre-Phase2E index.js..."
  [[ -f "$BACKUP" ]] && cp -a "$BACKUP" "$INDEX" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

echo "=== Vodia MCP Phase 2E — explicit tenant DNS provider choice ==="
echo "No DNS provider will be selected automatically."
echo "No tenant or DNS record is created by this installer."

echo "[1/7] Preflight existing tenant + DNS capabilities"
for marker in \
  '"plan_create_tenant"' \
  '"apply_tenant_change"' \
  '"plan_create_tenant_with_dns"' \
  '"apply_tenant_dns_change"' \
  'getCloudflareIntegrationStatus' \
  'vodiaSystemJson'; do
  grep -q "$marker" "$INDEX" || fail "required marker missing: $marker"
done
if grep -q 'Tenant DNS provider choice — Phase 2E' "$INDEX"; then
  echo "Phase 2E already appears installed. Exiting without changes."
  exit 0
fi
echo "PASS"

echo "[2/7] Stage current index.js"
cp -a "$INDEX" "$STAGED"
echo "PASS"

echo "[3/7] Add Vodia DNS inspection + provider-choice tool and routing policy"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import re, sys

p = Path(sys.argv[1])
s = p.read_text()

if 'Tenant DNS provider choice — Phase 2E' in s:
    raise SystemExit('PATCH ERROR: Phase 2E marker already exists')

# Put top-level helper logic before the combined Cloudflare planner.
anchor = 'async function planCreateTenantWithDns('
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: planCreateTenantWithDns anchor not found')

logic = r'''
// -----------------------------------------------------------------------------
// Tenant DNS provider choice — Phase 2E
// Always inspect Vodia first, then connected MCP DNS providers, then require
// an explicit administrator choice. Never auto-select a provider.
// -----------------------------------------------------------------------------

function phase2eFlattenSettings(value, path = "", out = []) {
  if (value === null || value === undefined) return out;
  if (Array.isArray(value)) {
    value.forEach((v, i) => phase2eFlattenSettings(v, `${path}[${i}]`, out));
    return out;
  }
  if (typeof value === "object") {
    Object.entries(value).forEach(([k, v]) => phase2eFlattenSettings(v, path ? `${path}.${k}` : k, out));
    return out;
  }
  out.push({ path, value: String(value) });
  return out;
}

function phase2eDetectVodiaManagedDns(data) {
  const flat = phase2eFlattenSettings(data);
  const dnsRows = flat.filter((row) => /dns|domain|host|address|wildcard/i.test(row.path));
  const wildcardRows = dnsRows.filter((row) => /vodia-pbx\.com/i.test(row.value));
  const explicitOff = wildcardRows.some((row) => /^(0|false|off|none|disabled)$/i.test(row.value.trim()));
  const enabled = wildcardRows.length > 0 && !explicitOff;
  return {
    enabled,
    wildcard: enabled ? "*.vodia-pbx.com" : null,
    evidence: wildcardRows.slice(0, 10),
  };
}

async function phase2eReadVodiaDnsSettings() {
  // Allow operators to override the settings endpoint if a PBX build exposes
  // System Settings at a different REST path. Default is read-only.
  const configured = String(process.env.VODIA_MCP_SYSTEM_SETTINGS_PATH || "").trim();
  const candidates = [...new Set([
    configured,
    "/rest/system/settings",
  ].filter(Boolean))];

  const attempts = [];
  for (const path of candidates) {
    try {
      const response = await vodiaSystemJson({ path });
      const detected = phase2eDetectVodiaManagedDns(response?.data);
      attempts.push({ path, ok: true, detected: detected.enabled });
      return {
        readable: true,
        path,
        detected,
        attempts,
      };
    } catch (error) {
      attempts.push({ path, ok: false, error: String(error?.message || error).slice(0, 300) });
    }
  }

  return {
    readable: false,
    path: null,
    detected: { enabled: false, wildcard: null, evidence: [] },
    attempts,
  };
}

async function phase2eTenantDnsChoices(tenant) {
  const normalizedTenant = normalizeTenantName(tenant);

  // Requirement: inspect Vodia first.
  const vodiaDns = await phase2eReadVodiaDnsSettings();

  // Then inspect DNS integrations connected to this MCP.
  let cloudflare = null;
  try {
    const status = getCloudflareIntegrationStatus();
    cloudflare = {
      connected: Boolean(status?.configured),
      zone: status?.domain ? String(status.domain).toLowerCase() : null,
      eligibleForTenant: Boolean(
        status?.configured && status?.domain &&
        (normalizedTenant === String(status.domain).toLowerCase() || normalizedTenant.endsWith(`.${String(status.domain).toLowerCase()}`))
      ),
    };
  } catch (error) {
    cloudflare = { connected: false, zone: null, eligibleForTenant: false, error: String(error?.message || error).slice(0, 300) };
  }

  const providers = [];
  if (vodiaDns.readable && vodiaDns.detected.enabled) {
    providers.push({
      id: "vodia",
      label: "Vodia managed wildcard DNS",
      available: true,
      detail: "PBX System Settings indicates the Vodia managed *.vodia-pbx.com DNS option is enabled.",
    });
  }
  if (cloudflare.connected && cloudflare.eligibleForTenant) {
    providers.push({
      id: "cloudflare",
      label: "Cloudflare",
      available: true,
      detail: `Connected MCP Cloudflare zone ${cloudflare.zone} controls ${normalizedTenant}.`,
    });
  }

  return {
    tenant: normalizedTenant,
    changesMade: false,
    requiresProviderChoice: true,
    autoSelected: false,
    vodiaCheckedFirst: true,
    vodiaDns,
    cloudflare,
    providers,
    providerIds: providers.map((p) => p.id),
    question: providers.length
      ? "Which DNS provider do you want to use for this tenant?"
      : "No eligible DNS provider was detected. Check Vodia System Settings and connected MCP DNS integrations.",
  };
}

'''
s = s[:idx] + logic + s[idx:]

# Register discovery tool immediately before the combined customer planner tool.
reg_anchor = 'server.registerTool(\n      "plan_create_tenant_with_dns",'
reg_idx = s.find(reg_anchor)
if reg_idx < 0:
    # tolerate 2-space indentation builds
    reg_anchor = 'server.registerTool(\n  "plan_create_tenant_with_dns",'
    reg_idx = s.find(reg_anchor)
if reg_idx < 0:
    raise SystemExit('PATCH ERROR: combined planner registration anchor not found')

registration = r'''
    server.registerTool(
      "get_tenant_dns_provider_choices",
      {
        title: "Get tenant DNS provider choices",
        description: "REQUIRED first step before planning a new Vodia tenant. Reads Vodia System Settings first to see whether managed *.vodia-pbx.com DNS is enabled, then checks DNS providers connected to this MCP such as Cloudflare. It never selects a provider automatically and makes no changes.",
        inputSchema: { tenant: z.string().min(3) },
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
      },
      async ({ tenant }) => {
        scopedAudit("get_tenant_dns_provider_choices", { tenant });
        try {
          const result = await phase2eTenantDnsChoices(tenant);
          return scopedSuccess(
            result,
            { operation: "GET_TENANT_DNS_PROVIDER_CHOICES", readOnly: true, changesMade: false },
            result.providers.length
              ? `Choose a DNS provider for ${result.tenant}; no provider was selected automatically.`
              : `No eligible DNS provider was detected for ${result.tenant}.`
          );
        } catch (error) {
          return failure(error, "Tenant DNS provider discovery");
        }
      }
    );

'''
s = s[:reg_idx] + registration + s[reg_idx:]

# Strengthen system/admin routing text. Do not remove existing Phase 2C/2D policy;
# prepend an explicit Phase 2E requirement near createVodiaServer.
factory = 'export function createVodiaServer('
fidx = s.find(factory)
if fidx < 0:
    raise SystemExit('PATCH ERROR: createVodiaServer anchor not found')
policy = (
    '// Tenant DNS provider choice — Phase 2E\n'
    '// Customer tenant creation MUST call get_tenant_dns_provider_choices first.\n'
    '// NEVER auto-select Vodia, Cloudflare, or another DNS provider. Ask the administrator to choose from the returned available providers.\n'
    '// If Vodia is chosen, use the guarded tenant-only plan/apply workflow; the PBX managed DNS setting owns DNS.\n'
    '// If Cloudflare is chosen, use plan_create_tenant_with_dns then apply_tenant_dns_change.\n'
)
s = s[:fidx] + policy + s[fidx:]

# Phase 2D hides low-level tenant-only tools. For explicit Vodia-provider selection,
# make that tenant-only guarded pair visible while keeping low-level Cloudflare
# standalone writes gated. We only alter the first Phase 2D gate.
flag = 'if (process.env.VODIA_MCP_EXPOSE_LOW_LEVEL_TENANT_DNS === "1") {'
first = s.find(flag)
if first >= 0:
    # Identify the matching block conservatively from the known Phase 2D comments.
    comment = '// Customer tenant tool surface — Phase 2D'
    cidx = s.rfind(comment, 0, first + 1)
    combined = s.find('"plan_create_tenant_with_dns"', first)
    if cidx >= 0 and combined > first:
      # Remove only the opening gate and its final closing brace immediately before combined tool.
      segment = s[cidx:combined]
      segment = segment.replace(flag + '\n', '', 1)
      # Phase 2D emits "    }\n\n" at the end of wrapped block.
      endpos = segment.rfind('    }\n\n')
      if endpos >= 0:
        segment = segment[:endpos] + segment[endpos + len('    }\n\n'):]
      else:
        raise SystemExit('PATCH ERROR: could not safely remove Phase 2D tenant-only visibility gate')
      s = s[:cidx] + segment + s[combined:]

# Make tenant-only tools self-describing so they are not selected before provider choice.
s = s.replace(
    'description: "Low-level tenant-only planner.',
    'description: "Vodia-managed-DNS tenant planner. Use ONLY after get_tenant_dns_provider_choices has been called and the administrator explicitly selected provider vodia. ',
    1
)

p.write_text(s)
PY
node --check "$STAGED"
echo "PASS"

echo "[4/7] Validate staged behavior"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import re, sys
s=Path(sys.argv[1]).read_text()
required=[
  'Tenant DNS provider choice — Phase 2E',
  '"get_tenant_dns_provider_choices"',
  'requiresProviderChoice: true',
  'autoSelected: false',
  'vodiaCheckedFirst: true',
  'Which DNS provider do you want to use for this tenant?',
  'NEVER auto-select Vodia, Cloudflare, or another DNS provider',
  'VODIA_MCP_SYSTEM_SETTINGS_PATH',
]
for x in required:
  if x not in s:
    raise SystemExit(f'VALIDATION ERROR: missing {x}')
count=len(re.findall(r'server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']', s, re.S))
if count != 1:
  raise SystemExit(f'VALIDATION ERROR: choice tool registration count={count}, expected 1')
print('PASS: explicit provider-choice workflow present; automatic selection disabled')
PY
echo "PASS"

echo "[5/7] Backup and activate"
cp -a "$INDEX" "$BACKUP"
cp -a "$STAGED" "$INDEX"
trap rollback ERR
node --check "$INDEX"
echo "backup: $BACKUP"
echo "PASS"

echo "[6/7] Restart and verify runtime"
systemctl restart "$SERVICE"
: > "$HEALTH"
for _ in {1..25}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager || true; false; }
cat "$HEALTH"; echo
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'already registered|SyntaxError|ReferenceError|TypeError:.*register|ERR_MODULE' > "$LOGS"; then
  cat "$LOGS"
  false
fi
echo "PASS"

echo "[7/7] Phase 2E installed"
echo "New required first-step tool: get_tenant_dns_provider_choices"
echo "Behavior: Vodia System Settings first -> connected MCP DNS providers -> explicit admin choice"
echo "No automatic provider selection."
echo "Cloudflare selection -> existing combined plan/apply workflow."
echo "Vodia selection -> guarded tenant-only plan/apply workflow; PBX managed DNS owns DNS."
echo "If this PBX exposes System Settings on another REST path, set VODIA_MCP_SYSTEM_SETTINGS_PATH in the service environment and restart."
echo "Backup retained: $BACKUP"
echo "Reconnect/start a fresh MCP client session so the updated tool catalog/instructions are loaded."
trap - ERR
