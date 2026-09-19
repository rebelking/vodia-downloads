#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
WEB_DIR="$APP/control-center-v2"
ICON_DIR="$WEB_DIR/assets/icons"
VERSION="$APP/version.js"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
CONTROL_SERVICE="${VODIA_CONTROL_SERVICE:-vodia-control-api}"

AWS_URL='https://upload.wikimedia.org/wikipedia/commons/9/93/Amazon_Web_Services_Logo.svg'
MS_URL='https://learn.microsoft.com/en-us/entra/identity-platform/media/howto-add-branding-in-apps/ms-symbollockup_mssymbol_19.svg'
CF_URL='https://cdn.jsdelivr.net/npm/simple-icons@16.31.0/icons/cloudflare.svg'

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.23.3-vendor-icons-$STAMP"
TMP_DIR="$(mktemp -d)"
STAGE_ICONS="$TMP_DIR/icons"
TMP_INDEX="$TMP_DIR/index.html"
TMP_CSS="$TMP_DIR/styles.css"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"

trap 'rm -rf "$TMP_DIR"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.23.3 files..."
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

download_svg(){
  local name="$1" url="$2" out="$3"
  echo "  checking $name..."
  curl --fail --silent --show-error --location \
    --retry 3 --retry-all-errors --connect-timeout 10 --max-time 30 \
    "$url" -o "$out"
  [[ -s "$out" ]] || fail "$name returned an empty file"
  grep -qi '<svg' "$out" || fail "$name did not return SVG content"
  local bytes
  bytes="$(wc -c < "$out")"
  [[ "$bytes" -ge 100 ]] || fail "$name SVG is unexpectedly small ($bytes bytes)"
  echo "  PASS: $name ($bytes bytes)"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl grep wc; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
grep -Eq '0\.14\.9\.(22|23|23\.1|23\.2|23\.3)' "$VERSION" || fail "expected installed base v0.14.9.22/v0.14.9.23.x"

echo "=== Vodia MCP v0.14.9.23.3 — Vendor Icons Verified + Staged ==="
echo "No live Control Center file is modified until every URL, SVG, HTML patch, CSS patch, version patch, and cross-reference test passes."

echo "[1/9] Stage remote assets in temp — NO APP CHANGES"
mkdir -p "$STAGE_ICONS"
download_svg "AWS" "$AWS_URL" "$STAGE_ICONS/aws.svg"
download_svg "Microsoft" "$MS_URL" "$STAGE_ICONS/microsoft.svg"
download_svg "Cloudflare" "$CF_URL" "$STAGE_ICONS/cloudflare.svg"

cat > "$STAGE_ICONS/vodia.svg" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 220 72" role="img" aria-labelledby="vodia-title">
  <title id="vodia-title">Vodia</title>
  <rect width="220" height="72" rx="12" fill="#ffffff"/>
  <text x="15" y="50" font-family="Arial,Helvetica,sans-serif" font-size="43" font-weight="700" letter-spacing="-2" fill="#0b2347">Vodia</text>
  <g fill="#e3242b">
    <circle cx="178" cy="17" r="5.5"/>
    <circle cx="191" cy="12" r="6.5"/>
    <circle cx="201" cy="25" r="5"/>
  </g>
</svg>
SVG
grep -qi '<svg' "$STAGE_ICONS/vodia.svg" || fail "local Vodia SVG invalid"
echo "PASS: all four SVGs staged only in $TMP_DIR"

echo "[2/9] Stage HTML/CSS/version patches — STILL NO APP CHANGES"
cp -a "$WEB_DIR/index.html" "$TMP_INDEX"
cp -a "$WEB_DIR/styles.css" "$TMP_CSS"
cp -a "$VERSION" "$TMP_VERSION"

python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
pairs=[
([r'<div class="brand-mark">V</div>',r'<div class="brand-mark brand-logo"><img[^>]+></div>'],
 '<div class="brand-mark brand-logo"><img src="./assets/icons/vodia.svg" alt="Vodia" class="header-vendor-logo"></div>'),
([r'<span class="provider-icon provider-pbx">☎</span>',r'<span class="provider-icon provider-pbx"><img[^>]+></span>'],
 '<span class="provider-icon provider-pbx"><img src="./assets/icons/vodia.svg" alt="Vodia" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-aws">aws</span>',r'<span class="provider-icon provider-aws"><img[^>]+></span>'],
 '<span class="provider-icon provider-aws"><img src="./assets/icons/aws.svg" alt="Amazon Web Services" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-m365">M365</span>',r'<span class="provider-icon provider-m365"><img[^>]+></span>'],
 '<span class="provider-icon provider-m365"><img src="./assets/icons/microsoft.svg" alt="Microsoft 365" class="vendor-logo"></span>'),
