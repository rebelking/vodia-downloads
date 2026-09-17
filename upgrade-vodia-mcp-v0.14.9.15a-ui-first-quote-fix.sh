#!/usr/bin/env bash
set -Eeuo pipefail

BASE=/root/upgrade-vodia-mcp-v0.14.9.15-ui-first-no-duplicate-summary.sh
FIXED=/root/upgrade-vodia-mcp-v0.14.9.15a-ui-first-no-duplicate-summary-fixed.sh
URL=https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.15-ui-first-no-duplicate-summary.sh
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"

echo "=== Vodia MCP v0.14.9.15a — UI-first quote fix ==="
echo "Fixes the v0.14.9.15 installer so its server instruction is valid JavaScript."
echo "The intended UI-first behavior is unchanged."

echo "[1/5] Verify safe live base"
node --check "$APP/index.js" >/dev/null || fail "live index.js is not valid"
grep -q '0.14.9.14' "$APP/version.js" || fail "expected live base v0.14.9.14"
curl -fsS http://127.0.0.1:3100/health | grep -q '"version":"0.14.9.14"' || fail "health is not reporting v0.14.9.14"
echo PASS

echo "[2/5] Fetch original v0.14.9.15 installer"
curl -fsSL "$URL" -o "$BASE"
chmod +x "$BASE"
bash -n "$BASE" || fail "original installer shell syntax invalid"
echo PASS

echo "[3/5] Patch only the unsafe embedded quote"
cp -a "$BASE" "$FIXED"
python3 - "$FIXED" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='respond only with a minimal status such as \\"Plan ready — use the approval card above.\\" '
# The original file contains literal double quotes in the Python string payload.
if old not in s:
    old='respond only with a minimal status such as "Plan ready — use the approval card above." '
if old not in s:
    raise SystemExit('PATCH ERROR: unsafe quoted status phrase not found exactly once')
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: unsafe phrase count={s.count(old)}')
new='respond only with a minimal status such as Plan ready — use the approval card above. '
s=s.replace(old,new,1)
p.write_text(s)
PY
chmod +x "$FIXED"
bash -n "$FIXED" || fail "fixed installer shell syntax invalid"
grep -q 'minimal status such as Plan ready — use the approval card above.' "$FIXED" || fail "fixed phrase not present"
echo PASS

echo "[4/5] Run corrected v0.14.9.15 installer"
"$FIXED"

echo "[5/5] Verify healthy v0.14.9.15"
node --check "$APP/index.js" >/dev/null || fail "installed index.js invalid"
curl -fsS http://127.0.0.1:3100/health | tee /tmp/vodia-mcp-15a-health.json
grep -q '"version":"0.14.9.15"' /tmp/vodia-mcp-15a-health.json || fail "health did not report v0.14.9.15"
echo
echo "PASS: v0.14.9.15 installed with valid UI-first server instructions"
echo "PASS: tenant approval card remains primary on MCP Apps hosts"
echo "PASS: non-UI text fallback and apply confirmation guards remain preserved"
