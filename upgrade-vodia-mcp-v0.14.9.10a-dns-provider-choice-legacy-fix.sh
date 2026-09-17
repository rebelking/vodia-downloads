#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.10a — legacy provider-choice registration cleanup wrapper
#
# Why this exists:
#   Some v0.14.9.9-era installs already contain the earlier Phase 2E
#   get_tenant_dns_provider_choices registration. The v0.14.9.10 installer adds
#   the replacement registration, so its staged validator correctly detected two
#   registrations and stopped before installation.
#
# This wrapper safely removes ONLY the older registration from the on-disk source,
# validates JavaScript syntax, then runs the original v0.14.9.10 installer. The
# currently running service is not restarted until the normal installer reaches
# its activation step. If anything fails, the wrapper restores the exact starting
# index.js/version.js and restarts the service.

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.10a-legacy-cleanup-$STAMP"
INSTALLER="/root/upgrade-vodia-mcp-v0.14.9.10-dns-provider-choice.sh"
INSTALLER_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.10-dns-provider-choice.sh"

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "v0.14.9.10a failed; restoring exact pre-wrapper files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  echo "Restored backup: $BACKUP_DIR"
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node wget systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.10a — legacy DNS-provider registration cleanup ==="

echo "[1/6] Backup exact current state"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"
trap rollback ERR

echo "[2/6] Inspect existing provider-choice registrations"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
count=len(re.findall(r'server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']',s,re.S))
print(f'Existing get_tenant_dns_provider_choices registrations: {count}')
if count > 1:
    raise SystemExit('FAIL: live source already has more than one provider-choice registration; refusing automatic cleanup')
PY

echo "[3/6] Remove legacy registration only when present"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()

legacy=re.search(r'(?m)^[ \t]*server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']',s)
if not legacy:
    print('PASS: no legacy registration present; nothing to remove')
    raise SystemExit(0)

# The earlier Phase 2E registration was inserted directly before the combined
# Cloudflare planner. Use that known neighboring tool as a hard boundary, and
# refuse the edit if another tool registration appears inside the candidate span.
combined=re.search(r'(?m)^[ \t]*server\.registerTool\(\s*["\']plan_create_tenant_with_dns["\']',s[legacy.start():])
if not combined:
    raise SystemExit('FAIL: could not find plan_create_tenant_with_dns after the legacy registration')
end=legacy.start()+combined.start()
segment=s[legacy.start():end]
registrations=len(re.findall(r'server\.registerTool\(',segment))
if registrations != 1:
    raise SystemExit(f'FAIL: cleanup boundary contains {registrations} tool registrations; expected exactly 1')
if 'get_tenant_dns_provider_choices' not in segment:
    raise SystemExit('FAIL: cleanup boundary sanity check failed')

# Preserve indentation/newline immediately before the next tool.
s=s[:legacy.start()] + s[end:]
p.write_text(s)
print('PASS: removed exactly one legacy get_tenant_dns_provider_choices registration')
PY
node --check "$INDEX" >/dev/null
echo "PASS: index.js syntax remains valid"

echo "[4/6] Fetch clean v0.14.9.10 installer"
wget -q -O "$INSTALLER" "$INSTALLER_URL"
chmod +x "$INSTALLER"
bash -n "$INSTALLER"
echo "PASS: installer syntax valid"

echo "[5/6] Run v0.14.9.10 installer"
"$INSTALLER"

echo "[6/6] Verify exactly one provider-choice registration and healthy version"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
count=len(re.findall(r'server\.registerTool\(\s*["\']get_tenant_dns_provider_choices["\']',s,re.S))
if count != 1:
    raise SystemExit(f'FAIL: final provider-choice registration count={count}, expected 1')
print('PASS: exactly one get_tenant_dns_provider_choices registration is installed')
PY
curl -fsS http://127.0.0.1:3100/health | grep -q '"version":"0.14.9.10"'
echo "PASS: v0.14.9.10 healthy"
echo "PASS: legacy duplicate-registration condition fixed"
echo "Backup retained: $BACKUP_DIR"
trap - ERR
