#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.9-public-dns-$STAMP"
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

printf '%s\n' "=== Vodia MCP v0.14.9.9 — public DNS propagation + rollback ==="
printf '%s\n' "Uses independent public resolvers instead of the host resolver and rolls back DNS if propagation fails before tenant creation."

echo "[1/7] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'async function waitForPublicDnsA' "$INDEX" || fail "DNS propagation helper missing"
grep -q 'createSavedCloudflareARecord' "$INDEX" || fail "Cloudflare create helper missing"
grep -q 'deleteSavedCloudflareDnsRecordById' "$INDEX" || fail "Cloudflare rollback helper missing"
grep -q 'const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);' "$INDEX" || fail "expected propagation gate call missing"
grep -q 'path: "/rest/system/domains"' "$INDEX" || fail "Vodia tenant endpoint missing"
if grep -q 'v0.14.9.9 independent public DNS resolvers' "$INDEX"; then
  echo "v0.14.9.9 already installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/7] Backup + stage"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"

echo "[3/7] Patch resolver gate + propagation rollback"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

start=s.find('// v0.14.9.4 DNS-FIRST public propagation gate.')
end=s.find('\nasync function applyCreateTenantWithDns(', start)
if start < 0 or end < 0:
    raise SystemExit('PATCH ERROR: waitForPublicDnsA block boundaries not found')

helper=r'''// v0.14.9.9 independent public DNS resolvers.
// Do not use the MCP host resolver here: the host may cache NXDOMAIN from an
// earlier lookup made before the Cloudflare record existed. Query independent
// recursive resolvers directly so the ACME safety gate is not tied to host cache.
async function waitForPublicDnsA(name, expectedIpv4, {
  timeoutMs = Number(process.env.VODIA_MCP_DNS_PROPAGATION_TIMEOUT_MS || 120000),
  intervalMs = Number(process.env.VODIA_MCP_DNS_PROPAGATION_INTERVAL_MS || 3000),
  consecutiveSuccesses = Number(process.env.VODIA_MCP_DNS_PROPAGATION_SUCCESSES || 2),
  resolverServers = String(process.env.VODIA_MCP_DNS_PROPAGATION_RESOLVERS || "1.1.1.1,8.8.8.8")
    .split(",").map((v) => v.trim()).filter(Boolean),
} = {}) {
  const fqdn = String(name || "").trim().toLowerCase();
  const expected = String(expectedIpv4 || "").trim();
  const deadline = Date.now() + Math.max(5000, timeoutMs);
  const pause = Math.max(500, intervalMs);
  const requiredRounds = Math.max(1, consecutiveSuccesses);
  const servers = [...new Set(resolverServers)];
  if (!servers.length) throw new Error("DNS_PROPAGATION_FAILED: no public DNS resolvers are configured.");

  const { Resolver } = await import("node:dns/promises");
  const resolvers = servers.map((server) => {
    const resolver = new Resolver();
    resolver.setServers([server]);
    return { server, resolver };
  });

  let attempt = 0;
  let streak = 0;
  let lastResults = [];

  while (Date.now() <= deadline) {
    attempt += 1;
    lastResults = await Promise.all(resolvers.map(async ({ server, resolver }) => {
      try {
        const answers = await resolver.resolve4(fqdn, { ttl: true });
        const addresses = [...new Set((answers || []).map((item) =>
          typeof item === "string" ? item : String(item?.address || "")
        ).filter(Boolean))];
        return { server, ok: addresses.includes(expected), addresses, error: null };
      } catch (error) {
        return { server, ok: false, addresses: [], error: String(error?.code || error?.message || error) };
      }
    }));

    const allResolversMatch = lastResults.every((result) => result.ok);
    if (allResolversMatch) {
      streak += 1;
      if (streak >= requiredRounds) {
        return {
          verified: true,
          name: fqdn,
          expectedIpv4: expected,
          attempts: attempt,
          consecutiveSuccesses: streak,
          resolverPolicy: "all-configured-resolvers-must-match",
          resolvers: lastResults,
        };
      }
    } else {
      streak = 0;
    }

    if (Date.now() > deadline) break;
    await new Promise((resolve) => setTimeout(resolve, pause));
  }

  const summary = lastResults.map((r) =>
    `${r.server}=${r.addresses.length ? r.addresses.join(",") : (r.error || "no-answer")}`
  ).join("; ");
  throw new Error(
    `DNS_PROPAGATION_FAILED: '${fqdn}' did not resolve to PBX IPv4 '${expected}' on all configured public resolvers ` +
    `before timeout. Last results: ${summary || "none"}. Vodia tenant creation was NOT attempted.`
  );
}
'''

