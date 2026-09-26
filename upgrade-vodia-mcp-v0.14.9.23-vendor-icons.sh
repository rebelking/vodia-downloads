#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
WEB_DIR="$APP/control-center-v2"
ICON_DIR="$WEB_DIR/assets/icons"
VERSION="$APP/version.js"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
CONTROL_SERVICE="${VODIA_CONTROL_SERVICE:-vodia-control-api}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.23-vendor-icons-$STAMP"
TMP_INDEX="$(mktemp --suffix=.html)"
TMP_CSS="$(mktemp --suffix=.css)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_CSS" "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.23 files..."
  [[ -f "$BACKUP_DIR/index.html" ]] && cp -a "$BACKUP_DIR/index.html" "$WEB_DIR/index.html" || true
  [[ -f "$BACKUP_DIR/styles.css" ]] && cp -a "$BACKUP_DIR/styles.css" "$WEB_DIR/styles.css" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  if [[ -d "$BACKUP_DIR/icons" ]]; then
    rm -rf "$ICON_DIR"
    mkdir -p "$(dirname "$ICON_DIR")"
    cp -a "$BACKUP_DIR/icons" "$ICON_DIR"
  else
    rm -rf "$ICON_DIR"
  fi
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
grep -q '0.14.9.22' "$VERSION" || fail "expected installed base v0.14.9.22"

echo "=== Vodia MCP v0.14.9.23 — Real Vendor Icons ==="

echo "[1/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$WEB_DIR/index.html" "$BACKUP_DIR/index.html"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -d "$ICON_DIR" ]] && cp -a "$ICON_DIR" "$BACKUP_DIR/icons" || true
echo "PASS: $BACKUP_DIR"

echo "[2/8] Download vendor SVG assets"
mkdir -p "$ICON_DIR"
curl -fsSL 'https://cdn.prod.website-files.com/65698eb840bd54b62e90e134/65698eb840bd54b62e90e1d2_logo2%20%281%29.svg' -o "$ICON_DIR/vodia.svg"
curl -fsSL 'https://cdnjs.cloudflare.com/ajax/libs/simple-icons/14.6.0/amazonwebservices.svg' -o "$ICON_DIR/aws.svg"
curl -fsSL 'https://cdnjs.cloudflare.com/ajax/libs/simple-icons/14.6.0/microsoft365.svg' -o "$ICON_DIR/microsoft365.svg"
curl -fsSL 'https://cdnjs.cloudflare.com/ajax/libs/simple-icons/14.6.0/cloudflare.svg' -o "$ICON_DIR/cloudflare.svg"
chmod 0644 "$ICON_DIR"/*.svg
for f in "$ICON_DIR"/*.svg; do [[ -s "$f" ]] || fail "empty SVG: $f"; grep -qi '<svg' "$f" || fail "not an SVG: $f"; done
echo PASS

echo "[3/8] Patch HTML"
cp -a "$WEB_DIR/index.html" "$TMP_INDEX"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
pairs=[
(r'<div class="brand-mark">V</div>','<div class="brand-mark brand-logo"><img src="./assets/icons/vodia.svg" alt="Vodia" class="header-vendor-logo"></div>'),
(r'<span class="provider-icon provider-pbx">☎</span>','<span class="provider-icon provider-pbx"><img src="./assets/icons/vodia.svg" alt="Vodia" class="vendor-logo"></span>'),
(r'<span class="provider-icon provider-aws">aws</span>','<span class="provider-icon provider-aws"><img src="./assets/icons/aws.svg" alt="Amazon Web Services" class="vendor-logo"></span>'),
(r'<span class="provider-icon provider-m365">M365</span>','<span class="provider-icon provider-m365"><img src="./assets/icons/microsoft365.svg" alt="Microsoft 365" class="vendor-logo"></span>'),
(r'<span class="provider-icon provider-cf">CF</span>','<span class="provider-icon provider-cf"><img src="./assets/icons/cloudflare.svg" alt="Cloudflare" class="vendor-logo"></span>')
]
for pat,repl in pairs:
    if re.search(pat,s): s=re.sub(pat,repl,s,count=1)
    elif repl not in s: raise SystemExit(f'PATCH ERROR: missing HTML anchor {pat}')
p.write_text(s)
PY
echo PASS

echo "[4/8] Patch CSS"
cp -a "$WEB_DIR/styles.css" "$TMP_CSS"
cat >> "$TMP_CSS" <<'CSS'

/* v0.14.9.23 real vendor icons */
.brand-logo{padding:7px;background:var(--surface);border:1px solid var(--line);overflow:hidden}
.header-vendor-logo,.vendor-logo{width:100%;height:100%;object-fit:contain;display:block}
.provider-icon{overflow:hidden;padding:7px;background:var(--surface-2);border:1px solid var(--line)}
.provider-pbx,.provider-aws,.provider-m365,.provider-cf{background:var(--surface-2);border-color:var(--line);color:inherit}
html[data-theme="dark"] .provider-icon,html[data-theme="dark"] .brand-logo{background:#fff}
CSS
echo PASS

echo "[5/8] Patch version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.23\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[6/8] Validate"
for x in vodia.svg aws.svg microsoft365.svg cloudflare.svg; do grep -q "./assets/icons/$x" "$TMP_INDEX" || fail "missing icon ref $x"; done
grep -q 'v0.14.9.23 real vendor icons' "$TMP_CSS" || fail "vendor CSS missing"
echo PASS

echo "[7/8] Install + restart"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_INDEX" "$WEB_DIR/index.html"
install -o root -g root -m 0644 "$TMP_CSS" "$WEB_DIR/styles.css"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed"
grep -q '0.14.9.23' "$HEALTH" || fail "health did not report v0.14.9.23"
echo PASS

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.23 real vendor icons installed"
echo "PASS: Vodia, AWS, Microsoft 365, and Cloudflare SVG logos installed"
echo "PASS: Light/Dark mode preserved"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
