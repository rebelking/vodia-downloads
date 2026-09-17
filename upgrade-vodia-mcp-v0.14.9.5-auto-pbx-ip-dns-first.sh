#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.5 — automatic PBX public IPv4 + DNS-FIRST tenant creation
#
# Customer tenant workflow:
#   PLAN
#     - determine PBX public IPv4 automatically from the configured Vodia endpoint
#     - verify tenant absent from Vodia
#     - verify exact DNS name absent from Cloudflare
#     - DO NOT require the new tenant hostname to resolve yet
#   APPLY
#     1. create Cloudflare A record (DNS only) -> detected PBX public IPv4
#     2. verify Cloudflare record
#     3. wait for public DNS to resolve tenant hostname -> detected PBX public IPv4
#     4. only then POST /rest/system/domains to Vodia
#
# An explicit ipv4 remains accepted as an engineering override, but normal customer
# tenant creation should not require the administrator to provide the PBX IP.

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.5-auto-pbx-ip-$STAMP"
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

printf '%s\n' "=== Vodia MCP v0.14.9.5 — automatic PBX IP + DNS-FIRST tenant creation ==="
printf '%s\n' "The MCP derives the PBX public IPv4 from the configured Vodia endpoint."
printf '%s\n' "A new tenant hostname is expected NOT to resolve during planning."
printf '%s\n' "No tenant or DNS record is created by this installer."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'async function discoverBundleIpv4' "$INDEX" || fail "discoverBundleIpv4 helper missing"
grep -q 'async function planCreateTenantWithDns' "$INDEX" || fail "combined tenant planner missing"
grep -q 'async function applyCreateTenantWithDns' "$INDEX" || fail "combined tenant apply helper missing"
grep -q 'async function waitForPublicDnsA' "$INDEX" || fail "v0.14.9.4 DNS propagation gate missing"
grep -q 'const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);' "$INDEX" || fail "DNS propagation gate is not before tenant creation"
if grep -q 'v0.14.9.5 automatic PBX public IPv4 discovery' "$INDEX"; then
  echo "v0.14.9.5 already installed; exiting without changes."
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

echo "[3/8] Patch automatic PBX IPv4 discovery + planner semantics"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1])
s=p.read_text()

if 'v0.14.9.5 automatic PBX public IPv4 discovery' in s:
    raise SystemExit('PATCH ERROR: v0.14.9.5 marker already present')

start=s.find('async function discoverBundleIpv4(')
end=s.find('\nasync function planCreateTenantWithDns(', start)
if start < 0 or end < 0:
    raise SystemExit('PATCH ERROR: discoverBundleIpv4 block boundaries not found')

