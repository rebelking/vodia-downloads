#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.12-admin-first-dns-choice-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring backup..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.12 — administrator-first DNS provider choice ==="
echo "Adds a provider-discovery tool that asks the administrator to choose Vodia DNS or Cloudflare BEFORE the tenant FQDN is finalized."
echo "Existing provider eligibility validation, tenant display_name, country_code, Cloudflare DNS-FIRST and rollback behavior are preserved."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
for marker in \
  'async function getTenantDnsProviderChoices(tenant)' \
  '"get_tenant_dns_provider_choices"' \
  'v0.14.9.11 tenant display-name support' \
  '"plan_create_tenant_with_dns"' \
  '"plan_create_tenant"' \
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS' \
  'deleteSavedCloudflareDnsRecordById'; do
  grep -q "$marker" "$INDEX" || fail "required current capability missing: $marker"
done
grep -q '0.14.9.11' "$VERSION" || fail "expected installed base version 0.14.9.11"
if grep -q 'v0.14.9.12 administrator-first DNS provider choice' "$INDEX"; then
  echo "v0.14.9.12 already appears installed; exiting without changes."
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

echo "[3/8] Add administrator-first provider discovery"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='v0.14.9.12 administrator-first DNS provider choice'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.12 marker already present')

anchor='async function getTenantDnsProviderChoices(tenant) {'
if s.count(anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one getTenantDnsProviderChoices anchor; found {s.count(anchor)}')

helper=r'''// v0.14.9.12 administrator-first DNS provider choice.
// This discovery step is intentionally independent of a final tenant FQDN.
// It tells the MCP which DNS namespaces are available so the administrator can
// choose the provider first; the existing tenant-specific discovery remains the
// post-selection safety validator for the final FQDN.
async function getAdminDnsProviderChoices() {
  // Use a harmless synthetic tenant only to make the existing Vodia settings
  // reader expose configured managed-DNS wildcards. No write is performed.
  const probeTenant="provider-choice.invalid";
  const vodiaDns=await dnsChoiceReadVodiaSettings(probeTenant);

  let cloudflare;
  try {
    const status=getCloudflareIntegrationStatus();
    const zone=status?.domain ? String(status.domain).trim().toLowerCase().replace(/\.$/, "") : null;
    const connected=Boolean(status?.configured && zone);
    cloudflare={ connected, zone };
  } catch (error) {
    cloudflare={ connected:false, zone:null, error:String(error?.message || error).slice(0,300) };
  }

  const providers=[];
  const wildcards=Array.isArray(vodiaDns?.detected?.wildcards) ? vodiaDns.detected.wildcards.filter(Boolean) : [];
  if (vodiaDns?.readable && vodiaDns?.detected?.enabled && wildcards.length) {
    providers.push({
      id:"vodia",
      label:"Vodia DNS",
      available:true,
      namespaces:wildcards,
      detail:`Vodia managed DNS is available for ${wildcards.join(", ")}.`,
    });
  }
  if (cloudflare.connected) {
    providers.push({
      id:"cloudflare",
      label:"Cloudflare",
      available:true,
      namespaces:[cloudflare.zone],
      detail:`Cloudflare is connected for zone ${cloudflare.zone}.`,
    });
  }

  const noProvider=providers.length===0;
  return {
    changesMade:false,
    adminChoiceRequired:providers.length>1,
    autoSelected:false,
    selectedProvider:null,
    providers,
    providerIds:providers.map((p)=>p.id),
    noProvider,
    vodiaDns,
    cloudflare,
    question:noProvider
      ? "No DNS provider is currently available for tenant creation."
      : providers.length>1
        ? "Which DNS provider do you want to use for this tenant: Vodia DNS or Cloudflare?"
        : `Only ${providers[0].label} is currently available. Continue with that provider?`,
    workflow:{
      first:"Administrator selects the DNS provider before the tenant FQDN is finalized.",
      vodia:"If Vodia DNS is selected, choose/build the tenant FQDN inside one of the returned Vodia managed wildcards, then validate it with get_tenant_dns_provider_choices before planning the tenant.",
      cloudflare:"If Cloudflare is selected, choose/build the tenant FQDN inside the returned Cloudflare zone, then validate it with get_tenant_dns_provider_choices before planning the combined DNS+tenant change.",
      fallback:"Never silently switch to a different provider after the administrator explicitly selected one.",
    },
  };
}

'''
s=s.replace(anchor,helper+anchor,1)

# Keep tenant-specific provider validation, but remove the idea that it is the
# first customer-facing decision step. It remains a validator after provider choice.
old_desc='description: "Required provider-discovery step before creating a Vodia tenant. Checks Vodia managed wildcard DNS first and then connected Cloudflare. If exactly one provider is eligible it may be used automatically; if multiple are eligible ask the administrator to choose. Makes no changes.",'
new_desc='description: "Post-selection FQDN safety validator. Call get_dns_provider_choices first so the administrator chooses Vodia DNS or Cloudflare before the tenant FQDN is finalized. Then call this tool with the final FQDN to verify that the selected provider is actually eligible. Makes no changes and must never silently switch providers.",'
if s.count(old_desc) != 1:
    raise SystemExit(f'PATCH ERROR: expected one old tenant provider description; found {s.count(old_desc)}')
s=s.replace(old_desc,new_desc,1)

# Register the new provider-first tool immediately before the existing tenant-specific tool.
reg_anchor='''    server.registerTool(
      "get_tenant_dns_provider_choices",'''
if s.count(reg_anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one tenant provider registration anchor; found {s.count(reg_anchor)}')
registration=r'''    server.registerTool(
      "get_dns_provider_choices",
      {
        title: "Choose DNS provider for tenant creation",
        description: "FIRST step for a new tenant. Read available DNS providers and namespaces before the tenant FQDN is finalized. If both Vodia DNS and Cloudflare are available, ask the administrator which provider to use. Do not auto-select between multiple providers. Makes no changes.",
        inputSchema: {},
        outputSchema: toolOutputSchema,
        annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true },
      },
      async () => {
        scopedAudit("get_dns_provider_choices", { readOnly:true });
        try {
          const result=await getAdminDnsProviderChoices();
          return scopedSuccess(
            result,
            { operation:"GET_DNS_PROVIDER_CHOICES", readOnly:true, changesMade:false },
            result.noProvider
              ? "No DNS provider is currently available for tenant creation."
              : result.adminChoiceRequired
                ? "Choose Vodia DNS or Cloudflare before the tenant FQDN is finalized."
                : `${result.providers[0].label} is the only currently available DNS provider.`
          );
        } catch (error) {
          return failure(error, "DNS provider discovery");
        }
      }
    );

'''
s=s.replace(reg_anchor,registration+reg_anchor,1)
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.12\2',s,count=1)
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
checks={
 'marker':'v0.14.9.12 administrator-first DNS provider choice',
 'helper':'async function getAdminDnsProviderChoices()',
 'tool':'"get_dns_provider_choices"',
 'tenant-validator':'"get_tenant_dns_provider_choices"',
 'display-helper':'setAndVerifyTenantDisplayName',
 'country-helper':'setAndVerifyTenantCountryCode',
 'cloudflare-public-dns':'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
 'cloudflare-rollback':'deleteSavedCloudflareDnsRecordById',
}
for name,text in checks.items():
    c=s.count(text)
    if c < 1:
        raise SystemExit(f'VALIDATION ERROR: {name} missing')
if s.count('"get_dns_provider_choices"') != 1:
    raise SystemExit(f'VALIDATION ERROR: get_dns_provider_choices registration expected once, found {s.count(chr(34)+"get_dns_provider_choices"+chr(34))}')
if 'adminChoiceRequired:providers.length>1' not in s:
    raise SystemExit('VALIDATION ERROR: multiple-provider administrator choice rule missing')
if 'autoSelected:false' not in s:
    raise SystemExit('VALIDATION ERROR: provider-first auto-selection guard missing')
if 'Never silently switch to a different provider' not in s:
    raise SystemExit('VALIDATION ERROR: no-silent-fallback rule missing')
print('PASS: provider-first read-only discovery added')
print('PASS: Vodia wildcards and Cloudflare zone are exposed before FQDN selection')
print('PASS: multiple providers require explicit administrator choice')
print('PASS: tenant-specific provider eligibility validator preserved')
print('PASS: display_name + country_code flows preserved')
print('PASS: Cloudflare DNS-FIRST/public resolver/rollback markers preserved')
PY

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
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.12' "$HEALTH" || fail "health endpoint did not report v0.14.9.12"
echo PASS

echo "[8/8] Complete"
echo "PASS: v0.14.9.12 installed"
echo "PASS: FIRST tenant step = get_dns_provider_choices"
echo "PASS: if Vodia DNS + Cloudflare are both available, administrator must choose"
echo "PASS: selected provider namespace is shown before tenant FQDN is finalized"
echo "PASS: final FQDN is still validated with get_tenant_dns_provider_choices"
echo "PASS: no silent provider fallback"
echo "PASS: display_name maps to Vodia display and remains verified"
echo "PASS: country_code remains required and verified"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session so the updated tool catalog and descriptions are loaded."
trap - ERR
