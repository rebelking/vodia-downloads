#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-microsoft-phase2.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Microsoft Phase 2 — Teams Readiness + Deployment Planning ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q '"microsoft_check_graph_readiness"' "$INDEX" || fail "Microsoft Phase 1 is not installed"
grep -q 'async function microsoftGraphGet' "$INDEX" || fail "Microsoft Graph helper not found"
grep -q 'server.registerTool' "$INDEX" || fail "MCP tool registration anchor not found"
grep -q 'toolOutputSchema' "$INDEX" || fail "toolOutputSchema not found"
grep -q 'scopedSuccess' "$INDEX" || fail "scopedSuccess helper not found"
echo "PASS"

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

echo "[3/7] Add Microsoft Phase 2 tools"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

marker = '"microsoft_check_teams_readiness"'
if marker in s:
    print("Microsoft Phase 2 tools already present; leaving existing implementation unchanged.")
    raise SystemExit(0)

anchor = 'server.registerTool(\n  "microsoft_check_graph_readiness",'
if anchor not in s:
    raise SystemExit("PATCH ERROR: microsoft_check_graph_readiness anchor not found")

block = r'''
// -----------------------------------------------------------------------------
// Microsoft 365 / Teams — Phase 2 (read-only)
// Uses the already-validated Graph app-only connection from Phase 1.
// This phase DOES NOT configure Teams Direct Routing and DOES NOT write to
// Microsoft 365 or Vodia. It verifies prerequisites and produces deployment
// plans only. Teams PSTN gateway/voice-route control is intentionally deferred
// until the Teams control-plane authentication model is verified separately.
// -----------------------------------------------------------------------------

function microsoftNormalizeHost(value) {
  return String(value || "")
    .trim()
    .toLowerCase()
    .replace(/^https?:\/\//, "")
    .replace(/\/$/, "")
    .split("/")[0]
    .replace(/:\d+$/, "")
    .replace(/\.$/, "");
}

function microsoftSkuIndex(licenses) {
  const map = new Map();
  for (const sku of Array.isArray(licenses) ? licenses : []) {
    const key = String(sku?.skuId || "").toLowerCase();
    if (key) map.set(key, sku);
  }
  return map;
}

function microsoftAssignedSkuDetails(user, licenses) {
  const idx = microsoftSkuIndex(licenses);
  return (Array.isArray(user?.assignedLicenses) ? user.assignedLicenses : []).map((x) => {
    const skuId = String(x?.skuId || "");
    const sku = idx.get(skuId.toLowerCase());
    return {
      skuId,
      skuPartNumber: sku?.skuPartNumber || null,
      capabilityStatus: sku?.capabilityStatus || null,
    };
  });
}

function microsoftLicenseSignals(assignedSkuDetails) {
  const parts = assignedSkuDetails
    .map((x) => String(x?.skuPartNumber || "").toUpperCase())
    .filter(Boolean);

  // Microsoft SKU part numbers vary across plans and regions. These are signals,
  // not authoritative licensing decisions. Unknown remains UNKNOWN rather than FAIL.
  const teamsSignal = parts.some((p) =>
    p.includes("TEAMS") ||
    p.includes("SPE_") ||
    p.includes("O365") ||
    p.includes("M365") ||
    p.includes("ENTERPRISEPACK") ||
    p.includes("STANDARDPACK")
  );

  const phoneSignal = parts.some((p) =>
    p.includes("MCOEV") ||
    p.includes("PHONESYSTEM") ||
    p.includes("PHONE_SYSTEM")
  );

  return {
    teamsLicenseSignal: teamsSignal ? "PRESENT" : "UNKNOWN",
    teamsPhoneLicenseSignal: phoneSignal ? "PRESENT" : "UNKNOWN",
    note: "License signals are based on tenant SKU part numbers. Microsoft licensing bundles change; UNKNOWN is not a failure.",
  };
}

function microsoftVerifiedCustomDomains(domains) {
  return (Array.isArray(domains) ? domains : []).filter((d) => {
    const id = String(d?.id || "").toLowerCase();
    return d?.isVerified === true && id && !id.endsWith(".onmicrosoft.com") && !id.endsWith(".mail.onmicrosoft.com");
  });
}

function microsoftSbcDomainMatch(sbcFqdn, domains) {
  const host = microsoftNormalizeHost(sbcFqdn);
  if (!host) return { provided: false, host: null, matchedDomain: null, valid: null };
  const verified = microsoftVerifiedCustomDomains(domains);
  const match = verified.find((d) => {
    const domain = String(d?.id || "").toLowerCase();
    return host === domain || host.endsWith(`.${domain}`);
  });
  return {
    provided: true,
    host,
    matchedDomain: match?.id || null,
    valid: Boolean(match),
  };
}

async function microsoftGetUserByUpn(userPrincipalName) {
  const upn = String(userPrincipalName || "").trim();
  if (!upn) throw new Error("userPrincipalName is required");
  const encoded = encodeURIComponent(upn);
  return microsoftGraphGet(`/users/${encoded}?$select=id,displayName,userPrincipalName,mail,accountEnabled,usageLocation,assignedLicenses`);
}

async function microsoftReadTeamsPrerequisites(userPrincipalName = null, sbcFqdn = null) {
  const [orgData, domainsData, skuData] = await Promise.all([
    microsoftGraphGet("/organization?$select=id,displayName"),
    microsoftGraphGet("/domains?$select=id,isDefault,isInitial,isVerified,authenticationType"),
    microsoftGraphGet("/subscribedSkus?$select=id,skuId,skuPartNumber,consumedUnits,prepaidUnits,capabilityStatus"),
  ]);

  const organization = Array.isArray(orgData.value) ? orgData.value[0] : null;
  const domains = Array.isArray(domainsData.value) ? domainsData.value : [];
  const licenses = Array.isArray(skuData.value) ? skuData.value : [];
  const verifiedCustomDomains = microsoftVerifiedCustomDomains(domains);
  const sbc = microsoftSbcDomainMatch(sbcFqdn, domains);

  let user = null;
  let assignedSkuDetails = [];
  let licenseSignals = null;
  if (userPrincipalName) {
    user = await microsoftGetUserByUpn(userPrincipalName);
    assignedSkuDetails = microsoftAssignedSkuDetails(user, licenses);
    licenseSignals = microsoftLicenseSignals(assignedSkuDetails);
  }

  return {
    organization,
    domains,
    verifiedCustomDomains,
    subscribedSkus: licenses,
    sbc,
    user,
    assignedSkuDetails,
    licenseSignals,
  };
}

server.registerTool(
  "microsoft_get_user",
  {
    title: "Get Microsoft 365 user",
    description: "Read-only lookup of one Microsoft 365 user by UPN, including account state, usage location, and assigned license IDs mapped to tenant SKU part numbers. Makes no changes.",
    inputSchema: { userPrincipalName: z.string().min(3) },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ userPrincipalName }) => {
    scopedAudit("microsoft_get_user", { userPrincipalName });
    try {
      const [user, skuData] = await Promise.all([
        microsoftGetUserByUpn(userPrincipalName),
        microsoftGraphGet("/subscribedSkus?$select=skuId,skuPartNumber,capabilityStatus"),
      ]);
      const licenses = Array.isArray(skuData.value) ? skuData.value : [];
      const assignedSkuDetails = microsoftAssignedSkuDetails(user, licenses);
      const licenseSignals = microsoftLicenseSignals(assignedSkuDetails);
      return scopedSuccess(
        { changesMade: false, user, assignedSkuDetails, licenseSignals },
        { operation: "MICROSOFT_GET_USER", readOnly: true, changesMade: false },
        `Microsoft 365 user ${user.userPrincipalName || userPrincipalName} read successfully.`
      );
    } catch (error) {
      return failure(error, "Microsoft 365 user read");
    }
  }
);

server.registerTool(
  "microsoft_check_teams_readiness",
  {
    title: "Check Microsoft Teams readiness",
    description: "Read-only prerequisite assessment for a future Vodia + Microsoft Teams Direct Routing deployment. Checks tenant identity, verified custom domains, subscribed SKUs, optional user licensing signals, and whether an optional SBC FQDN belongs to a verified custom domain. Does not inspect or change Teams PSTN gateways or voice routes.",
    inputSchema: {
      userPrincipalName: z.string().min(3).optional(),
      sbcFqdn: z.string().min(3).optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ userPrincipalName, sbcFqdn }) => {
    scopedAudit("microsoft_check_teams_readiness", { userPrincipalName, sbcFqdn });
    try {
      const data = await microsoftReadTeamsPrerequisites(userPrincipalName, sbcFqdn);
      const checks = [
        {
          check: "graph_connection",
          status: data.organization ? "PASS" : "FAIL",
          detail: data.organization?.displayName || null,
        },
        {
          check: "verified_custom_domain",
          status: data.verifiedCustomDomains.length ? "PASS" : "FAIL",
          detail: data.verifiedCustomDomains.map((d) => d.id),
        },
      ];

      if (userPrincipalName) {
        checks.push({
          check: "user_exists",
          status: data.user?.id ? "PASS" : "FAIL",
          detail: data.user?.userPrincipalName || userPrincipalName,
        });
        checks.push({
          check: "user_account_enabled",
          status: data.user?.accountEnabled === true ? "PASS" : "FAIL",
          detail: data.user?.accountEnabled ?? null,
        });
        checks.push({
          check: "teams_license_signal",
          status: data.licenseSignals?.teamsLicenseSignal === "PRESENT" ? "PASS" : "UNKNOWN",
          detail: data.assignedSkuDetails.map((x) => x.skuPartNumber).filter(Boolean),
        });
        checks.push({
          check: "teams_phone_license_signal",
          status: data.licenseSignals?.teamsPhoneLicenseSignal === "PRESENT" ? "PASS" : "UNKNOWN",
          detail: data.assignedSkuDetails.map((x) => x.skuPartNumber).filter(Boolean),
        });
      }

      if (sbcFqdn) {
        checks.push({
          check: "sbc_fqdn_verified_domain_match",
          status: data.sbc.valid ? "PASS" : "FAIL",
          detail: data.sbc,
        });
      }

      const blocked = checks.some((c) => c.status === "FAIL");
      return scopedSuccess(
        {
          readyForPlanning: !blocked,
          directRoutingConfigured: "NOT_CHECKED",
          changesMade: false,
          organization: data.organization,
          verifiedCustomDomains: data.verifiedCustomDomains,
          user: data.user,
          assignedSkuDetails: data.assignedSkuDetails,
          licenseSignals: data.licenseSignals,
          sbc: data.sbc,
          checks,
          boundary: "This tool checks Graph-visible prerequisites only. Teams PSTN gateways, voice routes, PSTN usages, and voice-routing policies require the Teams control plane and are not claimed here.",
        },
        { operation: "MICROSOFT_CHECK_TEAMS_READINESS", readOnly: true, changesMade: false },
        blocked ? "Microsoft Teams prerequisites have one or more blocking checks." : "Microsoft Teams Graph-visible prerequisites are ready for planning."
      );
    } catch (error) {
      return failure(error, "Microsoft Teams readiness check");
    }
  }
);

server.registerTool(
  "microsoft_plan_vodia_teams_user",
  {
    title: "Plan Vodia + Teams user deployment",
    description: "Read-only deployment planner for one future Microsoft Teams + Vodia user. Verifies the Microsoft user, licensing signals, verified-domain/SBC relationship, and returns the ordered Microsoft/Vodia actions that would be required. It performs zero writes.",
    inputSchema: {
      userPrincipalName: z.string().min(3),
      vodiaTenant: z.string().min(3),
      extension: z.string().min(1),
      did: z.string().min(3).optional(),
      sbcFqdn: z.string().min(3),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ userPrincipalName, vodiaTenant, extension, did, sbcFqdn }) => {
    scopedAudit("microsoft_plan_vodia_teams_user", {
      userPrincipalName, vodiaTenant, extension, did, sbcFqdn
    });
    try {
      const data = await microsoftReadTeamsPrerequisites(userPrincipalName, sbcFqdn);
      const blockers = [];
      const warnings = [];

      if (!data.organization) blockers.push("Microsoft organization could not be read.");
      if (!data.verifiedCustomDomains.length) blockers.push("No verified custom Microsoft 365 domain was found.");
      if (!data.user?.id) blockers.push(`Microsoft user ${userPrincipalName} was not found.`);
      if (data.user && data.user.accountEnabled !== true) blockers.push(`Microsoft user ${userPrincipalName} is disabled.`);
      if (!data.sbc.valid) blockers.push(`SBC FQDN ${sbcFqdn} is not under a verified custom Microsoft 365 domain.`);
      if (data.licenseSignals?.teamsLicenseSignal !== "PRESENT") warnings.push("A Teams-capable base-license SKU was not positively identified from the assigned SKU part numbers; verify the user's Microsoft licensing manually.");
      if (data.licenseSignals?.teamsPhoneLicenseSignal !== "PRESENT") warnings.push("A Teams Phone / Phone System SKU was not positively identified from the assigned SKU part numbers; verify Teams Phone entitlement manually.");

      const plan = {
        changesMade: false,
        status: blockers.length ? "BLOCKED" : "READY_FOR_CONTROL_PLANE_DISCOVERY",
        target: {
          microsoftTenant: data.organization?.displayName || data.organization?.id || null,
          userPrincipalName,
          vodiaTenant,
          extension,
          did: did || null,
          sbcFqdn: microsoftNormalizeHost(sbcFqdn),
        },
        microsoft: {
          user: data.user,
          assignedSkuDetails: data.assignedSkuDetails,
          licenseSignals: data.licenseSignals,
          verifiedCustomDomains: data.verifiedCustomDomains.map((d) => d.id),
          sbcDomainMatch: data.sbc,
        },
        blockers,
        warnings,
        proposedSequence: [
          { step: 1, system: "Microsoft", action: "Inspect Teams PSTN gateway state", write: false, futureTool: "teams_list_pstn_gateways" },
          { step: 2, system: "Microsoft", action: "Inspect voice routes, PSTN usages, and voice-routing policies", write: false, futureTool: "teams_check_direct_routing" },
          { step: 3, system: "Vodia", action: "Inspect or plan Microsoft Teams predefined SIP trunk", write: false, existingTool: "get_predefined_trunk_requirements / plan_create_predefined_trunk" },
          { step: 4, system: "Vodia", action: `Inspect extension ${extension} in tenant ${vodiaTenant}`, write: false },
          { step: 5, system: "Microsoft", action: "Plan Teams user/phone/voice-policy assignment", write: false },
          { step: 6, system: "Vodia", action: "Plan any required extension/DID/trunk association", write: false },
          { step: 7, system: "Both", action: "Require explicit administrator approval before any write", write: false },
          { step: 8, system: "Both", action: "Apply approved changes and verify end-to-end calling", write: true, approvalRequired: true },
        ],
        nextRecommendedTools: [
          "microsoft_get_user",
          "microsoft_check_teams_readiness",
          "get_predefined_trunk_requirements",
          "plan_create_predefined_trunk"
        ],
        controlPlaneGap: "Teams Direct Routing gateway/route/policy inspection is the next implementation phase. This planner does not claim those objects are configured.",
      };

      return scopedSuccess(
        plan,
        { operation: "MICROSOFT_PLAN_VODIA_TEAMS_USER", readOnly: true, changesMade: false },
        blockers.length
          ? `Deployment plan is blocked by ${blockers.length} prerequisite(s). No changes were made.`
          : "Vodia + Microsoft Teams user deployment plan is ready for Teams control-plane discovery. No changes were made."
      );
    } catch (error) {
      return failure(error, "Vodia + Microsoft Teams user deployment plan");
    }
  }
);

server.registerTool(
  "microsoft_get_teams_gap_report",
  {
    title: "Get Teams integration gap report",
    description: "Read-only implementation gap report showing what the Vodia MCP can already do with Microsoft Graph and what still requires Teams control-plane integration. Makes no changes.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  async () => {
    scopedAudit("microsoft_get_teams_gap_report", {});
    const capabilities = [
      { capability: "App-only Microsoft authentication", status: "IMPLEMENTED", tool: "microsoft_check_graph_readiness" },
      { capability: "Organization/domain discovery", status: "IMPLEMENTED", tool: "microsoft_get_tenant / microsoft_list_domains" },
      { capability: "User discovery", status: "IMPLEMENTED", tool: "microsoft_list_users / microsoft_get_user" },
      { capability: "License/SKU discovery", status: "IMPLEMENTED", tool: "microsoft_list_licenses" },
      { capability: "Teams prerequisite assessment", status: "IMPLEMENTED", tool: "microsoft_check_teams_readiness" },
      { capability: "Vodia + Teams user deployment planning", status: "IMPLEMENTED", tool: "microsoft_plan_vodia_teams_user" },
      { capability: "Vodia Microsoft Teams predefined SIP trunk planning", status: "IMPLEMENTED", tool: "get_predefined_trunk_requirements / plan_create_predefined_trunk" },
      { capability: "Teams PSTN gateway inspection", status: "NEXT", futureTool: "teams_list_pstn_gateways" },
      { capability: "Teams voice-route inspection", status: "NEXT", futureTool: "teams_get_voice_routes" },
      { capability: "Teams voice-routing policy inspection", status: "NEXT", futureTool: "teams_get_voice_policies" },
      { capability: "Teams phone-number assignment inspection", status: "NEXT", futureTool: "teams_get_phone_numbers" },
      { capability: "Microsoft user/license/phone writes", status: "DEFERRED_APPROVAL_GATED" },
      { capability: "Direct Routing gateway/route/policy writes", status: "DEFERRED_APPROVAL_GATED" },
    ];
    return scopedSuccess(
      { changesMade: false, capabilities },
      { operation: "MICROSOFT_GET_TEAMS_GAP_REPORT", readOnly: true, changesMade: false },
      "Microsoft/Vodia Teams integration gap report generated. No changes were made."
    );
  }
);

'''