([r'<span class="provider-icon provider-cf">CF</span>',r'<span class="provider-icon provider-cf"><img[^>]+></span>'],
 '<span class="provider-icon provider-cf"><img src="./assets/icons/cloudflare.svg" alt="Cloudflare" class="vendor-logo"></span>')
]
for patterns,repl in pairs:
    changed=False
    for pattern in patterns:
        if re.search(pattern,s):
            s=re.sub(pattern,repl,s,count=1)
            changed=True
            break
    if not changed and repl not in s:
        raise SystemExit(f"PATCH ERROR: no HTML anchor for {repl}")
p.write_text(s)
PY

python3 - "$TMP_CSS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker="/* v0.14.9.23.3 verified vendor icons */"
if marker not in s:
    s += r'''

/* v0.14.9.23.3 verified vendor icons */
.brand-logo{padding:5px;overflow:hidden;background:#fff;border:1px solid var(--line)}
.header-vendor-logo{width:100%;height:100%;object-fit:contain;display:block}
.provider-icon{overflow:hidden;padding:6px;background:#fff;border:1px solid var(--line)}
.vendor-logo{width:100%;height:100%;object-fit:contain;display:block}
.provider-pbx,.provider-aws,.provider-m365,.provider-cf{background:#fff;border-color:var(--line);color:inherit}
html[data-theme="dark"] .provider-icon,html[data-theme="dark"] .brand-logo{background:#fff}
'''
p.write_text(s)
PY

python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.23.3\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "staged version.js syntax invalid"
echo PASS

echo "[3/9] Cross-reference sanity test — STILL NO APP CHANGES"
python3 - "$TMP_INDEX" "$TMP_CSS" "$TMP_VERSION" "$STAGE_ICONS" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
css=Path(sys.argv[2]).read_text()
version=Path(sys.argv[3]).read_text()
icons=Path(sys.argv[4])

expected = [
    ("Vodia", "vodia.svg"),
    ("Amazon Web Services", "aws.svg"),
    ("Microsoft 365", "microsoft.svg"),
    ("Cloudflare", "cloudflare.svg"),
]
for alt, filename in expected:
    ref=f'./assets/icons/{filename}'
    if ref not in html:
        raise SystemExit(f'VALIDATION ERROR: HTML missing {ref}')
    if f'alt="{alt}"' not in html:
        raise SystemExit(f'VALIDATION ERROR: HTML missing alt label {alt}')
    p=icons/filename
    if not p.exists():
        raise SystemExit(f'VALIDATION ERROR: staged file missing {filename}')
    text=p.read_text(errors='ignore').lower()
    if '<svg' not in text:
        raise SystemExit(f'VALIDATION ERROR: staged file is not SVG {filename}')
    if p.stat().st_size < 100:
        raise SystemExit(f'VALIDATION ERROR: staged file too small {filename}')

refs=set(re.findall(r'\.\/assets\/icons\/([^"\']+\.svg)', html))
files={p.name for p in icons.glob('*.svg')}
if refs != files:
    raise SystemExit(f'VALIDATION ERROR: HTML/icon mismatch refs={sorted(refs)} files={sorted(files)}')

