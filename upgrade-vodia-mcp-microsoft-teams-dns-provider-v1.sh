#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP — Microsoft Teams DNS Provider Selector v1
#
# Adds a read-only/planning tool for Teams Direct Routing DNS preparation.
# It deliberately asks which DNS path should be used when the caller has not
# supplied one:
#   - vodia      Vodia-managed DNS / wildcard path
#   - cloudflare Existing saved Cloudflare integration
#   - manual     Customer/external DNS provider
#
# The tool checks Microsoft verified custom domains and refuses to describe an
# SBC hostname as Teams-ready when it is only under *.onmicrosoft.com.
# No Microsoft, DNS, or PBX write is performed by this installer or tool.

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d /tmp/vodia-teams-dns-provider.XXXXXX)"
STAGED="$WORK/index.js"
BACKUP="$INDEX.pre-teams-dns-provider-v1.$STAMP"
HEALTH="$WORK/health.json"
LOGS="$WORK/runtime-errors.txt"

cleanup(){ rm -rf "$WORK"; }
trap cleanup EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-install index.js..."
  [[ -f "$BACKUP" ]] && cp -a "$BACKUP" "$INDEX" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "Run as root"
[[ -f "$INDEX" ]] || fail "missing $INDEX"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

echo "=== Vodia MCP — Microsoft Teams DNS Provider Selector v1 ==="
echo "Adds read-only provider choice + Direct Routing DNS planning."
echo "No Microsoft, DNS, or PBX write is performed."

echo "[1/7] Preflight"
grep -q 'async function microsoftGraphGet' "$INDEX" || fail "Microsoft Graph Phase 1 helper is not installed"
grep -q '"microsoft_check_graph_readiness"' "$INDEX" || fail "Microsoft Graph Phase 1 tools are not installed"
grep -q 'toolOutputSchema' "$INDEX" || fail "toolOutputSchema not found"
grep -q 'scopedSuccess' "$INDEX" || fail "scopedSuccess helper not found"
if grep -q '"microsoft_plan_teams_dns"' "$INDEX"; then
  echo "Teams DNS provider selector already appears installed. Exiting without changes."
  exit 0
fi
cp -a "$INDEX" "$STAGED"
echo "PASS"

echo "[2/7] Patch staged index.js"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if '"microsoft_plan_teams_dns"' in s:
    raise SystemExit('PATCH ERROR: tool already present unexpectedly')

# Insert immediately before the existing Microsoft Graph readiness tool. This is
# a known top-level Microsoft registration anchor after the Phase 1 placement fix.
anchor = 'server.registerTool(\n  "microsoft_check_graph_readiness",'
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: microsoft_check_graph_readiness registration anchor not found')

