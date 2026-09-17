#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.4 — DNS-FIRST tenant creation
#
# Enforces the customer tenant creation sequence:
#   1. Create Cloudflare A record (DNS only)
#   2. Verify the record through Cloudflare
#   3. Wait until PUBLIC DNS resolves the tenant FQDN to the PBX IPv4
#   4. Only then POST the tenant to Vodia
#   5. Continue normal tenant/country/certificate workflow
#
# If public DNS never becomes ready, the Vodia tenant write is never attempted.
# This installer does not itself create DNS records or PBX tenants.

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.4-dns-first-$STAMP"
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
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"

printf '%s\n' "=== Vodia MCP v0.14.9.4 — DNS-FIRST tenant creation ==="
printf '%s\n' "Cloudflare DNS must be publicly resolvable before the Vodia tenant POST is allowed."
printf '%s\n' "No tenant or DNS record is created by this installer."

echo "[1/8] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'async function applyCreateTenantWithDns' "$INDEX" || fail "combined tenant + DNS apply helper missing"
grep -q 'createSavedCloudflareARecord' "$INDEX" || fail "Cloudflare A-record helper missing"
grep -q 'path: "/rest/system/domains"' "$INDEX" || fail "Vodia tenant endpoint missing"
grep -q 'proxied: false' "$INDEX" || fail "DNS-only Cloudflare policy missing"
if grep -q 'v0.14.9.4 DNS-FIRST public propagation gate' "$INDEX"; then
  echo "v0.14.9.4 DNS-FIRST gate already installed; exiting without changes."
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

echo "[3/8] Patch DNS-FIRST public propagation gate"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

if 'v0.14.9.4 DNS-FIRST public propagation gate' in s:
    raise SystemExit('PATCH ERROR: marker already present')

