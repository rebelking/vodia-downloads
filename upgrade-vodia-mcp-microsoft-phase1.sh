#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
ENV_DIR="/etc/vodia-mcp"
ENV_FILE="$ENV_DIR/microsoft.env"
DROPIN_DIR="/etc/systemd/system/vodia-mcp.service.d"
DROPIN_FILE="$DROPIN_DIR/microsoft.conf"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-microsoft-phase1.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Microsoft 365 Phase 1 — Read-only Graph Integration ==="

echo "[1/8] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q 'server.registerTool' "$INDEX" || fail "MCP tool registration anchor not found"
grep -q 'toolOutputSchema' "$INDEX" || fail "toolOutputSchema not found"
grep -q 'scopedSuccess' "$INDEX" || fail "scopedSuccess helper not found"
echo "PASS"

echo "[2/8] Backup"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

echo "[3/8] Configure protected Microsoft environment file"
install -d -m 0755 "$ENV_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cat > "$ENV_FILE" <<'EOF'
# Microsoft Entra app-only credentials for Vodia MCP.
# Fill these three values from Entra ID > App registrations > Vodia MCP.
MICROSOFT_TENANT_ID=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
EOF
  chmod 0600 "$ENV_FILE"
  echo "CREATED: $ENV_FILE"
else
  chmod 0600 "$ENV_FILE"
  echo "PRESERVED: existing $ENV_FILE"
fi

install -d -m 0755 "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
[Service]
EnvironmentFile=-$ENV_FILE
EOF
systemctl daemon-reload

echo "[4/8] Add Microsoft Graph helpers + MCP tools"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

marker = '"microsoft_get_tenant"'
if marker in s:
    print("Microsoft Phase 1 tools already present; leaving existing implementation unchanged.")
    raise SystemExit(0)

anchor = 'server.registerTool('
pos = s.find(anchor)
if pos < 0:
    raise SystemExit("PATCH ERROR: server.registerTool anchor not found")

