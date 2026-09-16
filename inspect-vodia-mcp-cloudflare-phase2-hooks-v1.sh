#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
CF="$APP/cloudflare-integration.js"
SERVICE="vodia-mcp"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "Run as root: sudo bash $0"
[[ -f "$INDEX" ]] || fail "Missing $INDEX"
[[ -f "$CF" ]] || fail "Missing $CF"

printf '%s\n' "=== Vodia MCP Cloudflare Phase 2 hook inspector v1 ==="
printf '%s\n' "READ ONLY: no files, DNS records, PBX tenants, credentials, or services are modified."
printf '%s\n' "Secrets are not printed."
echo

echo "[1/8] Runtime"
printf 'service: '
systemctl is-active "$SERVICE" || true
printf 'mcp version: '
node -p "require('$APP/package.json').version" 2>/dev/null || echo unknown
printf 'node: '
node --version

echo

echo "[2/8] Cloudflare integration exports"
grep -nE '^export (async )?function |^export const |^export class ' "$CF" \
  | sed -E 's/(apiToken|token|secret|authorization|password)[^,)]*/\1=[REDACTED]/Ig' \
  || true

echo

echo "[3/8] Cloudflare imports + Phase 1 tool locations in index.js"
grep -nE 'cloudflare-integration\.js|Cloudflare DNS|cloudflare_(check_connection|get_zone|list_dns_records|get_dns_record|plan_|apply_|verify_)' "$INDEX" \
  | head -n 120 || true

echo

echo "[4/8] Server factory + helper boundaries"
grep -nE 'function createVodiaServer|const createVodiaServer|function registerPbXReadTool|registerPbXReadTool\(|Microsoft 365 / Entra / Graph|server\.registerTool\(' "$INDEX" \
  | head -n 140 || true

echo

echo "[5/8] Existing guarded-write / plan-apply patterns"
grep -nEi 'apply_vodia_change|plan_[a-z0-9_]+|confirmation|planId|plan_id|expires|single-use|single use|write plan|approval|accessMode|mcp:approve|mcp:admin' "$INDEX" \
  | head -n 220 || true

echo

echo "[6/8] Exact snippets around apply_vodia_change and tenant planner"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re, sys
p = Path(sys.argv[1])
lines = p.read_text(errors='replace').splitlines()
needles = [
    '"apply_vodia_change"',
    'apply_vodia_change',
    'CREATE VODIA TENANT',
    'plan_create_tenant',
    'plan_create_domain',
]
seen=[]
for needle in needles:
    for i,line in enumerate(lines):
        if needle in line:
            lo=max(0,i-18); hi=min(len(lines),i+70)
            key=(lo,hi)
            if key in seen: continue
            seen.append(key)
            print(f'--- {needle} around line {i+1} ---')
            for n in range(lo,hi):
                text=lines[n]
                text=re.sub(r'(?i)(token|secret|password|authorization)(\s*[:=]\s*)[^,}\]]+', r'\1\2[REDACTED]', text)
                print(f'{n+1:6d}  {text}')
            print()
            break
PY

echo

echo "[7/8] Exact Cloudflare helper snippets needed for Phase 2"
python3 - "$CF" <<'PY'
from pathlib import Path
import re, sys
lines=Path(sys.argv[1]).read_text(errors='replace').splitlines()
needles=[
 'function db(',
 'function decrypt',
 'async function cloudflare',
 'async function cf(',
 'listSavedCloudflareDnsRecords',
 'checkSavedCloudflareConnection',
 'getCloudflareIntegrationStatus',
]
for needle in needles:
    for i,line in enumerate(lines):
        if needle in line:
            lo=max(0,i-10); hi=min(len(lines),i+55)
            print(f'--- {needle} around line {i+1} ---')
            for n in range(lo,hi):
                text=lines[n]
                text=re.sub(r'(?i)(token|secret|password|authorization)(\s*[:=]\s*)[^,}\]]+', r'\1\2[REDACTED]', text)
                print(f'{n+1:6d}  {text}')
            print()
            break
PY

echo

echo "[8/8] Safety checks"
printf 'Cloudflare Phase 1 read tools count: '
grep -Ec '"cloudflare_(check_connection|get_zone|list_dns_records|get_dns_record)"' "$INDEX" || true
printf 'Existing Cloudflare write-tool references: '
grep -Ec '"cloudflare_(plan_|apply_|verify_|create_|update_|delete_)' "$INDEX" || true
printf 'apply_vodia_change registrations: '
grep -Ec '"apply_vodia_change"' "$INDEX" || true
printf 'createVodiaServer definitions: '
grep -Ec 'function createVodiaServer|const createVodiaServer' "$INDEX" || true
printf 'registerPbXReadTool definitions: '
grep -Ec 'function registerPbXReadTool' "$INDEX" || true

echo
echo "Inspection complete. No changes were made."