anchor='async function applyCreateTenantWithDns({ actor, changeId, confirmation } = {}) {'
if s.count(anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one applyCreateTenantWithDns anchor; found {s.count(anchor)}')

helper=r'''// v0.14.9.4 DNS-FIRST public propagation gate.
// A Cloudflare API write is not enough: Vodia/ACME must not see the tenant until
// the new hostname is actually resolvable through DNS. This resolver check occurs
// BEFORE POST /rest/system/domains, so a failed DNS gate results in zero PBX writes.
async function waitForPublicDnsA(name, expectedIpv4, {
  timeoutMs = Number(process.env.VODIA_MCP_DNS_PROPAGATION_TIMEOUT_MS || 120000),
  intervalMs = Number(process.env.VODIA_MCP_DNS_PROPAGATION_INTERVAL_MS || 3000),
  consecutiveSuccesses = Number(process.env.VODIA_MCP_DNS_PROPAGATION_SUCCESSES || 2),
} = {}) {
  const fqdn = String(name || "").trim().toLowerCase();
  const expected = String(expectedIpv4 || "").trim();
  const deadline = Date.now() + Math.max(5000, timeoutMs);
  const pause = Math.max(500, intervalMs);
  const required = Math.max(1, consecutiveSuccesses);
  let attempt = 0;
  let streak = 0;
  let lastAddresses = [];
  let lastError = null;

  // Dynamic import avoids changing the module's import block and uses the host's
  // configured recursive resolver, which exercises real DNS rather than merely
  // re-reading the Cloudflare API object.
  const { resolve4 } = await import("node:dns/promises");

  while (Date.now() <= deadline) {
    attempt += 1;
    try {
      const answers = await resolve4(fqdn, { ttl: true });
      lastAddresses = [...new Set((answers || []).map((item) =>
        typeof item === "string" ? item : String(item?.address || "")
      ).filter(Boolean))];
      lastError = null;
      if (lastAddresses.includes(expected)) {
        streak += 1;
        if (streak >= required) {
          return {
            verified: true,
            name: fqdn,
            expectedIpv4: expected,
            addresses: lastAddresses,
            attempts: attempt,
            consecutiveSuccesses: streak,
          };
        }
      } else {
        streak = 0;
      }
    } catch (error) {
      streak = 0;
      lastAddresses = [];
      lastError = String(error?.code || error?.message || error);
    }
    if (Date.now() > deadline) break;
    await new Promise((resolve) => setTimeout(resolve, pause));
  }

  const observed = lastAddresses.length ? lastAddresses.join(", ") : "none";
  throw new Error(
    `DNS_PREFLIGHT_FAILED: '${fqdn}' did not resolve to PBX IPv4 '${expected}' ` +
    `before timeout. Last A answers: ${observed}. Last resolver error: ${lastError || "none"}. ` +
    `Vodia tenant creation was NOT attempted.`
  );
}

'''
s=s.replace(anchor,helper+anchor,1)

insert_anchor='''    // One last PBX conflict check after DNS succeeds but before tenant write.\n'''
if s.count(insert_anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one DNS-to-PBX transition anchor; found {s.count(insert_anchor)}')

gate=r'''    // DNS-FIRST hard gate: do not create the Vodia tenant merely because the
    // Cloudflare API object exists. Wait for real DNS resolution first. Vodia may
    // start ACME immediately when the tenant is created, so propagation must win
    // that race before POST /rest/system/domains is allowed.
    const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);

'''
s=s.replace(insert_anchor,gate+insert_anchor,1)

# Expose DNS gate proof in the successful combined result.
result_anchor='''      cloudflare: {\n        verified: true,\n        zone: plan.zone,\n        record: finalRecord,\n      },'''
if s.count(result_anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one Cloudflare result block; found {s.count(result_anchor)}')
result_new='''      cloudflare: {\n        verified: true,\n        zone: plan.zone,\n        record: finalRecord,\n        publicDnsVerifiedBeforeTenantCreate: true,\n        publicDns,\n      },'''
s=s.replace(result_anchor,result_new,1)

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/8] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.4\2',s,count=1)
if n==s:
    raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/8] Static safety validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
s=Path(__import__('sys').argv[1]).read_text()
required=[
  'v0.14.9.4 DNS-FIRST public propagation gate',
  'async function waitForPublicDnsA(',
  'DNS_PREFLIGHT_FAILED:',
  'Vodia tenant creation was NOT attempted.',
  'const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);',
  'publicDnsVerifiedBeforeTenantCreate: true',
]
for item in required:
    if item not in s:
        raise SystemExit(f'VALIDATION ERROR: missing {item!r}')

# Validate order INSIDE the combined apply helper, not elsewhere in the file.
start=s.index('async function applyCreateTenantWithDns')
end=s.find('\nasync function ',start+10)
block=s[start:] if end < 0 else s[start:end]
pos_cf=block.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=block.find('const publicDns = await waitForPublicDnsA')
pos_pbx=block.find('method: "POST",\n        path: "/rest/system/domains"')
if min(pos_cf,pos_dns,pos_pbx) < 0:
    raise SystemExit(f'VALIDATION ERROR: workflow markers missing cf={pos_cf} dns={pos_dns} pbx={pos_pbx}')
if not (pos_cf < pos_dns < pos_pbx):
    raise SystemExit(f'VALIDATION ERROR: DNS-FIRST order wrong cf={pos_cf} dns={pos_dns} pbx={pos_pbx}')
print('PASS: Cloudflare create -> public DNS verify -> Vodia tenant POST')
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
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'SyntaxError|ReferenceError|ERR_MODULE|already registered' >/tmp/vodia-mcp-v01494-errors.$$; then
  cat /tmp/vodia-mcp-v01494-errors.$$ || true
  rm -f /tmp/vodia-mcp-v01494-errors.$$
  false
fi
rm -f /tmp/vodia-mcp-v01494-errors.$$ || true
cat "$HEALTH"; echo
echo PASS

echo "[8/8] DNS-FIRST tenant workflow installed"
echo "PASS: Cloudflare A record is created first (DNS only)"
echo "PASS: Cloudflare record verification remains required"
echo "PASS: public DNS must resolve tenant FQDN to the PBX IPv4"
echo "PASS: two consecutive public DNS resolutions are required by default"
echo "PASS: Vodia POST /rest/system/domains occurs only after DNS passes"
echo "PASS: DNS timeout => zero Vodia tenant-create writes"
echo "Defaults: timeout=120s interval=3s successes=2"
echo "Optional env: VODIA_MCP_DNS_PROPAGATION_TIMEOUT_MS / INTERVAL_MS / SUCCESSES"
echo "Backup: $BACKUP_DIR"
trap - ERR