s = s.replace(anchor, block + anchor, 1)
p.write_text(s)
print("PASS: Microsoft Phase 2 tools inserted")
PY

echo "[4/7] Validate JavaScript"
if ! node --check "$INDEX"; then
  cp -a "$BACKUP" "$INDEX"
  fail "JavaScript validation failed; restored $BACKUP"
fi
echo "PASS"

echo "[5/7] Safety contract checks"
for tool in \
  microsoft_get_user \
  microsoft_check_teams_readiness \
  microsoft_plan_vodia_teams_user \
  microsoft_get_teams_gap_report; do
  grep -q "\"$tool\"" "$INDEX" || { cp -a "$BACKUP" "$INDEX"; fail "missing tool $tool; restored backup"; }
done
grep -q 'directRoutingConfigured: "NOT_CHECKED"' "$INDEX" || { cp -a "$BACKUP" "$INDEX"; fail "Direct Routing boundary marker missing; restored backup"; }
grep -q 'readOnlyHint: true' "$INDEX" || { cp -a "$BACKUP" "$INDEX"; fail "read-only annotation missing; restored backup"; }
echo "PASS"

echo "[6/7] Restart service"
if ! systemctl restart vodia-mcp; then
  cp -a "$BACKUP" "$INDEX"
  systemctl restart vodia-mcp || true
  fail "service restart failed; restored $BACKUP"