block = r'''
// -----------------------------------------------------------------------------
// Microsoft 365 / Entra / Graph — Phase 1 (read-only)
// Credentials are supplied by environment variables only. Never log secrets.
// Required Graph application permissions:
//   User.Read.All, Organization.Read.All, Domain.Read.All
// -----------------------------------------------------------------------------

const microsoftGraphBaseUrl = "https://graph.microsoft.com/v1.0";
let microsoftTokenCache = { token: null, expiresAt: 0 };

function microsoftConfigStatus() {
  return {
    tenantIdConfigured: Boolean(process.env.MICROSOFT_TENANT_ID),
    clientIdConfigured: Boolean(process.env.MICROSOFT_CLIENT_ID),
    clientSecretConfigured: Boolean(process.env.MICROSOFT_CLIENT_SECRET),
  };
}

function requireMicrosoftConfig() {
  const tenantId = String(process.env.MICROSOFT_TENANT_ID || "").trim();
  const clientId = String(process.env.MICROSOFT_CLIENT_ID || "").trim();
  const clientSecret = String(process.env.MICROSOFT_CLIENT_SECRET || "").trim();
  const missing = [];
  if (!tenantId) missing.push("MICROSOFT_TENANT_ID");
  if (!clientId) missing.push("MICROSOFT_CLIENT_ID");
  if (!clientSecret) missing.push("MICROSOFT_CLIENT_SECRET");
  if (missing.length) {
    const err = new Error(`Microsoft Graph credentials are not configured: ${missing.join(", ")}`);
    err.code = "MICROSOFT_CONFIG_MISSING";
    throw err;
  }
  return { tenantId, clientId, clientSecret };
}

async function getMicrosoftGraphToken() {
  const now = Date.now();
  if (microsoftTokenCache.token && microsoftTokenCache.expiresAt > now + 60000) {
    return microsoftTokenCache.token;
  }

  const { tenantId, clientId, clientSecret } = requireMicrosoftConfig();
  const tokenUrl = `https://login.microsoftonline.com/${encodeURIComponent(tenantId)}/oauth2/v2.0/token`;
  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    scope: "https://graph.microsoft.com/.default",
    grant_type: "client_credentials",
  });

  const response = await fetch(tokenUrl, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body,
  });

  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.access_token) {
    const detail = payload.error_description || payload.error || `HTTP ${response.status}`;
    const err = new Error(`Microsoft token request failed: ${detail}`);
    err.code = "MICROSOFT_TOKEN_FAILED";
    throw err;
  }

  const expiresIn = Number(payload.expires_in || 3600);
  microsoftTokenCache = {
    token: payload.access_token,
    expiresAt: Date.now() + Math.max(60, expiresIn - 60) * 1000,
  };
  return payload.access_token;
}

async function microsoftGraphGet(pathname) {
  const token = await getMicrosoftGraphToken();
  const url = pathname.startsWith("http")
    ? pathname
    : `${microsoftGraphBaseUrl}${pathname.startsWith("/") ? "" : "/"}${pathname}`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      authorization: `Bearer ${token}`,
      accept: "application/json",
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const detail = payload?.error?.message || `HTTP ${response.status}`;
    const err = new Error(`Microsoft Graph request failed: ${detail}`);
    err.code = "MICROSOFT_GRAPH_FAILED";
    throw err;
  }
  return payload;
}

server.registerTool(
  "microsoft_get_tenant",
  {
    title: "Get Microsoft 365 tenant",
    description: "Read-only Microsoft Graph check that returns organization and verified-domain information for the configured Microsoft 365 tenant. Never changes Microsoft 365 or Vodia.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("microsoft_get_tenant", { configured: microsoftConfigStatus() });
    try {
      const [org, domains] = await Promise.all([
        microsoftGraphGet("/organization?$select=id,displayName,verifiedDomains"),
        microsoftGraphGet("/domains?$select=id,isDefault,isInitial,isVerified,authenticationType"),
      ]);
      const organization = Array.isArray(org.value) ? org.value[0] : null;
      return scopedSuccess(
        {
          connected: true,
          changesMade: false,
          organization,
          domains: Array.isArray(domains.value) ? domains.value : [],
        },
        { operation: "MICROSOFT_GET_TENANT", readOnly: true, changesMade: false },
        organization ? `Connected to Microsoft 365 tenant ${organization.displayName || organization.id}.` : "Microsoft Graph connected; organization record was empty."
      );
    } catch (error) {
      return failure(error, "Microsoft 365 tenant read");
    }
  }
);

server.registerTool(
  "microsoft_list_domains",
  {
    title: "List Microsoft 365 domains",
    description: "Read-only list of domains in the configured Microsoft 365 tenant, including verified/default status. Useful for Direct Routing readiness checks.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("microsoft_list_domains", {});
    try {
      const data = await microsoftGraphGet("/domains?$select=id,isDefault,isInitial,isVerified,authenticationType");
      const domains = Array.isArray(data.value) ? data.value : [];
      return scopedSuccess(
        { changesMade: false, count: domains.length, domains },
        { operation: "MICROSOFT_LIST_DOMAINS", readOnly: true, changesMade: false },
        `Found ${domains.length} Microsoft 365 domain(s).`
      );
    } catch (error) {
      return failure(error, "Microsoft 365 domain list");
    }
  }
);

server.registerTool(
  "microsoft_list_users",
  {
    title: "List Microsoft 365 users",
    description: "Read-only list of Microsoft 365 users with basic identity and assigned-license IDs. Does not expose passwords, tokens, or secrets.",
    inputSchema: { top: z.number().int().min(1).max(100).optional() },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ top = 50 }) => {
    scopedAudit("microsoft_list_users", { top });
    try {
      const data = await microsoftGraphGet(`/users?$top=${encodeURIComponent(top)}&$select=id,displayName,userPrincipalName,accountEnabled,assignedLicenses`);
      const users = Array.isArray(data.value) ? data.value : [];
      return scopedSuccess(
        { changesMade: false, count: users.length, users },
        { operation: "MICROSOFT_LIST_USERS", readOnly: true, changesMade: false },
        `Returned ${users.length} Microsoft 365 user(s).`
      );
    } catch (error) {
      return failure(error, "Microsoft 365 user list");
    }
  }
);

server.registerTool(
  "microsoft_list_licenses",
  {
    title: "List Microsoft 365 subscribed licenses",
    description: "Read-only Microsoft Graph view of tenant subscribed SKUs and consumption. Useful for checking Teams/Teams Phone licensing before Direct Routing deployment.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("microsoft_list_licenses", {});
    try {
      const data = await microsoftGraphGet("/subscribedSkus?$select=id,skuId,skuPartNumber,consumedUnits,prepaidUnits,capabilityStatus");
      const licenses = Array.isArray(data.value) ? data.value : [];
      return scopedSuccess(
        { changesMade: false, count: licenses.length, licenses },
        { operation: "MICROSOFT_LIST_LICENSES", readOnly: true, changesMade: false },
        `Found ${licenses.length} subscribed Microsoft SKU(s).`
      );
    } catch (error) {
      return failure(error, "Microsoft 365 license list");
    }
  }
);

server.registerTool(
  "microsoft_check_graph_readiness",
  {
    title: "Check Microsoft Graph readiness",
    description: "Read-only readiness check for the Vodia MCP Microsoft 365 connection. Tests app-only authentication plus tenant, domain, user, and license reads. Makes no changes.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("microsoft_check_graph_readiness", { configured: microsoftConfigStatus() });
    const checks = [];
    try {
      await getMicrosoftGraphToken();
      checks.push({ check: "oauth_client_credentials", status: "PASS" });
    } catch (error) {
      checks.push({ check: "oauth_client_credentials", status: "FAIL", error: error.message });
      return scopedSuccess(
        { ready: false, changesMade: false, configured: microsoftConfigStatus(), checks },
        { operation: "MICROSOFT_CHECK_GRAPH_READINESS", readOnly: true, changesMade: false },
        "Microsoft Graph readiness failed at OAuth authentication."
      );
    }

    for (const [name, path] of [
      ["organization_read", "/organization?$select=id,displayName"],
      ["domain_read", "/domains?$select=id,isVerified"],
      ["user_read", "/users?$top=1&$select=id,userPrincipalName"],
      ["license_read", "/subscribedSkus?$select=skuId,skuPartNumber"],
    ]) {
      try {
        await microsoftGraphGet(path);
        checks.push({ check: name, status: "PASS" });
      } catch (error) {
        checks.push({ check: name, status: "FAIL", error: error.message });
      }
    }

    const ready = checks.every((c) => c.status === "PASS");
    return scopedSuccess(
      { ready, changesMade: false, configured: microsoftConfigStatus(), checks },
      { operation: "MICROSOFT_CHECK_GRAPH_READINESS", readOnly: true, changesMade: false },
      ready ? "Microsoft Graph Phase 1 is ready." : "Microsoft Graph connection is partially configured; review failed checks."
    );
  }
);

'''

