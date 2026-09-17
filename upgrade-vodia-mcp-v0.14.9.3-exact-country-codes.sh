#!/usr/bin/env bash
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"; VERSION="$APP/version.js"; SERVICE=vodia-mcp
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.3-exact-country-codes-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"; TMP_VERSION="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
echo "=== Vodia MCP v0.14.9.3 — Exact Country Codes ==="
echo "[1/6] Preflight"
for file in "$INDEX" "$VERSION"; do test -f "$file" || fail "missing $file"; done
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'v0.14.9.2 country-code coercion' "$INDEX" || fail "v0.14.9.2 prerequisite missing"
grep -q 'country_code: z.coerce.string().regex' "$INDEX" || fail "coercing country schemas missing"
grep -q 'v0.14.9.3 exact ITU country-code allow-list' "$INDEX" && fail "v0.14.9.3 already installed"
echo PASS
echo "[2/6] Backup"
mkdir -p "$BACKUP_DIR"; cp -a "$INDEX" "$BACKUP_DIR/index.js"; cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$INDEX" "$TMP_INDEX"; cp -a "$VERSION" "$TMP_VERSION"
echo "PASS: $BACKUP_DIR"
echo "[3/6] Replace broad country-code pattern"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='const VODIA_TENANT_COUNTRY_CODE_PATTERN = /^(?:1|2[078]|2[1234569]\\d|3[0123469]|3[578]\\d|4[013-9]|42\\d|5[1-8]|5[09]\\d|6[0-6]|6[7-9]\\d|7|8[123469]|8[0578]\\d|9[0123458]|9[679]\\d)$/;'
codes='1|7|20|27|30|31|32|33|34|36|39|40|41|43|44|45|46|47|48|49|51|52|53|54|55|56|57|58|60|61|62|63|64|65|66|81|82|84|86|90|91|92|93|94|95|98|211|212|213|216|218|220|221|222|223|224|225|226|227|228|229|230|231|232|233|234|235|236|237|238|239|240|241|242|243|244|245|246|247|248|249|250|251|252|253|254|255|256|257|258|260|261|262|263|264|265|266|267|268|269|290|291|297|298|299|350|351|352|353|354|355|356|357|358|359|370|371|372|373|374|375|376|377|378|380|381|382|383|385|386|387|389|420|421|423|500|501|502|503|504|505|506|507|508|509|590|591|592|593|594|595|596|597|598|599|670|672|673|674|675|676|677|678|679|680|681|682|683|685|686|687|688|689|690|691|692|850|852|853|855|856|880|886|960|961|962|963|964|965|966|967|968|970|971|972|973|974|975|976|977|992|993|994|995|996|998'
new='// v0.14.9.3 exact ITU country-code allow-list: country and territory calling codes only.\n// International network/service codes (800, 808, 870, 878, 881, 882, 883, 888, 979) are excluded.\nconst VODIA_TENANT_COUNTRY_CODE_PATTERN = /^(?:'+codes+')$/;'
if s.count(old) != 1: raise SystemExit(f'PATCH ERROR: expected one broad country-code pattern; found {s.count(old)}')
for invalid in ('978','210','999','979','800'):
    if invalid in codes.split('|'): raise SystemExit(f'PATCH ERROR: invalid code {invalid} included')
s=s.replace(old,new,1); p.write_text(s)
PY
echo PASS
echo "[4/6] Patch version + validate"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.3\2',s,count=1)
if n == s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
grep -q 'v0.14.9.3 exact ITU country-code allow-list' "$TMP_INDEX" || fail "allow-list marker missing"
echo PASS
if [[ "${VODIA_MCP_PATCH_ONLY:-false}" =~ ^(1|true|yes)$ ]]; then echo "PATCH-ONLY PASS: nothing installed or restarted"; exit 0; fi
echo "[5/6] Install + restart"
cp -a "$TMP_INDEX" "$INDEX"; cp -a "$TMP_VERSION" "$VERSION"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; systemctl restart "$SERVICE" || true; fail "restart failed; backup restored"; fi
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP_DIR/index.js" "$INDEX"; cp -a "$BACKUP_DIR/version.js" "$VERSION"; systemctl restart "$SERVICE" || true; fail "service unhealthy; backup restored"; }
echo PASS
echo "[6/6] Verify"
grep -n -E 'v0\.14\.9\.3 exact ITU|COUNTRY_CODE_PATTERN' "$INDEX" | head -4
grep -n '0.14.9.3' "$VERSION"
echo "=== v0.14.9.3 INSTALL PASS ==="
echo "Backup: $BACKUP_DIR"
echo "PBX writes performed by installer: 0"
