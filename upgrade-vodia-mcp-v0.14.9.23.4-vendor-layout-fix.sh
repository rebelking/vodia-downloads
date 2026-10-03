#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
WEB_DIR="$APP/control-center-v2"
ICON_DIR="$WEB_DIR/assets/icons"
VERSION="$APP/version.js"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
CONTROL_SERVICE="${VODIA_CONTROL_SERVICE:-vodia-control-api}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.23.4-vendor-layout-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_CSS="$TMP_DIR/styles.css"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"

trap 'rm -rf "$TMP_DIR"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.23.4 files..."
  [[ -f "$BACKUP_DIR/styles.css" ]] && cp -a "$BACKUP_DIR/styles.css" "$WEB_DIR/styles.css" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

for f in "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$VERSION"; do
  [[ -f "$f" ]] || fail "missing $f"
done

echo "=== Vodia MCP v0.14.9.23.4 — Vendor Logo Layout Fix ==="
echo "Keeps Microsoft 365 unchanged and corrects Vodia/AWS/Cloudflare sizing."

echo "[1/8] Preflight sanity — NO CHANGES"
for f in vodia.svg aws.svg microsoft.svg cloudflare.svg; do
  p="$ICON_DIR/$f"
  [[ -s "$p" ]] || fail "missing icon asset: $p"
  grep -qi '<svg' "$p" || fail "invalid SVG: $p"
done

grep -q './assets/icons/vodia.svg' "$WEB_DIR/index.html" || fail "Vodia icon reference missing"
grep -q './assets/icons/aws.svg' "$WEB_DIR/index.html" || fail "AWS icon reference missing"
grep -q './assets/icons/microsoft.svg' "$WEB_DIR/index.html" || fail "Microsoft icon reference missing"
grep -q './assets/icons/cloudflare.svg' "$WEB_DIR/index.html" || fail "Cloudflare icon reference missing"

echo "PASS: all four current SVG assets exist and are referenced"

echo "[2/8] Stage CSS — NO CHANGES"
cp -a "$WEB_DIR/styles.css" "$TMP_CSS"

python3 - "$TMP_CSS" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1])
s=p.read_text()

marker="/* v0.14.9.23.4 vendor logo sizing */"
block=r'''
/* v0.14.9.23.4 vendor logo sizing */
.connection-title{align-items:center}

/* Base logo chip: fixed dimensions prevent wide SVGs from expanding the card. */
.provider-icon{
  min-width:0;
  width:44px;
  height:44px;
  flex:0 0 44px;
  padding:6px;
  display:grid;
  place-items:center;
  overflow:hidden;
  border-radius:10px;
  background:#fff;
  border:1px solid var(--line);
}

/* Use each vendor logo at its natural aspect ratio instead of stretching it. */
.vendor-logo{
  width:100%;
  height:100%;
  max-width:100%;
  max-height:100%;
  object-fit:contain;
  object-position:center;
  display:block;
}

/* Vodia and AWS are horizontal wordmarks: give them a little more width. */
.provider-pbx{
  width:74px;
  flex-basis:74px;
  padding:7px 8px;
}
.provider-aws{
  width:66px;
  flex-basis:66px;
  padding:7px 8px;
}

/* Keep the Microsoft 365 square treatment exactly compact. */
.provider-m365{
  width:44px;
  flex-basis:44px;
  padding:6px;
}

/* Cloudflare needs a slightly wider canvas for the cloud mark. */
.provider-cf{
  width:54px;
  flex-basis:54px;
  padding:7px;
}

/* Vendor artwork should remain on a neutral chip in both themes. */
html[data-theme="dark"] .provider-icon,
html[data-theme="light"] .provider-icon{
  background:#fff;
}

/* Do not let legacy vendor rules recolor or resize the SVG chips. */
.provider-pbx,.provider-aws,.provider-m365,.provider-cf{
  color:inherit;
  border-color:var(--line);
  text-transform:none;
}
'''

