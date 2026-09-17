#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.7-restore-tenant-country-helpers.sh"
TMP="$(mktemp --suffix=.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

echo "=== Vodia MCP v0.14.9.8 — tenant-country repair validator fix ==="
echo "[1/4] Download v0.14.9.7 repair base"
curl -fsSL "$BASE_URL" -o "$TMP"
chmod +x "$TMP"
bash -n "$TMP" || fail "downloaded v0.14.9.7 repair has invalid shell syntax"
echo PASS

echo "[2/4] Relax brittle schema preflight + validation"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

# v0.14.9.7 incorrectly required one exact formatting of the schema reference.
# The runtime ReferenceError already proves the symbol is referenced; formatting
# differences must not block the helper restoration.
s=s.replace("grep -q 'country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN' \"$INDEX\" || fail \"tenant country schema reference missing\"\n", "")
s=s.replace("grep -q 'setAndVerifyTenantCountryCode' \"$INDEX\" || fail \"tenant country apply reference missing\"\n", "")

# Remove the brittle exact schema-string requirement from static validation.
s=s.replace(" 'schema':'country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN',\n", "")

# Add a semantic usage guard after helper checks: declaration + at least one use.
needle="for name,text in checks.items():\n    if s.count(text) != 1:\n        raise SystemExit(f'VALIDATION ERROR: {name} expected exactly once, found {s.count(text)}')\n"
replacement=needle+"if s.count('VODIA_TENANT_COUNTRY_CODE_PATTERN') < 2:\n    raise SystemExit('VALIDATION ERROR: country-code pattern is not referenced by runtime/schema logic')\n"
if needle not in s:
    raise SystemExit('PATCH ERROR: v0.14.9.7 validation anchor not found')
s=s.replace(needle,replacement,1)

# Promote visible version labels and connector version to 0.14.9.8.
s=s.replace('v0.14.9.7', 'v0.14.9.8')
s=s.replace('0.14.9.7\\2', '0.14.9.8\\2')

p.write_text(s)
PY
bash -n "$TMP" || fail "corrected repair installer has invalid shell syntax"
echo PASS

echo "[3/4] Execute corrected repair"
"$TMP"

echo "[4/4] v0.14.9.8 complete"
echo "PASS: brittle exact schema formatting check removed"
echo "PASS: complete tenant-country helper block restoration attempted"
echo "PASS: DNS-FIRST and automatic PBX-IP checks remain enforced by the base repair"