block = r'''
// -----------------------------------------------------------------------------
// Microsoft Teams Direct Routing DNS provider selector v1 — read-only planning
// -----------------------------------------------------------------------------
function teamsDnsNormalizeHost(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/\/$/, "")
    .split("/")[0]
    .replace(/:\d+$/, "")
    .replace(/\.$/, "");
}

function teamsDnsVerifiedCustomDomains(domains) {
  return (Array.isArray(domains) ? domains : []).filter((d) => {
    const id = teamsDnsNormalizeHost(d?.id);
    return d?.isVerified === true && id && !id.endsWith(".onmicrosoft.com") && !id.endsWith(".mail.onmicrosoft.com");
  });
}

function teamsDnsDomainMatch(host, domains) {
  const normalizedHost = teamsDnsNormalizeHost(host);
  const verified = teamsDnsVerifiedCustomDomains(domains);
  const match = verified.find((d) => {
    const domain = teamsDnsNormalizeHost(d?.id);
    return normalizedHost === domain || normalizedHost.endsWith(`.${domain}`);
  });
  return {
    host: normalizedHost || null,
    valid: Boolean(match),
    matchedDomain: match?.id || null,
    verifiedCustomDomains: verified.map((d) => d.id),
  };
}

function teamsDnsCloudflareStatus() {
  // Cloudflare is optional. Reuse the existing integration only when its helper
  // exists in this build; otherwise report it as unavailable instead of failing.
  try {
    if (typeof getCloudflareIntegrationStatus === "function") {
      const status = getCloudflareIntegrationStatus();
      return {
        available: Boolean(status?.configured),
        configured: Boolean(status?.configured),
        zone: teamsDnsNormalizeHost(status?.domain) || null,
      };
    }
  } catch {}
  return { available: false, configured: false, zone: null };
}

function teamsDnsProviderOptions({ sbcFqdn, domainMatch, cloudflare }) {
  const host = teamsDnsNormalizeHost(sbcFqdn);
  const cfZone = teamsDnsNormalizeHost(cloudflare?.zone);
  const cloudflareMatches = Boolean(
    cloudflare?.configured && cfZone && (host === cfZone || host.endsWith(`.${cfZone}`))
  );
  return [
    {
      id: "vodia",
      label: "Vodia managed DNS",
      available: true,
      teamsCompatibleForThisFqdn: Boolean(domainMatch?.valid),
      note: domainMatch?.valid
        ? "The SBC hostname is under a verified Microsoft custom domain; use the Vodia-managed path only if Vodia is authoritative for that DNS name."
        : "The SBC hostname is not under a verified Microsoft custom domain. Vodia wildcard DNS alone does not satisfy the Microsoft domain prerequisite.",
    },
    {
      id: "cloudflare",
      label: "Cloudflare",
      available: Boolean(cloudflare?.configured),
      teamsCompatibleForThisFqdn: Boolean(domainMatch?.valid && cloudflareMatches),
      zone: cloudflare?.zone || null,
      note: cloudflare?.configured
        ? (cloudflareMatches ? "Saved Cloudflare zone matches the SBC hostname." : "Saved Cloudflare zone does not control this SBC hostname.")
        : "No saved Cloudflare integration is available to this MCP instance.",
    },
    {
      id: "manual",
      label: "External / manual DNS",
      available: true,
      teamsCompatibleForThisFqdn: Boolean(domainMatch?.valid),
      note: "Use when the customer's DNS is managed outside Vodia and Cloudflare. The MCP will plan and verify, but will not change that external provider.",
    },
  ];
}

server.registerTool(
  "microsoft_plan_teams_dns",
  {
    title: "Plan Teams Direct Routing DNS",
    description: "Read-only planner for the DNS portion of a Vodia + Microsoft Teams Direct Routing deployment. If dnsProvider is omitted, it returns Vodia, Cloudflare, and manual choices and requires the administrator to choose. It validates that the SBC FQDN belongs to a verified Microsoft 365 custom domain. It performs zero writes.",
    inputSchema: {
      sbcFqdn: z.string().min(3),
      dnsProvider: z.enum(["vodia", "cloudflare", "manual"]).optional(),
      ipv4: z.string().min(7).optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ sbcFqdn, dnsProvider, ipv4 }) => {
    scopedAudit("microsoft_plan_teams_dns", { sbcFqdn, dnsProvider: dnsProvider || null, ipv4Provided: Boolean(ipv4) });
    try {
      const host = teamsDnsNormalizeHost(sbcFqdn);
      if (!host || !host.includes(".")) throw new Error("A fully-qualified SBC hostname is required.");

      const domainsData = await microsoftGraphGet("/domains?$select=id,isDefault,isInitial,isVerified,authenticationType");
      const domains = Array.isArray(domainsData.value) ? domainsData.value : [];
      const domainMatch = teamsDnsDomainMatch(host, domains);
      const cloudflare = teamsDnsCloudflareStatus();
      const providerOptions = teamsDnsProviderOptions({ sbcFqdn: host, domainMatch, cloudflare });

      if (!dnsProvider) {
        return scopedSuccess(
          {
            changesMade: false,
            requiresProviderChoice: true,
            question: "Which DNS provider should be used for this Teams SBC hostname?",
            sbcFqdn: host,
            domainMatch,
            providerOptions,
            nextInput: { dnsProvider: "vodia | cloudflare | manual" },
          },
          { operation: "MICROSOFT_PLAN_TEAMS_DNS", readOnly: true, changesMade: false },
          "Choose Vodia, Cloudflare, or manual DNS before continuing the Teams DNS plan."
        );
      }

      const selected = providerOptions.find((x) => x.id === dnsProvider);
      const blockers = [];
      const warnings = [];

      if (!domainMatch.valid) {
        blockers.push(`SBC FQDN ${host} is not under a verified custom domain in this Microsoft 365 tenant.`);
      }
      if (dnsProvider === "cloudflare") {
        if (!cloudflare.configured) blockers.push("Cloudflare was selected but no saved Cloudflare integration is configured.");
        else if (!selected?.teamsCompatibleForThisFqdn) blockers.push(`The saved Cloudflare zone ${cloudflare.zone || "(unknown)"} does not control ${host}.`);
      }
      if (dnsProvider === "vodia" && host.endsWith(".vodia-pbx.com") && !domainMatch.valid) {
        warnings.push("The Vodia wildcard hostname is convenient for PBX DNS, but this hostname is not currently under a verified Microsoft custom domain for this tenant.");
      }
      if (!ipv4) {
        warnings.push("No PBX public IPv4 was supplied to this planner. Resolve/discover the target address before applying an A record.");
      }

      const plan = {
        changesMade: false,
        requiresProviderChoice: false,
        status: blockers.length ? "BLOCKED" : "READY_FOR_DNS_PRECHECK",
        sbcFqdn: host,
        dnsProvider,
        ipv4: ipv4 || null,
        domainMatch,
        provider: selected || null,
        providerOptions,
        blockers,
        warnings,
        proposedSequence: dnsProvider === "cloudflare"
          ? [
              "verify Microsoft custom domain",
              "verify saved Cloudflare zone controls SBC hostname",
              "plan DNS-only A record",
              "request explicit approval before DNS write",
              "create/verify A record using existing Cloudflare guarded workflow",
              "verify public DNS resolution",
              "verify TLS certificate",
              "continue to Teams Direct Routing control-plane planning",
            ]
          : dnsProvider === "vodia"
            ? [
                "verify Microsoft custom domain",
                "verify Vodia is authoritative for the chosen hostname",
                "plan Vodia-managed DNS mapping",
                "request explicit approval before any DNS change",
                "verify public DNS resolution",
                "verify TLS certificate",
                "continue to Teams Direct Routing control-plane planning",
              ]
            : [
                "verify Microsoft custom domain",
                "provide required A-record hostname and target IPv4",
                "administrator/customer creates the record at external DNS provider",
                "verify public DNS resolution",
                "verify TLS certificate",
                "continue to Teams Direct Routing control-plane planning",
              ],
        boundary: "This tool plans only. It does not create DNS, change Microsoft 365, or change the Vodia PBX. Existing guarded Cloudflare write tools remain the apply path when Cloudflare is selected.",
      };

      return scopedSuccess(
        plan,
        { operation: "MICROSOFT_PLAN_TEAMS_DNS", readOnly: true, changesMade: false },
        blockers.length
          ? "Teams DNS plan is blocked; review the domain/provider checks."
          : `Teams DNS plan is ready for ${dnsProvider} preflight.`
      );
    } catch (error) {
      return failure(error, "Microsoft Teams DNS planning");
    }
  }
);

'''

