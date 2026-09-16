#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
CF="$APP/cloudflare-integration.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-cloudflare-mcp-tools.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Cloudflare — expose read-only MCP tools ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
test -f "$CF" || fail "missing $CF — install Cloudflare Phase 1 first"
grep -q 'export async function checkSavedCloudflareConnection' "$CF" || fail "Cloudflare saved-connection helper missing"
grep -q 'export function getCloudflareIntegrationStatus' "$CF" || fail "Cloudflare status helper missing"
grep -q 'export async function listSavedCloudflareDnsRecords' "$CF" || fail "Cloudflare DNS read helper missing"
grep -q 'server.registerTool' "$INDEX" || fail "MCP tool registration anchor missing"
grep -q 'toolOutputSchema' "$INDEX" || fail "toolOutputSchema helper missing"
grep -q 'scopedSuccess' "$INDEX" || fail "scopedSuccess helper missing"
grep -q 'scopedAudit' "$INDEX" || fail "scopedAudit helper missing"
grep -q 'failure(' "$INDEX" || fail "failure helper missing"
echo "PASS"

if grep -q '"cloudflare_check_connection"' "$INDEX"; then
  echo "Cloudflare MCP read tools already appear installed. Exiting without changes."
  exit 0
fi

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

rollback(){
  local rc=$?
  echo "Cloudflare MCP tools patch failed; restoring $BACKUP"
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

echo "[3/7] Patch index.js"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

if '"cloudflare_check_connection"' in s:
    print('Cloudflare MCP tools already present; no patch needed.')
    raise SystemExit(0)

imp = '''import {\n  checkSavedCloudflareConnection,\n  getCloudflareIntegrationStatus,\n  listSavedCloudflareDnsRecords,\n} from "./cloudflare-integration.js";\n'''

if 'from "./cloudflare-integration.js"' not in s:
    if s.startswith('#!'):
        nl = s.find('\n')
        if nl < 0:
            raise SystemExit('PATCH ERROR: malformed index.js shebang')
        s = s[:nl+1] + imp + s[nl+1:]
    else:
        s = imp + s

anchor = 'server.registerTool('
idx = s.find(anchor)
if idx < 0:
    raise SystemExit('PATCH ERROR: server.registerTool anchor not found')

block = r'''
// -----------------------------------------------------------------------------
// Cloudflare DNS — Phase 1 MCP exposure (read-only)
// Credentials remain server-side in the encrypted integration store. These tools
// never accept or return the Cloudflare API token and perform zero DNS writes.
// -----------------------------------------------------------------------------

function cloudflareNormalizeRecordName(value) {
  return String(value || "").trim().toLowerCase().replace(/\.$/, "");
}

server.registerTool(
  "cloudflare_check_connection",
  {
    title: "Check Cloudflare connection",
    description: "Read-only check of the saved Cloudflare integration. Verifies the stored credential can authenticate, the configured zone can be found, and DNS records can be read. The API token is never returned.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("cloudflare_check_connection", {});
    try {
      const result = await checkSavedCloudflareConnection();
      return scopedSuccess(
        { ...result, changesMade: false },
        { operation: "CLOUDFLARE_CHECK_CONNECTION", readOnly: true, changesMade: false },
        result?.connected ? `Cloudflare connection is healthy for ${result.domain || "the configured zone"}.` : "Cloudflare is not configured."
      );
    } catch (error) {
      return failure(error, "Cloudflare connection check");
    }
  }
);

server.registerTool(
  "cloudflare_get_zone",
  {
    title: "Get Cloudflare zone",
    description: "Read-only summary of the Cloudflare zone currently connected to Vodia MCP. Returns zone metadata only and never returns the stored API token.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async () => {
    scopedAudit("cloudflare_get_zone", {});
    try {
      const status = getCloudflareIntegrationStatus();
      if (!status?.configured) {
        return scopedSuccess(
          { ...status, changesMade: false },
          { operation: "CLOUDFLARE_GET_ZONE", readOnly: true, changesMade: false },
          "Cloudflare is not configured."
        );
      }
      const check = await checkSavedCloudflareConnection();
      return scopedSuccess(
        {
          changesMade: false,
          provider: "cloudflare",
          configured: true,
          connected: Boolean(check?.connected),
          domain: check?.domain || status.domain || null,
          zoneId: check?.zoneId || status.zoneId || null,
          zoneStatus: check?.zoneStatus || null,
          accountName: check?.accountName || status.accountName || null,
          permissions: check?.permissions || null,
          credentialStored: true,
        },
        { operation: "CLOUDFLARE_GET_ZONE", readOnly: true, changesMade: false },
        `Cloudflare zone ${check?.domain || status.domain} read successfully.`
      );
    } catch (error) {
      return failure(error, "Cloudflare zone read");
    }
  }
);

server.registerTool(
  "cloudflare_list_dns_records",
  {
    title: "List Cloudflare DNS records",
    description: "Read-only list of DNS records in the saved Cloudflare zone. Optional name and type filters may be supplied. Performs zero DNS writes.",
    inputSchema: {
      name: z.string().optional(),
      type: z.string().optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ name, type }) => {
    scopedAudit("cloudflare_list_dns_records", { name, type });
    try {
      const result = await listSavedCloudflareDnsRecords({ name: name || "", type: type || "" });
      return scopedSuccess(
        { ...result, changesMade: false, count: Array.isArray(result?.records) ? result.records.length : 0 },
        { operation: "CLOUDFLARE_LIST_DNS_RECORDS", readOnly: true, changesMade: false },
        `Read ${Array.isArray(result?.records) ? result.records.length : 0} Cloudflare DNS record(s).`
      );
    } catch (error) {
      return failure(error, "Cloudflare DNS record list");
    }
  }
);

server.registerTool(
  "cloudflare_get_dns_record",
  {
    title: "Get Cloudflare DNS record",
    description: "Read-only lookup for one DNS name in the saved Cloudflare zone. Optionally filter by record type. Returns all exact-name matches and performs zero writes.",
    inputSchema: {
      name: z.string().min(1),
      type: z.string().optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
  },
  async ({ name, type }) => {
    const normalizedName = cloudflareNormalizeRecordName(name);
    scopedAudit("cloudflare_get_dns_record", { name: normalizedName, type });
    try {
      const result = await listSavedCloudflareDnsRecords({ name: normalizedName, type: type || "" });
      const records = (Array.isArray(result?.records) ? result.records : []).filter(
        (record) => cloudflareNormalizeRecordName(record?.name) === normalizedName
      );
      return scopedSuccess(
        {
          changesMade: false,
          provider: "cloudflare",
          domain: result?.domain || null,
          query: { name: normalizedName, type: type || null },
          found: records.length > 0,
          count: records.length,
          records,
        },
        { operation: "CLOUDFLARE_GET_DNS_RECORD", readOnly: true, changesMade: false },
        records.length ? `Found ${records.length} exact Cloudflare DNS record match(es) for ${normalizedName}.` : `No Cloudflare DNS record exists for ${normalizedName}.`
      );
    } catch (error) {
      return failure(error, "Cloudflare DNS record read");
    }
  }
);

'''

s = s[:idx] + block + s[idx:]
p.write_text(s)
PY

echo "[4/7] Validate JavaScript"
node --check "$INDEX"
node --check "$CF"
echo "PASS"

echo "[5/7] Validate safety boundaries"
grep -q '"cloudflare_check_connection"' "$INDEX" || fail "cloudflare_check_connection missing"
grep -q '"cloudflare_get_zone"' "$INDEX" || fail "cloudflare_get_zone missing"
grep -q '"cloudflare_list_dns_records"' "$INDEX" || fail "cloudflare_list_dns_records missing"
grep -q '"cloudflare_get_dns_record"' "$INDEX" || fail "cloudflare_get_dns_record missing"
if grep -E 'cloudflare_(create|update|delete)_dns|apply_cloudflare_change' "$INDEX" >/dev/null; then
  fail "unexpected Cloudflare write tool detected in read-only patch"
fi
echo "PASS: read-only tool set only"

echo "[6/7] Restart Vodia MCP"
systemctl restart "$SERVICE"
for attempt in {1..20}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-cloudflare-mcp-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
if ! test -s /tmp/vodia-cloudflare-mcp-health.json; then
  journalctl -u "$SERVICE" -n 60 --no-pager || true
  fail "health endpoint did not become ready"
fi
cat /tmp/vodia-cloudflare-mcp-health.json
echo

echo "[7/7] Cloudflare MCP read tools installed"
echo "Backup retained at: $BACKUP"
echo "Tools exposed:"
echo "  cloudflare_check_connection"
echo "  cloudflare_get_zone"
echo "  cloudflare_list_dns_records"
echo "  cloudflare_get_dns_record"
echo "No Cloudflare DNS write tools were added."
echo "Reconnect the Claude MCP connector (or start a fresh chat) so Claude refreshes the tool list."
trap - ERR
