#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.11-tenant-display-name.sh"
WORK="$(mktemp /tmp/vodia-mcp-v014911a.XXXXXX.sh)"
trap 'rm -f "$WORK"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in wget python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.11a — tenant display-name installer fix ==="
echo "Fixes the v0.14.9.11 planner assumption that only one combined public country_code field exists."
echo "The current v0.14.9.10 planner correctly has two: top-level plan metadata and nested Vodia metadata."

echo "[1/4] Fetch original v0.14.9.11 installer"
wget -qO "$WORK" "$BASE_URL"
bash -n "$WORK" || fail "downloaded v0.14.9.11 installer syntax invalid"
echo PASS

echo "[2/4] Patch the installer logic only"
python3 - "$WORK" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''public_country='country_code: normalizedCountryCode,'
if combined.count(public_country) != 1:
    raise SystemExit(f'PATCH ERROR: expected one combined public country_code field; found {combined.count(public_country)}')
combined=combined.replace(public_country,public_country+'\\n    display_name: normalizedDisplayName,',1)'''
new='''public_country='country_code: normalizedCountryCode,'
if combined.count(public_country) != 2:
    raise SystemExit(f'PATCH ERROR: expected two combined country_code fields (top-level + nested Vodia metadata); found {combined.count(public_country)}')
# Add display_name to the top-level public plan first.
combined=combined.replace(public_country,public_country+'\\n    display_name: normalizedDisplayName,',1)
# Add display_name to the nested Vodia metadata separately, preserving indentation.
nested_country='      country_code: normalizedCountryCode,'
if combined.count(nested_country) != 1:
    raise SystemExit(f'PATCH ERROR: expected one nested Vodia country_code field; found {combined.count(nested_country)}')
combined=combined.replace(nested_country,nested_country+'\\n      display_name: normalizedDisplayName,',1)'''
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: expected exactly one v0.14.9.11 problematic planner block; found {s.count(old)}')
s=s.replace(old,new,1)
p.write_text(s)
PY
bash -n "$WORK" || fail "patched installer syntax invalid"
grep -q 'expected two combined country_code fields' "$WORK" || fail "11a fix marker missing"
echo PASS

echo "[3/4] Dry static sanity check against current live planner"
python3 - <<'PY'
from pathlib import Path
s=Path('/opt/vodia-mcp/index.js').read_text()
start=s.index('async function planCreateTenantWithDns')
end=s.index('async function applyCreateTenantWithDns',start)
block=s[start:end]
count=block.count('country_code: normalizedCountryCode,')
if count != 2:
    raise SystemExit(f'FAIL: live combined planner has {count} country_code fields; expected 2')
if block.count('      country_code: normalizedCountryCode,') != 1:
    raise SystemExit('FAIL: nested Vodia country_code field shape not found exactly once')
print('PASS: live v0.14.9.10 planner matches the corrected v0.14.9.11a assumptions')
PY

echo "[4/4] Run corrected v0.14.9.11 installer"
exec bash "$WORK"
