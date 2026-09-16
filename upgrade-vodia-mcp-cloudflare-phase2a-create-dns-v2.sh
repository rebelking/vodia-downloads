#!/usr/bin/env bash
set -Eeuo pipefail

# Cloudflare Phase 2A installer v2
#
# The original v1 installer rolled back cleanly on the live v0.14.7 server
# because its AWS Chime insertion anchor expected server.registerTool( and the
# tool name on the same logical line. The live file has them on separate lines.
#
# This wrapper downloads the pinned v1 installer, replaces only that fragile
# anchor with a structure-aware lookup, syntax-checks the corrected installer,
# and executes it. v1's own backup/rollback/health checks remain intact.

V1_COMMIT="747a1ec34c4e83b9e7d0bff372dbf275651dd4a8"
V1_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${V1_COMMIT}/upgrade-vodia-mcp-cloudflare-phase2a-create-dns-v1.sh"
TMP="$(mktemp /tmp/vodia-cloudflare-phase2a-v2.XXXXXX.sh)"

cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "Run as root"
command -v wget >/dev/null 2>&1 || fail "wget is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2A installer v2 ==="
printf '%s\n' "Fixes the v1 AWS Chime tool insertion anchor for the live v0.14.7 layout."
printf '%s\n' "The failed v1 run already restored the live files; this installer starts from that known-good state."

echo "[1/4] Download pinned v1 installer"
wget -q -O "$TMP" "$V1_URL"
[[ -s "$TMP" ]] || fail "could not download pinned v1 installer"
echo "PASS"

echo "[2/4] Replace fragile index.js insertion anchor"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

start = s.find("anchor2 = '    server.registerTool(")
end = s.find("tools = r'''    server.registerTool(", start)
if start < 0 or end < 0 or end <= start:
    raise SystemExit("PATCH ERROR: could not locate the v1 AWS Chime anchor block")

replacement = r'''# Locate the existing AWS Chime planner structurally inside the same adminMode
# block as plan_create_tenant. The live v0.14.7 file places server.registerTool(
# and the tool name on separate lines, so do not depend on whitespace layout.
tenant_tool_idx = s.find('"plan_create_tenant"')
if tenant_tool_idx < 0:
    raise SystemExit('PATCH ERROR: plan_create_tenant tool not found while locating adminMode block')
admin_idx = s.rfind('if (adminMode) {', 0, tenant_tool_idx)
if admin_idx < 0:
    raise SystemExit('PATCH ERROR: adminMode block not found before plan_create_tenant')
aws_name_idx = s.find('"aws_chime_plan_create_voice_connector"', tenant_tool_idx)
if aws_name_idx < 0:
    raise SystemExit('PATCH ERROR: aws_chime_plan_create_voice_connector tool not found after tenant planner')
idx2 = s.rfind('server.registerTool(', admin_idx, aws_name_idx)
if idx2 < 0:
    raise SystemExit('PATCH ERROR: server.registerTool for AWS Chime planner not found inside adminMode block')
# Insert at the beginning of the registration line so indentation remains valid.
line_start = s.rfind('\n', admin_idx, idx2)
idx2 = admin_idx if line_start < 0 else line_start + 1

'''

s = s[:start] + replacement + s[end:]
p.write_text(s)
PY

grep -q 'aws_chime_plan_create_voice_connector tool not found after tenant planner' "$TMP" \
  || fail "corrected anchor was not written"
if grep -q "anchor2 = '    server.registerTool" "$TMP"; then
  fail "fragile v1 anchor still present"
fi
echo "PASS"

echo "[3/4] Validate corrected installer"
bash -n "$TMP"
echo "PASS: corrected installer syntax valid"

echo "[4/4] Run corrected Phase 2A installer"
chmod 700 "$TMP"
bash "$TMP"

echo
echo "PASS: Cloudflare Phase 2A v2 wrapper completed."
echo "If the inner installer reports all eight steps PASS, reconnect/start a fresh Claude MCP session so the new tools are discovered."