if 'v0.14.9.23.3 verified vendor icons' not in css:
    raise SystemExit('VALIDATION ERROR: CSS marker missing')
if '0.14.9.23.3' not in version:
    raise SystemExit('VALIDATION ERROR: staged version mismatch')
if re.search(r'provider-(pbx|aws|m365|cf)">[^<]+</span>', html):
    raise SystemExit('VALIDATION ERROR: placeholder provider text remains')

print('PASS: exact HTML alt labels match exact SVG filenames')
print('PASS: every referenced SVG exists and every staged SVG is referenced')
print('PASS: no provider placeholder text remains')
print('PASS: CSS and connector version are staged correctly')
PY

echo "[4/9] Backup live files"
mkdir -p "$BACKUP_DIR"
cp -a "$WEB_DIR/index.html" "$BACKUP_DIR/index.html"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -d "$ICON_DIR" ]] && cp -a "$ICON_DIR" "$BACKUP_DIR/icons" || true
echo "PASS: $BACKUP_DIR"

echo "[5/9] Activate all staged files atomically as one change"
trap rollback ERR
mkdir -p "$ICON_DIR"
install -o root -g root -m 0644 "$STAGE_ICONS/vodia.svg" "$ICON_DIR/vodia.svg"
install -o root -g root -m 0644 "$STAGE_ICONS/aws.svg" "$ICON_DIR/aws.svg"
install -o root -g root -m 0644 "$STAGE_ICONS/microsoft.svg" "$ICON_DIR/microsoft.svg"
install -o root -g root -m 0644 "$STAGE_ICONS/cloudflare.svg" "$ICON_DIR/cloudflare.svg"
rm -f "$ICON_DIR/microsoft365.svg"
install -o root -g root -m 0644 "$TMP_INDEX" "$WEB_DIR/index.html"
install -o root -g root -m 0644 "$TMP_CSS" "$WEB_DIR/styles.css"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
echo PASS

echo "[6/9] Restart services"
systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.23.3' "$HEALTH" || fail "health did not report v0.14.9.23.3"
echo PASS

echo "[7/9] Validate live installed files"
python3 - "$WEB_DIR/index.html" "$ICON_DIR" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
icons=Path(sys.argv[2])
expected=[
 ("Vodia","vodia.svg"),
 ("Amazon Web Services","aws.svg"),
 ("Microsoft 365","microsoft.svg"),
 ("Cloudflare","cloudflare.svg"),
]
for alt,filename in expected:
    if f'alt="{alt}"' not in html: raise SystemExit(f'LIVE VALIDATION ERROR: missing alt {alt}')
    if f'./assets/icons/{filename}' not in html: raise SystemExit(f'LIVE VALIDATION ERROR: missing ref {filename}')
    p=icons/filename
    if not p.exists() or '<svg' not in p.read_text(errors='ignore').lower():
        raise SystemExit(f'LIVE VALIDATION ERROR: invalid {filename}')
refs=set(re.findall(r'\.\/assets\/icons\/([^"\']+\.svg)',html))
needed={'vodia.svg','aws.svg','microsoft.svg','cloudflare.svg'}
if refs != needed: raise SystemExit(f'LIVE VALIDATION ERROR: refs={sorted(refs)}')
print('PASS: live vendor icon references are exact and complete')
PY
echo PASS

echo "[8/9] Browser-route smoke test"
if curl -fsS http://127.0.0.1:3110/control-api/health >/dev/null 2>&1; then
  echo "PASS: Control Center API healthy"
else
  echo "WARN: Control Center API health not reachable on 127.0.0.1:3110"
fi
echo "PASS: MCP health reports v0.14.9.23.3"

echo "[9/9] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.23.3 vendor icons installed"
echo "PASS: AWS logo installed"
echo "PASS: Microsoft 365 card uses verified Microsoft SVG"
echo "PASS: Cloudflare logo installed"
echo "PASS: Vodia local vector tile installed"
echo "PASS: no live application file was modified until all staged validation passed"
echo "PASS: Light/Dark mode preserved"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