s=s[:start]+helper+s[end:]

old='''    const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);'''
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: expected one propagation gate call; found {s.count(old)}')
new=r'''    let publicDns;
    try {
      publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);
    } catch (dnsError) {
      // No PBX write has occurred yet. Roll back exactly the Cloudflare record
      // created by this approved plan and verify it is absent before returning.
      let rollbackResult = null;
      let rollbackError = null;
      try {
        rollbackResult = await deleteSavedCloudflareDnsRecordById({
          recordId: cfRecord.id,
          expectedName: plan.tenant,
        });
      } catch (error) {
        rollbackError = error;
      }
      tenantDnsBundlePlans.delete(id);
      if (rollbackError) {
        throw new Error(
          `${String(dnsError?.message || dnsError)} ROLLBACK WARNING: Cloudflare record ${cfRecord.id} may remain: ${rollbackError.message}`
        );
      }
      throw new Error(
        `${String(dnsError?.message || dnsError)} Cloudflare rollback PASS: record ${cfRecord.id} was removed and verified absent=${Boolean(rollbackResult?.verifiedAbsent)}.`
      );
    }'''
s=s.replace(old,new,1)

p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/7] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.9\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/7] Static safety validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
required=[
  'v0.14.9.9 independent public DNS resolvers',
  'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
  'resolver.setServers([server])',
  '1.1.1.1,8.8.8.8',
  'Cloudflare rollback PASS:',
  'deleteSavedCloudflareDnsRecordById({',
  'publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);',
]
for item in required:
    if item not in s: raise SystemExit(f'VALIDATION ERROR: missing {item!r}')

start=s.index('async function applyCreateTenantWithDns')
end=s.find('\nasync function ',start+10)
block=s[start:] if end < 0 else s[start:end]
pos_cf=block.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=block.find('publicDns = await waitForPublicDnsA')
pos_rollback=block.find('Cloudflare rollback PASS:', pos_dns)
pos_pbx=block.find('method: "POST",\n        path: "/rest/system/domains"')
if min(pos_cf,pos_dns,pos_rollback,pos_pbx) < 0:
    raise SystemExit(f'VALIDATION ERROR: workflow marker missing cf={pos_cf} dns={pos_dns} rollback={pos_rollback} pbx={pos_pbx}')
if not (pos_cf < pos_dns < pos_rollback < pos_pbx):
    raise SystemExit(f'VALIDATION ERROR: expected Cloudflare -> DNS gate/rollback -> PBX order, got {pos_cf}, {pos_dns}, {pos_rollback}, {pos_pbx}')
print('PASS: public resolver gate uses explicit resolver servers')
print('PASS: propagation failure rolls back the just-created Cloudflare record before any PBX write')
print('PASS: Vodia tenant POST remains after successful DNS propagation')
PY

echo "[6/7] Install + restart"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
node --check "$INDEX" >/dev/null
node --check "$VERSION" >/dev/null
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo

echo "[7/7] Complete"
echo "PASS: v0.14.9.9 installed"
echo "PASS: propagation checks bypass the MCP host DNS cache"
echo "PASS: default resolvers = 1.1.1.1 and 8.8.8.8"
echo "PASS: both configured resolvers must return the PBX IPv4 for two consecutive rounds by default"
echo "PASS: propagation timeout before PBX creation => Cloudflare record rollback + verified absence"
echo "Optional env: VODIA_MCP_DNS_PROPAGATION_RESOLVERS / TIMEOUT_MS / INTERVAL_MS / SUCCESSES"
echo "Backup: $BACKUP_DIR"
trap - ERR