replacement=r'''// v0.14.9.5 automatic PBX public IPv4 discovery.
// Normal customer tenant creation should not require an administrator to type the
// PBX IP. The MCP is already connected to Vodia, so derive the address from the
// configured Vodia endpoint. The *new tenant hostname* is deliberately NOT looked
// up here; it is expected to be absent until APPLY creates the Cloudflare record.
function isUsablePublicIpv4(value) {
  const raw = String(value || "").trim();
  const parts = raw.split(".").map((v) => Number(v));
  if (parts.length !== 4 || parts.some((v) => !Number.isInteger(v) || v < 0 || v > 255)) return false;
  const [a,b] = parts;
  if (a === 0 || a === 10 || a === 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && b === 168) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a >= 224) return false;
  return true;
}

async function discoverBundleIpv4(ipv4, zone) {
  // Engineering override remains available, but it is not required for the normal
  // customer workflow.
  if (String(ipv4 || "").trim()) {
    const explicit = validateIpv4ForPlan(ipv4);
    return { ipv4: explicit, source: "explicit", automatic: false };
  }

  const configured = [
    ["PBX_BASE_URL", process.env.PBX_BASE_URL],
    ["VODIA_BASE_URL", process.env.VODIA_BASE_URL],
    ["VODIA_URL", process.env.VODIA_URL],
    ["PBX_URL", process.env.PBX_URL],
  ].filter(([,value]) => String(value || "").trim());

  if (!configured.length) {
    throw new Error("PBX public IPv4 could not be determined automatically because no configured Vodia endpoint was found.");
  }

  const { resolve4 } = await import("node:dns/promises");
  const attempts = [];

  for (const [envName, rawValue] of configured) {
    const raw = String(rawValue || "").trim();
    let hostname = "";
    try {
      const candidate = raw.includes("://") ? raw : `https://${raw}`;
      hostname = new URL(candidate).hostname.trim().toLowerCase();
    } catch (error) {
      attempts.push(`${envName}: invalid URL/host`);
      continue;
    }
    if (!hostname) continue;

    // If the configured Vodia endpoint itself is a public IPv4, use it directly.
    if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(hostname)) {
      const validated = validateIpv4ForPlan(hostname);
      if (!isUsablePublicIpv4(validated)) {
        attempts.push(`${envName}: configured address ${validated} is not a usable public IPv4`);
        continue;
      }
      return {
        ipv4: validated,
        source: `configured-endpoint:${envName}:${hostname}`,
        endpointHostname: hostname,
        automatic: true,
      };
    }

    // Preferred automatic path: resolve the exact hostname used by the MCP to
    // reach Vodia and use its unique public A address.
    try {
      const answers = await resolve4(hostname);
      const publicAnswers = [...new Set((answers || []).map(String).filter(isUsablePublicIpv4))];
      if (publicAnswers.length === 1) {
        return {
          ipv4: validateIpv4ForPlan(publicAnswers[0]),
          source: `configured-endpoint-dns:${envName}:${hostname}`,
          endpointHostname: hostname,
          automatic: true,
        };
      }
      if (publicAnswers.length > 1) {
        attempts.push(`${envName}:${hostname} resolves to multiple public A records (${publicAnswers.join(", ")})`);
      } else {
        attempts.push(`${envName}:${hostname} has no usable public A record`);
      }
    } catch (error) {
      attempts.push(`${envName}:${hostname} DNS ${String(error?.code || error?.message || error)}`);
    }

    // Fallback for a Cloudflare-managed Vodia hostname: use an exact unique A
    // record from the configured zone. This is useful if the host resolver cannot
    // resolve temporarily but Cloudflare configuration is authoritative here.
    if (hostname === zone || hostname.endsWith(`.${zone}`)) {
      try {
        const result = await listSavedCloudflareDnsRecords({ name: hostname, type: "A" });
        const exact = (Array.isArray(result?.records) ? result.records : []).filter(
          (record) => normalizeCloudflarePlanName(record?.name) === hostname
            && String(record?.type || "").toUpperCase() === "A"
            && Boolean(record?.proxied) === false
        );
        const unique = [...new Set(exact.map((record) => String(record?.content || "").trim()).filter(isUsablePublicIpv4))];
        if (unique.length === 1) {
          return {
            ipv4: validateIpv4ForPlan(unique[0]),
            source: `cloudflare-configured-endpoint:${hostname}`,
            endpointHostname: hostname,
            automatic: true,
          };
        }
      } catch (error) {
        attempts.push(`cloudflare:${hostname} ${String(error?.message || error)}`);
      }
    }
  }

  throw new Error(
    "PBX public IPv4 could not be determined unambiguously from the configured Vodia endpoint. " +
    "No tenant or DNS record was changed. Discovery details: " + attempts.join("; ")
  );
}
'''

s=s[:start]+replacement+s[end:]

# The propagation failure happens AFTER the Cloudflare write; call it propagation,
# not pre-flight, so the client does not mistake ENOTFOUND-before-create for a
# planner requirement.
s=s.replace('DNS_PREFLIGHT_FAILED:', 'DNS_PROPAGATION_FAILED:', 1)

# Add explicit planner output documenting that absence of public DNS is expected
# before APPLY. Insert beside the existing sequence field if present.
needle='sequence: ["create_cloudflare_dns", "verify_cloudflare_dns", "create_vodia_tenant", "verify_vodia_tenant", "final_verify_both"],'
if needle in s:
    repl='''sequence: ["create_cloudflare_dns", "verify_cloudflare_dns", "wait_for_public_dns", "create_vodia_tenant", "verify_vodia_tenant", "final_verify_both"],
    dnsPlanningPolicy: "NEW_HOSTNAME_MAY_BE_UNRESOLVED_DURING_PLAN; public DNS is checked only after Cloudflare creation and before the Vodia tenant POST.",'''
    s=s.replace(needle,repl,1)
