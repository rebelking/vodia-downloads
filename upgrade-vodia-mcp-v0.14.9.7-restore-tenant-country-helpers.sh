#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.7-country-helper-restore-$STAMP"
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

printf '%s\n' "=== Vodia MCP v0.14.9.7 — restore tenant country helpers ==="
printf '%s\n' "Repairs helper block accidentally removed by the v0.14.9.6 PBX-IP patch."

echo "[1/7] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'async function planCreateTenantWithDns' "$INDEX" || fail "combined tenant planner missing"
grep -q 'country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN' "$INDEX" || fail "tenant country schema reference missing"
grep -q 'setAndVerifyTenantCountryCode' "$INDEX" || fail "tenant country apply reference missing"
if grep -q 'v0.14.9.7 restored tenant country helpers' "$INDEX"; then
  echo "v0.14.9.7 already installed; exiting without changes."
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

echo "[3/7] Restore complete tenant country helper block"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

marker='// v0.14.9.7 restored tenant country helpers.'
if marker in s:
    raise SystemExit('PATCH ERROR: restore marker already present')

anchor='async function planCreateTenantWithDns('
if s.count(anchor) != 1:
    raise SystemExit(f'PATCH ERROR: expected one combined planner anchor; found {s.count(anchor)}')

# v0.14.9.6 replaced the region immediately before planCreateTenantWithDns and
# accidentally deleted all four helpers originally introduced by v0.14.9.1.
# Restore the whole dependency block so schemas and apply logic cannot fail one
# symbol at a time.
helpers=r'''// v0.14.9.7 restored tenant country helpers.
// Mirrors Vodia's portal country_code field: ITU calling codes, digits only.
const VODIA_TENANT_COUNTRY_CODE_PATTERN = /^(?:1|2[078]|2[1234569]\d|3[0123469]|3[578]\d|4[013-9]|42\d|5[1-8]|5[09]\d|6[0-6]|6[7-9]\d|7|8[123469]|8[0578]\d|9[0123458]|9[679]\d)$/;
function normalizeTenantCountryCode(value) {
  const code=String(value ?? "").trim();
  if (!VODIA_TENANT_COUNTRY_CODE_PATTERN.test(code)) {
    throw new Error('country_code must use the Vodia calling-code format: digits only, without "+".');
  }
  return code;
}
async function readTenantSystemInfo(tenant) {
  const wanted=String(tenant||"").trim().toLowerCase();
  for (let page=1; page<=100; page+=1) {
    const list=await vodiaSystemJson({path:`/rest/system/domaininfo?size=100&page=${page}`});
    const rows=Array.isArray(list.data)?list.data:[];
    const row=rows.find((entry)=>{
      const names=[entry?.name,entry?.primary,entry?.display,...(Array.isArray(entry?.alias)?entry.alias:[])].map((v)=>String(v||"").trim().toLowerCase());
      return names.includes(wanted);
    });
    if (row?.id != null) {
      const detail=await vodiaSystemJson({path:`/rest/system/domaininfo?id=${encodeURIComponent(String(row.id))}`});
      const data=Array.isArray(detail.data)?detail.data[0]:detail.data;
      return data && typeof data === "object" ? data : null;
    }
    if (rows.length < 100) break;
  }
  return null;
}
async function setAndVerifyTenantCountryCode(tenant,countryCode) {
  const configPath=`/rest/domain/${encodeURIComponent(tenant)}/config`;
  const response=await vodiaSystemJson({path:configPath});
  const raw=Array.isArray(response.data)?response.data[0]:response.data;
  if (!raw || typeof raw !== "object") throw new Error("tenant config could not be read after tenant creation");
  const allowed=new Set(["primary","alias","admins","country_code","display","license_key","max_extensions","max_attendants","max_callingcards","max_hunts","max_hoots","max_srvflags","max_ivrnodes","max_doors","max_acds","max_conferences","max_colines","max_calls","max_trunk_calls","max_trunk_notify","max_call_duration","max_regs","parm1","parm2","parm3","billing_start","bill_customer","bill_admin","bill_data","bill_plan","voice2text","google_voice2text_key","spamreject","sms_enabled","didr","rec_enabled","cloud_provider_public","lastdigits","cdr_keep","rec_keep","visible"]);
  const body=Object.fromEntries(Object.entries(raw).filter(([key,value])=>allowed.has(key) && value !== undefined));
  body.primary=String(body.primary||tenant);
  body.alias=Array.isArray(body.alias)&&body.alias.length?body.alias:[tenant];
  body.admins=Array.isArray(body.admins)?body.admins:[];
  body.country_code=countryCode;
  await vodiaSystemJson({method:"POST",path:configPath,body});
  const detail=await readTenantSystemInfo(tenant);
  const verified=String(detail?.country??"").trim();
  if (verified !== countryCode) throw new Error(`country read-back was '${verified||"empty"}', expected '${countryCode}'`);
  return {country_code:countryCode,verifiedCountry:verified,tenantId:detail?.id??null};
}

'''

