#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.12-admin-first-dns-provider-choice.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "=== Vodia MCP v0.14.9.12a — admin-first DNS validation fix ==="
echo "Fixes the v0.14.9.12 static validator so it counts the get_dns_provider_choices tool registration itself, not every string occurrence."
echo "The original v0.14.9.12 patch logic and safety checks are otherwise unchanged."

echo "[1/4] Fetch original v0.14.9.12 installer"
curl -fsSL "$BASE_URL" -o "$TMP"
echo PASS

echo "[2/4] Patch static validation only"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''if s.count('"get_dns_provider_choices"') != 1:\n    raise SystemExit(f'VALIDATION ERROR: get_dns_provider_choices registration expected once, found {s.count(chr(34)+"get_dns_provider_choices"+chr(34))}')'''
new='''registration_marker='server.registerTool(\\n      "get_dns_provider_choices",'\nregistration_count=s.count(registration_marker)\nif registration_count != 1:\n    raise SystemExit(f'VALIDATION ERROR: get_dns_provider_choices registration expected once, found {registration_count}')'''
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: expected one validator anchor; found {s.count(old)}')
s=s.replace(old,new,1)
s=s.replace('=== Vodia MCP v0.14.9.12 — administrator-first DNS provider choice ===','=== Vodia MCP v0.14.9.12a — administrator-first DNS provider choice (validator corrected) ===',1)
p.write_text(s)
PY
bash -n "$TMP"
echo PASS

echo "[3/4] Verify current live base is still v0.14.9.11"
grep -q '0.14.9.11' /opt/vodia-mcp/version.js || { echo "FAIL: expected live base v0.14.9.11" >&2; exit 1; }
if grep -q 'v0.14.9.12 administrator-first DNS provider choice' /opt/vodia-mcp/index.js; then
  echo "FAIL: live index already contains v0.14.9.12 marker; inspect before continuing" >&2
  exit 1
fi
echo PASS

echo "[4/4] Run corrected installer"
bash "$TMP"

echo "PASS: v0.14.9.12a wrapper completed"
