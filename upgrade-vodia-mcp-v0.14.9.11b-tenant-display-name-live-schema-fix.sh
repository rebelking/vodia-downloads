#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.11-tenant-display-name.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
command -v wget >/dev/null 2>&1 || fail "wget is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v bash >/dev/null 2>&1 || fail "bash is required"

cat <<'EOF'
=== Vodia MCP v0.14.9.11b — tenant display-name live-schema fix ===
Fixes v0.14.9.11 assumptions to match the actual v0.14.9.10 live MCP source:
  - combined planner has two country_code metadata fields (top-level + nested Vodia)
  - country_code schemas use z.coerce.string(), not z.string()
The MCP parameter is display_name; the Vodia tenant config field written is display.
EOF

echo "[1/5] Fetch original v0.14.9.11 installer"
wget -qO "$TMP" "$BASE_URL"
bash -n "$TMP" || fail "downloaded v0.14.9.11 installer syntax invalid"
echo PASS

echo "[2/5] Patch installer assumptions to actual live schema"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

repls=[
(
"if combined.count(public_country) != 1:\n    raise SystemExit(f'PATCH ERROR: expected one combined public country_code field; found {combined.count(public_country)}')",
"if combined.count(public_country) != 2:\n    raise SystemExit(f'PATCH ERROR: expected two combined public country_code fields; found {combined.count(public_country)}')"
),
(
'''          country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),\n          ipv4: z.string().min(7).max(15).optional(),''',
'''          country_code: z.coerce.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),\n          ipv4: z.string().min(7).max(15).optional(),'''
),
(
'''        country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),\n        reason: z.string().max(1000).optional(),''',
'''        country_code: z.coerce.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN, 'Use digits only, without "+".'),\n        reason: z.string().max(1000).optional(),'''
),
]
for old,new in repls:
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'WRAPPER PATCH ERROR: expected exactly one installer anchor, found {n}: {old[:90]!r}')
    s=s.replace(old,new,1)

# Add a visible wrapper marker to the downloaded installer output.
s=s.replace('=== Vodia MCP v0.14.9.11 — tenant display name ===',
            '=== Vodia MCP v0.14.9.11b — tenant display name (live-schema corrected) ===',1)
p.write_text(s)
PY
bash -n "$TMP" || fail "corrected installer syntax invalid"
echo PASS

echo "[3/5] Verify actual live v0.14.9.10 schema before touching anything"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/vodia-mcp/index.js').read_text()
checks={
 'version marker':'v0.14.9.10 DNS provider choice routing',
 'standalone tool':'"plan_create_tenant"',
 'combined tool':'"plan_create_tenant_with_dns"',
 'coerced country schema':'country_code: z.coerce.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN',
 'display not yet installed':'v0.14.9.11 tenant display-name support',
}
for k,v in list(checks.items())[:4]:
    if v not in s: raise SystemExit(f'LIVE SCHEMA ERROR: missing {k}: {v}')
if checks['display not yet installed'] in s:
    raise SystemExit('LIVE SCHEMA ERROR: display-name support already appears installed')
# Current combined planner intentionally exposes country_code twice: top-level and nested vodia metadata.
a=s.index('async function planCreateTenantWithDns')
b=s.index('async function applyCreateTenantWithDns',a)
block=s[a:b]
if block.count('country_code: normalizedCountryCode,') != 2:
    raise SystemExit(f"LIVE SCHEMA ERROR: expected 2 combined country_code metadata fields, found {block.count('country_code: normalizedCountryCode,')}")
print('PASS: live schema matches v0.14.9.11b assumptions')
PY

echo "[4/5] Run corrected installer"
bash "$TMP"

echo "[5/5] Verify tenant-name mapping + healthy version"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/vodia-mcp/index.js').read_text()
checks=[
 'v0.14.9.11 tenant display-name support',
 'display_name: z.string().min(1).max(255)',
 'body.display=expected;',
 'setAndVerifyTenantDisplayName',
 'displayVerified: true',
]
for c in checks:
    if c not in s: raise SystemExit(f'POST-INSTALL VERIFY ERROR: missing {c}')
print('PASS: MCP accepts display_name and maps it to Vodia config field display')
PY
curl -fsS http://127.0.0.1:3100/health; echo

echo "PASS: v0.14.9.11b completed"
echo "MCP input: display_name"
echo "Vodia tenant config field: display"