# Do not create duplicate definitions if some future source restored any symbol.
for symbol in [
    'const VODIA_TENANT_COUNTRY_CODE_PATTERN',
    'function normalizeTenantCountryCode(',
    'async function readTenantSystemInfo(',
    'async function setAndVerifyTenantCountryCode(',
]:
    if symbol in s:
        raise SystemExit(f'PATCH ERROR: partial helper state detected: {symbol} already exists; refusing duplicate definitions')

s=s.replace(anchor,helpers+anchor,1)
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[4/7] Patch connector version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.7\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[5/7] Static validation"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
checks={
 'pattern':'const VODIA_TENANT_COUNTRY_CODE_PATTERN',
 'normalize':'function normalizeTenantCountryCode(',
 'read':'async function readTenantSystemInfo(',
 'set':'async function setAndVerifyTenantCountryCode(',
 'schema':'country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN',
 'dns_gate':'const publicDns = await waitForPublicDnsA(plan.tenant, plan.ipv4);',
 'auto_ip':'v0.14.9.5 automatic PBX public IPv4 discovery',
}
for name,text in checks.items():
    if s.count(text) != 1:
        raise SystemExit(f'VALIDATION ERROR: {name} expected exactly once, found {s.count(text)}')
# Preserve DNS-FIRST order from v0.14.9.6.
apply_start=s.index('async function applyCreateTenantWithDns')
apply_end=s.find('\nasync function ',apply_start+10)
block=s[apply_start:] if apply_end < 0 else s[apply_start:apply_end]
pos_cf=block.find('const cfResult = await createSavedCloudflareARecord')
pos_dns=block.find('const publicDns = await waitForPublicDnsA')
pos_pbx=block.find('method: "POST",\n        path: "/rest/system/domains"')
if min(pos_cf,pos_dns,pos_pbx)<0 or not (pos_cf < pos_dns < pos_pbx):
    raise SystemExit(f'VALIDATION ERROR: DNS-FIRST order changed ({pos_cf}, {pos_dns}, {pos_pbx})')
print('PASS: all tenant country dependencies restored exactly once')
print('PASS: DNS-FIRST order preserved')
print('PASS: automatic PBX-IP discovery preserved')
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

echo "[7/7] Runtime smoke guard"
# createVodiaServer is lazy and may only run on an authenticated MCP request, so
# we cannot fully exercise it here without credentials. We can still reject any
# immediate startup regressions and print the exact post-install verification step.
if journalctl -u "$SERVICE" --since "2 minutes ago" --no-pager | grep -E 'SyntaxError|ERR_MODULE|already registered' >/tmp/vodia-mcp-v01497-errors.$$; then
  cat /tmp/vodia-mcp-v01497-errors.$$ || true
  rm -f /tmp/vodia-mcp-v01497-errors.$$
  false
fi
rm -f /tmp/vodia-mcp-v01497-errors.$$ || true

echo "PASS: v0.14.9.7 installed"
echo "PASS: VODIA_TENANT_COUNTRY_CODE_PATTERN restored"
echo "PASS: normalizeTenantCountryCode restored"
echo "PASS: readTenantSystemInfo restored"
echo "PASS: setAndVerifyTenantCountryCode restored"
echo "NEXT: retry one read-only MCP call from Claude while watching journalctl -u vodia-mcp -f -o cat"
echo "Backup: $BACKUP_DIR"
trap - ERR