else:
    # Newer source may already contain wait_for_public_dns. Add policy near operation.
    op='operation: "CreateVodiaTenantWithCloudflareDns",'
    pos=s.find(op, s.find('async function planCreateTenantWithDns'))
    if pos < 0:
        raise SystemExit('PATCH ERROR: planner return operation anchor not found')
    insert=pos+len(op)
    s=s[:insert]+'\n    dnsPlanningPolicy: "NEW_HOSTNAME_MAY_BE_UNRESOLVED_DURING_PLAN; public DNS is checked only after Cloudflare creation and before the Vodia tenant POST.",'+s[insert:]

# Strengthen the combined planner tool description without changing its schema.
s=s.replace(
  'Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record.',
  'Customer-facing combined planner for one new Vodia tenant and its Cloudflare A record. Automatically derives the PBX public IPv4 from the configured Vodia endpoint; a brand-new tenant hostname is expected to be unresolved during planning.',
  1
)

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.5\2',s,count=1)
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
required=[
  'v0.14.9.5 automatic PBX public IPv4 discovery',
  'configured-endpoint-dns:',
  'NEW_HOSTNAME_MAY_BE_UNRESOLVED_DURING_PLAN',
  'DNS_PROPAGATION_FAILED:',
  'const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);',
]
for item in required:
    if item not in s: raise SystemExit(f'VALIDATION ERROR: missing {item!r}')
if 'DNS_PREFLIGHT_FAILED:' in s:
    raise SystemExit('VALIDATION ERROR: obsolete DNS_PREFLIGHT_FAILED wording remains')

plan_start=s.index('async function planCreateTenantWithDns')
apply_start=s.index('async function applyCreateTenantWithDns', plan_start)
plan_block=s[plan_start:apply_start]
# Planner may query Cloudflare API for name conflicts, but must not resolve the new
# tenant hostname through waitForPublicDnsA before a record exists.
if 'waitForPublicDnsA(' in plan_block:
    raise SystemExit('VALIDATION ERROR: planner is attempting public DNS propagation before Cloudflare creation')

apply_end=s.find('\nasync function ', apply_start+10)
apply_block=s[apply_start:] if apply_end < 0 else s[apply_start:apply_end]
pos_cf=apply_block.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=apply_block.find('const publicDns = await waitForPublicDnsA')
pos_pbx=apply_block.find('method: "POST",\n        path: "/rest/system/domains"')
if min(pos_cf,pos_dns,pos_pbx) < 0 or not (pos_cf < pos_dns < pos_pbx):
    raise SystemExit(f'VALIDATION ERROR: required order is not Cloudflare -> DNS propagation -> Vodia ({pos_cf}, {pos_dns}, {pos_pbx})')
print('PASS: planner does not require new hostname resolution')
print('PASS: PBX IPv4 is derived automatically from configured Vodia endpoint')
print('PASS: APPLY order = Cloudflare create -> public DNS -> Vodia tenant create')
PY
echo PASS

if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then
  echo "PATCH-ONLY PASS: staged patch validated; nothing installed or restarted"
  exit 0
fi

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
echo PASS

echo "[8/8] v0.14.9.5 installed"
echo "PASS: normal tenant planning automatically determines the connected PBX public IPv4"
echo "PASS: a brand-new tenant hostname is NOT required to resolve during planning"
echo "PASS: Cloudflare A record is created DNS-only first"
echo "PASS: public DNS propagation is checked only AFTER Cloudflare creation"
echo "PASS: Vodia tenant POST is allowed only AFTER DNS resolves to the detected PBX IPv4"
echo "PASS: ambiguous/missing PBX public IP => no DNS or tenant write"
echo "Backup: $BACKUP_DIR"
trap - ERR
