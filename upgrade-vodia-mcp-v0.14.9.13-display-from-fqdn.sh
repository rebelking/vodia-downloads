#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.13-display-from-fqdn-$STAMP"
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

echo "=== Vodia MCP v0.14.9.13 — derive tenant display name from FQDN ==="
echo "If display_name is omitted, use the left-most DNS label as the Vodia tenant display field."
echo "An explicit display_name still overrides the derived value."

# 1) Preflight
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -q '0.14.9.12' "$VERSION" || fail "expected installed base version 0.14.9.12"
for marker in \
  'v0.14.9.12 administrator-first DNS provider choice' \
  'v0.14.9.11 tenant display-name support' \
  'async function planCreateTenantWithDns' \
  'async function planCreateTenant(' \
  'setAndVerifyTenantDisplayName' \
  '"get_dns_provider_choices"' \
  '"get_tenant_dns_provider_choices"'; do
  grep -q "$marker" "$INDEX" || fail "required capability missing: $marker"
done
if grep -q 'v0.14.9.13 derive tenant display from FQDN' "$INDEX"; then
  echo "v0.14.9.13 already appears installed; exiting without changes."
  exit 0
fi
echo "[1/7] Preflight PASS"

# 2) Backup/stage
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "[2/7] Backup + stage PASS: $BACKUP_DIR"

# 3) Patch staged index.js
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text()

marker='v0.14.9.13 derive tenant display from FQDN'
if marker in s:
    raise SystemExit('PATCH ERROR: v0.14.9.13 marker already present')

# Insert one helper after normalizeTenantDisplayName.
helper_anchor='''function normalizeTenantDisplayName(value) {\n  const display=String(value ?? "").trim();\n  if (!display) throw new Error("display_name is required and must not be blank.");\n  if (display.length > 255) throw new Error("display_name must be 255 characters or fewer.");\n  return display;\n}\n'''
if s.count(helper_anchor) != 1:
    raise SystemExit(f'PATCH ERROR: normalizeTenantDisplayName anchor count={s.count(helper_anchor)}')
helper=helper_anchor+'''\n// v0.14.9.13 derive tenant display from FQDN.\nfunction resolveTenantDisplayName(tenant, displayName) {\n  const explicit=String(displayName ?? "").trim();\n  if (explicit) return normalizeTenantDisplayName(explicit);\n\n  const normalizedTenant=normalizeTenantName(tenant);\n  const leftMostLabel=String(normalizedTenant.split(".")[0] || "").trim();\n  if (!leftMostLabel) throw new Error("Could not derive tenant display name from tenant FQDN.");\n  return normalizeTenantDisplayName(leftMostLabel);\n}\n'''
s=s.replace(helper_anchor,helper,1)

# Combined planner: derive from the normalized FQDN when displayName omitted.
combined_old='''async function planCreateTenantWithDns({ actor, tenant, countryCode, displayName, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = normalizeTenantDisplayName(displayName);'''
combined_new='''async function planCreateTenantWithDns({ actor, tenant, countryCode, displayName, ipv4, ttl = 1, comment = "", reason = "" } = {}) {\n  const normalizedTenant = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = resolveTenantDisplayName(normalizedTenant, displayName);'''
if s.count(combined_old) != 1:
    raise SystemExit(f'PATCH ERROR: combined planner display anchor count={s.count(combined_old)}')
s=s.replace(combined_old,combined_new,1)

# Standalone planner: same fallback behavior.
stand_old='''async function planCreateTenant({ actor, tenant, countryCode, displayName, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = normalizeTenantDisplayName(displayName);'''
stand_new='''async function planCreateTenant({ actor, tenant, countryCode, displayName, reason } = {}) {\n  const normalized = normalizeTenantName(tenant);\n  const normalizedCountryCode = normalizeTenantCountryCode(countryCode);\n  const normalizedDisplayName = resolveTenantDisplayName(normalized, displayName);'''
if s.count(stand_old) != 1:
    raise SystemExit(f'PATCH ERROR: standalone planner display anchor count={s.count(stand_old)}')
