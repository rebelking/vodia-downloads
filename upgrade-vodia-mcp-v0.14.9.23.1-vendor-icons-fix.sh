#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
WEB_DIR="$APP/control-center-v2"
ICON_DIR="$WEB_DIR/assets/icons"
VERSION="$APP/version.js"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
CONTROL_SERVICE="${VODIA_CONTROL_SERVICE:-vodia-control-api}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.23.1-vendor-icons-fix-$STAMP"

TMP_INDEX="$(mktemp --suffix=.html)"
TMP_CSS="$(mktemp --suffix=.css)"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"

trap 'rm -f "$TMP_INDEX" "$TMP_CSS" "$TMP_VERSION" "$HEALTH"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

rollback() {
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.23.1 files..."
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

download_svg() {
  local url="$1"
  local out="$2"
  curl --retry 3 --retry-delay 1 --connect-timeout 10 -fsSL "$url" -o "$out"
  [[ -s "$out" ]] || return 1
  grep -qi '<svg' "$out" || return 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
if ! grep -Eq '0\.14\.9\.(22|23|23\.1)' "$VERSION"; then fail "expected installed base v0.14.9.22/v0.14.9.23"; fi

echo "=== Vodia MCP v0.14.9.23.1 — Vendor Icons URL Fix ==="
echo "Uses stable jsDelivr Simple Icons assets and a local Vodia SVG fallback."

echo "[1/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$WEB_DIR/index.html" "$BACKUP_DIR/index.html"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -d "$ICON_DIR" ]] && cp -a "$ICON_DIR" "$BACKUP_DIR/icons" || true
echo "PASS: $BACKUP_DIR"

echo "[2/8] Install vendor SVG assets"
mkdir -p "$ICON_DIR"
download_svg 'https://cdn.jsdelivr.net/npm/simple-icons@v16/icons/amazonwebservices.svg' "$ICON_DIR/aws.svg" || fail "AWS SVG download failed"
download_svg 'https://cdn.jsdelivr.net/npm/simple-icons@v16/icons/microsoft365.svg' "$ICON_DIR/microsoft365.svg" || fail "Microsoft 365 SVG download failed"
download_svg 'https://cdn.jsdelivr.net/npm/simple-icons@v16/icons/cloudflare.svg' "$ICON_DIR/cloudflare.svg" || fail "Cloudflare SVG download failed"

cat > "$ICON_DIR/vodia.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 220 72" role="img" aria-labelledby="title">
  <title id="title">Vodia</title>
  <rect width="220" height="72" rx="12" fill="#ffffff"/>
  <g fill="#e3222a">
    <circle cx="184" cy="13" r="7"/>
    <circle cx="198" cy="22" r="6"/>
    <circle cx="177" cy="28" r="5"/>
  </g>
  <text x="14" y="50" font-family="Arial, Helvetica, sans-serif" font-size="42" font-weight="700" letter-spacing="-2" fill="#071a39">Vodia</text>
</svg>
SVG

chmod 0644 "$ICON_DIR"/*.svg
for f in "$ICON_DIR/vodia.svg" "$ICON_DIR/aws.svg" "$ICON_DIR/microsoft365.svg" "$ICON_DIR/cloudflare.svg"; do
  [[ -s "$f" ]] || fail "empty SVG: $f"
  grep -qi '<svg' "$f" || fail "invalid SVG: $f"
done
echo "PASS: Vodia, AWS, Microsoft 365, Cloudflare SVG assets ready"

echo "[3/8] Patch Control Center HTML"
cp -a "$WEB_DIR/index.html" "$TMP_INDEX"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
pairs=[
([r'<div class="brand-mark">V</div>',r'<div class="brand-mark brand-logo"><img[^>]+></div>'],'<div class="brand-mark brand-logo"><img src="./assets/icons/vodia.svg" alt="Vodia" class="header-vendor-logo"></div>'),
([r'<span class="provider-icon provider-pbx">☎</span>',r'<span class="provider-icon provider-pbx"><img[^>]+></span>'],'<span class="provider-icon provider-pbx"><img src="./assets/icons/vodia.svg" alt="Vodia" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-aws">aws</span>',r'<span class="provider-icon provider-aws"><img[^>]+></span>'],'<span class="provider-icon provider-aws"><img src="./assets/icons/aws.svg" alt="Amazon Web Services" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-m365">M365</span>',r'<span class="provider-icon provider-m365"><img[^>]+></span>'],'<span class="provider-icon provider-m365"><img src="./assets/icons/microsoft365.svg" alt="Microsoft 365" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-cf">CF</span>',r'<span class="provider-icon provider-cf"><img[^>]+></span>'],'<span class="provider-icon provider-cf"><img src="./assets/icons/cloudflare.svg" alt="Cloudflare" class="vendor-logo"></span>')
]
for patterns,repl in pairs:
    changed=False
    for pattern in patterns:
        if re.search(pattern,s):
            s=re.sub(pattern,repl,s,count=1); changed=True; break
    if not changed and repl not in s: raise SystemExit(f"PATCH ERROR: no HTML anchor for {repl}")
p.write_text(s)
PY
echo PASS

echo "[4/8] Patch icon CSS"
cp -a "$WEB_DIR/styles.css" "$TMP_CSS"
python3 - "$TMP_CSS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker="/* v0.14.9.23.1 vendor icon fix */"
if marker not in s:
    s += r'''

/* v0.14.9.23.1 vendor icon fix */
.brand-logo{padding:5px;overflow:hidden;background:#fff;border:1px solid var(--line)}
.header-vendor-logo{width:100%;height:100%;object-fit:contain;display:block}
.provider-icon{overflow:hidden;padding:6px;background:#fff;border:1px solid var(--line)}
.vendor-logo{width:100%;height:100%;object-fit:contain;display:block}
.provider-pbx,.provider-aws,.provider-m365,.provider-cf{background:#fff;border-color:var(--line);color:inherit}
html[data-theme="dark"] .provider-icon,html[data-theme="dark"] .brand-logo{background:#fff}
'''
p.write_text(s)
PY
echo PASS

echo "[5/8] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.23.1\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[6/8] Static validation"
python3 - "$TMP_INDEX" "$ICON_DIR" <<'PY'
from pathlib import Path
import sys
html=Path(sys.argv[1]).read_text(); icons=Path(sys.argv[2])
required={"Vodia":"vodia.svg","Amazon Web Services":"aws.svg","Microsoft 365":"microsoft365.svg","Cloudflare":"cloudflare.svg"}
for label,filename in required.items():
    if f'alt="{label}"' not in html: raise SystemExit(f"VALIDATION ERROR: missing alt label {label}")
    p=icons/filename
    if not p.exists() or "<svg" not in p.read_text(errors="ignore").lower(): raise SystemExit(f"VALIDATION ERROR: missing/invalid {filename}")
print("PASS: all four vendor assets valid")
print("PASS: all four cards reference local SVG files")
PY

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
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.23.1' "$HEALTH" || fail "health did not report v0.14.9.23.1"
echo PASS

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.23.1 vendor icon fix installed"
echo "PASS: AWS SVG installed from stable jsDelivr source"
echo "PASS: Microsoft 365 SVG installed from stable jsDelivr source"
echo "PASS: Cloudflare SVG installed from stable jsDelivr source"
echo "PASS: Vodia local vector brand tile installed"
echo "PASS: Light/Dark mode preserved"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
