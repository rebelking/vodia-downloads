#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
SERVICE=vodia-mcp
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.2-country-code-coercion-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
echo "=== Vodia MCP v0.14.9.2 — Country Code Coercion ==="
echo "[1/6] Preflight"
for file in "$INDEX" "$VERSION"; do test -f "$file" || fail "missing $file"; done
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'v0.14.9.1 tenant country-code + DNS validation' "$INDEX" || fail "v0.14.9.1 tenant-country prerequisite missing"
grep -q 'country_code: z.string().regex' "$INDEX" || fail "expected v0.14.9.1 country string schema missing"
if grep -q 'v0.14.9.2 country-code coercion' "$INDEX"; then fail "v0.14.9.2 patch already installed"; fi
echo PASS

echo "[2/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"

echo "[3/6] Patch input schemas"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='country_code: z.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN,'
replacement='country_code: z.coerce.string().regex(VODIA_TENANT_COUNTRY_CODE_PATTERN,'
count=s.count(needle)
if count != 2: raise SystemExit(f"PATCH ERROR: expected two country schemas; found {count}")
s=s.replace(needle,replacement)
anchor='// v0.14.9.1 tenant country-code + DNS validation.\n'
if s.count(anchor) != 1: raise SystemExit('PATCH ERROR: country-code marker missing or ambiguous')
s=s.replace(anchor,anchor+'// v0.14.9.2 country-code coercion accepts numeric MCP inputs as digit strings.\n',1)
p.write_text(s)
PY
echo PASS

echo "[4/6] Patch version + validate"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.2\2',s,count=1)
if n == s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
grep -q 'country_code: z.coerce.string().regex' "$TMP_INDEX" || fail "coercing schema missing"
echo PASS
if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then echo "PATCH-ONLY PASS: nothing installed or restarted"; exit 0; fi

echo "[5/6] Install + restart"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"
  systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; systemctl restart "$SERVICE" || true; fail "service unhealthy; backup restored"; }
echo PASS

echo "[6/6] Verify"
grep -n 'country_code: z.coerce.string().regex' "$INDEX"
grep -n '0.14.9.2' "$VERSION"
echo "=== v0.14.9.2 INSTALL PASS ==="
echo "Backup: $BACKUP_DIR"
echo "PBX writes performed by installer: 0"