s=s.replace(stand_old,stand_new,1)

# Both MCP planner schemas should permit omission; handlers already pass undefined safely.
schema='display_name: z.string().min(1).max(255),'
count=s.count(schema)
if count != 2:
    raise SystemExit(f'PATCH ERROR: expected two required display_name schema fields; found {count}')
s=s.replace(schema,'display_name: z.string().min(1).max(255).optional(),')

# Update descriptions so clients know omission derives the value from DNS.
s=s.replace(
  'title: "Plan Vodia tenant creation",',
  'title: "Plan Vodia tenant creation",',1)
s=s.replace(
  'description: "PREFERRED customer-facing planner for natural-language requests to create a new Vodia tenant/domain when Cloudflare manages that zone. Use this instead of separate tenant and DNS planners. It checks both sides, creates no changes, discovers the PBX IPv4 when possible, defaults DNS to DNS-only/TTL Auto, and returns one concise exact approval phrase.",',
  'description: "PREFERRED customer-facing planner for natural-language requests to create a new Vodia tenant/domain when Cloudflare manages that zone. Use this instead of separate tenant and DNS planners. If display_name is omitted, the tenant display is derived from the left-most DNS label. It checks both sides, creates no changes, discovers the PBX IPv4 when possible, defaults DNS to DNS-only/TTL Auto, and returns one concise exact approval phrase.",',1)

# Static marker near helper is enough for idempotence.
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo "[3/7] Patch display derivation PASS"

# 4) Patch version
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.13\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo "[4/7] Version patch PASS"

# 5) Static safety validation
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
checks={
  'v0.14.9.13 marker':'v0.14.9.13 derive tenant display from FQDN',
  'resolver helper':'function resolveTenantDisplayName(tenant, displayName)',
  'provider-first tool':'"get_dns_provider_choices"',
  'tenant provider validator':'"get_tenant_dns_provider_choices"',
  'display write helper':'setAndVerifyTenantDisplayName',
  'country write helper':'setAndVerifyTenantCountryCode',
  'public resolver gate':'VODIA_MCP_DNS_PROPAGATION_RESOLVERS',
  'Cloudflare rollback':'deleteSavedCloudflareDnsRecordById',
}
for name,text in checks.items():
    if text not in s: raise SystemExit(f'VALIDATION ERROR: {name} missing')
if s.count('display_name: z.string().min(1).max(255).optional(),') != 2:
    raise SystemExit('VALIDATION ERROR: display_name optional schema count must be 2')
if s.count('resolveTenantDisplayName(normalizedTenant, displayName)') != 1:
    raise SystemExit('VALIDATION ERROR: combined display derivation missing')
if s.count('resolveTenantDisplayName(normalized, displayName)') != 1:
    raise SystemExit('VALIDATION ERROR: standalone display derivation missing')
if 'const leftMostLabel=String(normalizedTenant.split(".")[0]' not in s:
    raise SystemExit('VALIDATION ERROR: left-most DNS label derivation missing')
print('PASS: omitted display_name derives from left-most tenant DNS label')
print('PASS: explicit display_name still overrides the DNS-derived value')
print('PASS: both Vodia-native and Cloudflare tenant planners support the fallback')
print('PASS: provider-first DNS selection preserved')
print('PASS: country_code, display read-back, DNS-FIRST, resolver gate and rollback preserved')
PY
echo "[5/7] Static validation PASS"

# 6) Install/restart
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
grep -q '0.14.9.13' "$HEALTH" || fail "health endpoint did not report v0.14.9.13"
echo "[6/7] Install + health PASS"

# 7) Complete
echo "[7/7] Complete"
echo "PASS: v0.14.9.13 installed"
echo "PASS: display_name is optional in both tenant planners"
echo "PASS: if omitted, display is derived from the left-most label of the tenant FQDN"
echo "PASS: explicit display_name remains supported as an override"
echo "PASS: example homedepot.vodia-pbx.com -> display homedepot"
echo "PASS: administrator-first Vodia DNS / Cloudflare selection preserved"
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session so the optional display_name schema is reloaded."
trap - ERR
