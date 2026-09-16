#!/usr/bin/env bash
set -Eeuo pipefail

# Cloudflare Phase 2A installer v3
#
# Fixes both issues found while applying the original Phase 2A installer to the
# live Vodia MCP 0.14.7 layout:
#   1. the AWS Chime tool insertion anchor was too whitespace-sensitive;
#   2. the Cloudflare import appender could produce `,,` when the existing
#      import list already ended with a trailing comma.
#
# This wrapper downloads the pinned v1 installer, applies only those two
# corrections, validates the corrected shell installer, and executes it.
# The inner installer's own backup/rollback, JS syntax checks, service health
# checks, and duplicate-registration checks remain in force.

V1_COMMIT="747a1ec34c4e83b9e7d0bff372dbf275651dd4a8"
V1_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${V1_COMMIT}/upgrade-vodia-mcp-cloudflare-phase2a-create-dns-v1.sh"
TMP="$(mktemp /tmp/vodia-cloudflare-phase2a-v3.XXXXXX.sh)"

cleanup(){ rm -f "$TMP"; }
trap cleanup EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "Run as root"
command -v wget >/dev/null 2>&1 || fail "wget is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2A installer v3 ==="
printf '%s\n' "Fixes live v0.14.7 AWS Chime insertion and Cloudflare import trailing-comma handling."
printf '%s\n' "The failed v2 run restored the live files before exiting."

echo "[1/5] Download pinned v1 installer"
wget -q -O "$TMP" "$V1_URL"
[[ -s "$TMP" ]] || fail "could not download pinned v1 installer"
echo "PASS"

echo "[2/5] Fix Cloudflare import appender"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = """if 'createSavedCloudflareARecord' not in body:\n    body = body.rstrip() + ',\\n  createSavedCloudflareARecord,\\n'\n    repl = 'import {' + body + '} from \"./cloudflare-integration.js\";'\n"""
new = """if 'createSavedCloudflareARecord' not in body:\n    # Existing import blocks commonly end with a trailing comma. Remove only\n    # that final delimiter before appending the new symbol so we never create\n    # an invalid `,,` token.\n    body = body.rstrip()\n    if body.endswith(','):\n        body = body[:-1].rstrip()\n    body = body + ',\\n  createSavedCloudflareARecord,\\n'\n    repl = 'import {' + body + '} from \"./cloudflare-integration.js\";'\n"""
if old not in s:
    raise SystemExit('PATCH ERROR: v1 Cloudflare import appender not found')
s = s.replace(old, new, 1)
p.write_text(s)
PY

grep -q "if body.endswith(',')" "$TMP" || fail "import comma correction was not written"
echo "PASS"

echo "[3/5] Replace fragile AWS Chime insertion anchor"
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
  || fail "corrected AWS anchor was not written"
if grep -q "anchor2 = '    server.registerTool" "$TMP"; then
  fail "fragile v1 AWS anchor still present"
fi
echo "PASS"

echo "[4/5] Validate corrected installer"
bash -n "$TMP"
# Ensure the known bad import-construction expression is gone.
if grep -Fq "body = body.rstrip() + ',\\n  createSavedCloudflareARecord,\\n'" "$TMP"; then
  fail "fragile import appender still present"
fi
echo "PASS: corrected installer syntax valid"

echo "[5/5] Run corrected Phase 2A installer"
chmod 700 "$TMP"
bash "$TMP"

echo
echo "PASS: Cloudflare Phase 2A v3 wrapper completed."
echo "If the inner installer reports all eight steps PASS, reconnect/start a fresh Claude MCP session so the new tools are discovered."