s = s[:idx] + block + s[idx:]
p.write_text(s)
print('PASS: microsoft_plan_teams_dns inserted')
PY
node --check "$STAGED"
echo "PASS"

echo "[3/7] Validate staged tool registration"
python3 - "$STAGED" <<'PY'
from pathlib import Path
import re, sys
s = Path(sys.argv[1]).read_text()
name = 'microsoft_plan_teams_dns'
count = len(re.findall(r'server\.registerTool\(\s*["\']' + name + r'["\']', s, re.S))
print(f'{name} registration count: {count}')
if count != 1:
    raise SystemExit(f'VALIDATION ERROR: {name} registration count={count}, expected 1')
for marker in [
    'requiresProviderChoice',
    'dnsProvider: z.enum(["vodia", "cloudflare", "manual"]).optional()',
    'verified custom domain',
    'changesMade: false',
]:
    if marker not in s:
        raise SystemExit(f'VALIDATION ERROR: missing marker: {marker}')
print('PASS')
PY

echo "[4/7] Back up live index.js"
cp -a "$INDEX" "$BACKUP"
echo "backup: $BACKUP"
echo "PASS"

echo "[5/7] Activate staged code"
cp -a "$STAGED" "$INDEX"
trap rollback ERR
node --check "$INDEX"
echo "PASS"

echo "[6/7] Restart and runtime check"
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

echo "[7/7] Installed"
echo "New tool: microsoft_plan_teams_dns"
echo "Behavior when provider omitted: asks for one of vodia | cloudflare | manual"
echo "Writes performed by tool: 0"
echo "Backup retained: $BACKUP"
echo
echo "Example MCP test:"
echo '  Use microsoft_plan_teams_dns with sbcFqdn teams.audiomercy.com and do not choose a DNS provider yet.'
echo "Expected: requiresProviderChoice=true and three provider options."
trap - ERR