fi
if ! systemctl is-active --quiet vodia-mcp; then
  echo "Service failed after patch. Recent journal:"
  journalctl -u vodia-mcp -n 60 --no-pager || true
  cp -a "$BACKUP" "$INDEX"
  systemctl restart vodia-mcp || true
  fail "vodia-mcp inactive; restored $BACKUP"
fi
echo "PASS: vodia-mcp active"

echo "[7/7] Summary"
echo
echo "=== MICROSOFT PHASE 2 INSTALL PASS ==="
echo "Tools added:"
echo "  microsoft_get_user"
echo "  microsoft_check_teams_readiness"
echo "  microsoft_plan_vodia_teams_user"
echo "  microsoft_get_teams_gap_report"
echo "Microsoft writes: 0"
echo "Vodia PBX writes: 0"
echo "Teams Direct Routing configuration claimed: NO"
echo "Backup: $BACKUP"
echo
echo "TEST NEXT:"
echo "  microsoft_get_teams_gap_report"
echo "  microsoft_check_teams_readiness"
echo "Then, with a real UPN + future SBC FQDN:"
echo "  microsoft_check_teams_readiness({ userPrincipalName, sbcFqdn })"
echo "  microsoft_plan_vodia_teams_user({ userPrincipalName, vodiaTenant, extension, did, sbcFqdn })"