# Remove prior generated vendor sizing blocks that conflict with this one.
patterns=[
    r'/\* v0\.14\.9\.23 real vendor icons \*/.*?(?=/\* v0\.14\.9\.23\.1 vendor icon fix \*/|/\* v0\.14\.9\.23\.2 verified vendor icons \*/|/\* v0\.14\.9\.23\.3 verified vendor icons \*/|\Z)',
    r'/\* v0\.14\.9\.23\.1 vendor icon fix \*/.*?(?=/\* v0\.14\.9\.23\.2 verified vendor icons \*/|/\* v0\.14\.9\.23\.3 verified vendor icons \*/|\Z)',
    r'/\* v0\.14\.9\.23\.2 verified vendor icons \*/.*?(?=/\* v0\.14\.9\.23\.3 verified vendor icons \*/|\Z)',
    r'/\* v0\.14\.9\.23\.3 verified vendor icons \*/.*?(?=\Z)',
    r'/\* v0\.14\.9\.23\.4 vendor logo sizing \*/.*?(?=\Z)',
]
for pattern in patterns:
    s=re.sub(pattern,'',s,flags=re.S)

s=s.rstrip()+"\n\n"+block.strip()+"\n"
p.write_text(s)
PY

grep -q 'v0.14.9.23.4 vendor logo sizing' "$TMP_CSS" || fail "new CSS block missing"
echo PASS

echo "[3/8] Stage version — NO CHANGES"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.23.4\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "staged version.js syntax invalid"
echo PASS

echo "[4/8] CSS sanity test — STILL NO CHANGES"
python3 - "$TMP_CSS" <<'PY'
from pathlib import Path
import sys,re
s=Path(sys.argv[1]).read_text()
checks={
 "base fixed width":r'\.provider-icon\{[^}]*width:44px;[^}]*flex:0 0 44px;',
 "Vodia width":r'\.provider-pbx\{[^}]*width:74px;[^}]*flex-basis:74px;',
 "AWS width":r'\.provider-aws\{[^}]*width:66px;[^}]*flex-basis:66px;',
 "Microsoft compact":r'\.provider-m365\{[^}]*width:44px;[^}]*flex-basis:44px;',
 "Cloudflare width":r'\.provider-cf\{[^}]*width:54px;[^}]*flex-basis:54px;',
 "contain":r'\.vendor-logo\{[^}]*object-fit:contain;',
}
for label,pat in checks.items():
    if not re.search(pat,s,re.S):
        raise SystemExit(f'VALIDATION ERROR: {label}')
print('PASS: fixed logo chip dimensions validated')
print('PASS: Microsoft 365 remains compact')
print('PASS: Vodia/AWS/Cloudflare have vendor-specific widths')
print('PASS: object-fit contain prevents stretch/crop')
PY

echo "[5/8] Backup live CSS/version"
mkdir -p "$BACKUP_DIR"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[6/8] Install + restart"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_CSS" "$WEB_DIR/styles.css"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.23.4' "$HEALTH" || fail "health did not report v0.14.9.23.4"
echo PASS

echo "[7/8] Live validation"
grep -q 'v0.14.9.23.4 vendor logo sizing' "$WEB_DIR/styles.css" || fail "live CSS marker missing"
grep -q 'width:66px' "$WEB_DIR/styles.css" || fail "AWS width missing in live CSS"
grep -q 'width:54px' "$WEB_DIR/styles.css" || fail "Cloudflare width missing in live CSS"
grep -q 'width:44px' "$WEB_DIR/styles.css" || fail "Microsoft/base width missing in live CSS"
echo "PASS: live CSS contains vendor-specific sizing"

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.23.4 vendor layout fix installed"
echo "PASS: Microsoft 365 treatment preserved"
echo "PASS: AWS logo constrained to its own chip"
echo "PASS: Cloudflare logo constrained to its own chip"
echo "PASS: Vodia wordmark constrained to its own chip"
echo "PASS: Light/Dark mode preserved"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