s = s[:pos] + block + s[pos:]
p.write_text(s)
print("PASS: Microsoft Phase 1 tools inserted")
PY

echo "[5/8] Validate JavaScript"
node --check "$INDEX"
echo "PASS"

echo "[6/8] Safety contract checks"
for tool in microsoft_get_tenant microsoft_list_domains microsoft_list_users microsoft_list_licenses microsoft_check_graph_readiness; do
  grep -q "\"$tool\"" "$INDEX" || fail "missing tool $tool"
done
grep -q 'readOnlyHint: true' "$INDEX" || fail "read-only annotation missing"
if grep -q 'MICROSOFT_CLIENT_SECRET=.*[^=[:space:]]' "$INDEX"; then
  fail "secret-like value found in source"
fi
echo "PASS"

echo "[7/8] Restart service"
systemctl restart vodia-mcp
systemctl is-active --quiet vodia-mcp || fail "vodia-mcp did not restart"
echo "PASS: vodia-mcp active"

echo "[8/8] Summary"
echo
echo "=== MICROSOFT PHASE 1 INSTALL PASS ==="
echo "Tools added:"
echo "  microsoft_get_tenant"
echo "  microsoft_list_domains"
echo "  microsoft_list_users"
echo "  microsoft_list_licenses"
echo "  microsoft_check_graph_readiness"
echo "Microsoft writes: 0"
echo "Vodia PBX writes: 0"
echo "Backup: $BACKUP"
echo
echo "NEXT: edit $ENV_FILE and fill:"
echo "  MICROSOFT_TENANT_ID"
echo "  MICROSOFT_CLIENT_ID"
echo "  MICROSOFT_CLIENT_SECRET"
echo "Then run:"
echo "  systemctl restart vodia-mcp"
echo "  journalctl -u vodia-mcp -n 50 --no-pager"
echo "Finally call MCP tool: microsoft_check_graph_readiness"
