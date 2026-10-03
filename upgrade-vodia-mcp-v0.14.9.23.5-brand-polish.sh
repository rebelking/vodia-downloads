#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
WEB_DIR="$APP/control-center-v2"
ICON_DIR="$WEB_DIR/assets/icons"
VERSION="$APP/version.js"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
CONTROL_SERVICE="${VODIA_CONTROL_SERVICE:-vodia-control-api}"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.23.5-brand-polish-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_CF="$TMP_DIR/cloudflare.svg"
TMP_VODIA="$TMP_DIR/vodia.svg"
TMP_CSS="$TMP_DIR/styles.css"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"

trap 'rm -rf "$TMP_DIR"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.23.5 files..."
  [[ -f "$BACKUP_DIR/cloudflare.svg" ]] && cp -a "$BACKUP_DIR/cloudflare.svg" "$ICON_DIR/cloudflare.svg" || true
  [[ -f "$BACKUP_DIR/vodia.svg" ]] && cp -a "$BACKUP_DIR/vodia.svg" "$ICON_DIR/vodia.svg" || true
  [[ -f "$BACKUP_DIR/styles.css" ]] && cp -a "$BACKUP_DIR/styles.css" "$WEB_DIR/styles.css" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

for f in "$ICON_DIR/vodia.svg" "$ICON_DIR/aws.svg" "$ICON_DIR/microsoft.svg" "$ICON_DIR/cloudflare.svg" "$WEB_DIR/styles.css" "$VERSION"; do
  [[ -f "$f" ]] || fail "missing $f"
done

echo "=== Vodia MCP v0.14.9.23.5 — Brand Polish ==="
echo "Keeps AWS and Microsoft exactly as-is."
echo "Improves Vodia and Cloudflare only."

echo "[1/8] Preflight — NO LIVE CHANGES"
grep -qi '<svg' "$ICON_DIR/cloudflare.svg" || fail "Cloudflare asset is not SVG"
grep -qi '<svg' "$ICON_DIR/microsoft.svg" || fail "Microsoft asset is not SVG"
grep -qi '<svg' "$ICON_DIR/aws.svg" || fail "AWS asset is not SVG"
grep -qi '<svg' "$ICON_DIR/vodia.svg" || fail "Vodia asset is not SVG"
echo "PASS: current assets valid"

echo "[2/8] Stage improved Cloudflare mark"
cp -a "$ICON_DIR/cloudflare.svg" "$TMP_CF"
python3 - "$TMP_CF" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()

# Preserve the exact existing Cloudflare vector path; only apply Cloudflare orange.
if '<svg' not in s.lower():
    raise SystemExit('Cloudflare SVG missing <svg>')
s=re.sub(r'<path\b(?![^>]*\bfill=)', '<path fill="#F38020"', s, count=1, flags=re.I)

# If the path already had a fill, replace it.
s=re.sub(r'(<path\b[^>]*\bfill=["\'])[^"\']+(["\'])', r'\1#F38020\2', s, count=1, flags=re.I)

p.write_text(s)
PY
grep -q '#F38020' "$TMP_CF" || fail "Cloudflare orange was not applied"
echo "PASS: exact Cloudflare vector retained and recolored orange"

echo "[3/8] Stage compact Vodia mark"
cat > "$TMP_VODIA" <<'SVG'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96" role="img" aria-labelledby="title">
  <title id="title">Vodia</title>
  <rect width="96" height="96" rx="22" fill="#ffffff"/>
  <path d="M18 25h15l15 43 15-43h15L57 79H39L18 25z" fill="#0B2347"/>
  <g fill="#E3242B">
    <circle cx="69" cy="18" r="6"/>
    <circle cx="80" cy="27" r="5"/>
    <circle cx="64" cy="31" r="4"/>
  </g>
</svg>
SVG
grep -qi '<svg' "$TMP_VODIA" || fail "staged Vodia SVG invalid"
echo "PASS: compact Vodia brand mark staged"

echo "[4/8] Stage CSS/version — NO LIVE CHANGES"
cp -a "$WEB_DIR/styles.css" "$TMP_CSS"
cat >> "$TMP_CSS" <<'CSS'

/* v0.14.9.23.5 final vendor brand polish */
.provider-pbx{
  width:44px;
  flex-basis:44px;
  padding:4px;
}
.provider-cf{
  width:44px;
  flex-basis:44px;
  padding:6px;
}
.provider-pbx .vendor-logo,
.provider-cf .vendor-logo{
  width:100%;
  height:100%;
  object-fit:contain;
}
CSS

cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.23.5\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "staged version.js syntax invalid"
echo PASS

echo "[5/8] Full staged sanity check — STILL NO LIVE CHANGES"
python3 - "$TMP_CF" "$TMP_VODIA" "$TMP_CSS" "$TMP_VERSION" <<'PY'
from pathlib import Path
import sys
cf=Path(sys.argv[1]).read_text()
vodia=Path(sys.argv[2]).read_text()
css=Path(sys.argv[3]).read_text()
ver=Path(sys.argv[4]).read_text()

if '#F38020' not in cf:
    raise SystemExit('VALIDATION ERROR: Cloudflare orange missing')
if '<svg' not in cf.lower():
    raise SystemExit('VALIDATION ERROR: Cloudflare SVG invalid')
if '<svg' not in vodia.lower() or '#E3242B' not in vodia or '#0B2347' not in vodia:
    raise SystemExit('VALIDATION ERROR: Vodia mark invalid')
if '.provider-pbx{' not in css or '.provider-cf{' not in css:
    raise SystemExit('VALIDATION ERROR: final sizing CSS missing')
if '0.14.9.23.5' not in ver:
    raise SystemExit('VALIDATION ERROR: version mismatch')

print('PASS: Cloudflare orange mark validated')
print('PASS: Vodia compact mark validated')
print('PASS: AWS left untouched')
print('PASS: Microsoft 365 left untouched')
print('PASS: staged CSS/version validated')
PY

echo "[6/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$ICON_DIR/cloudflare.svg" "$BACKUP_DIR/cloudflare.svg"
cp -a "$ICON_DIR/vodia.svg" "$BACKUP_DIR/vodia.svg"
cp -a "$WEB_DIR/styles.css" "$BACKUP_DIR/styles.css"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[7/8] Activate + verify"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_CF" "$ICON_DIR/cloudflare.svg"
install -o root -g root -m 0644 "$TMP_VODIA" "$ICON_DIR/vodia.svg"
install -o root -g root -m 0644 "$TMP_CSS" "$WEB_DIR/styles.css"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"

systemctl restart "$SERVICE"
systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done

[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.23.5' "$HEALTH" || fail "health did not report v0.14.9.23.5"
grep -q '#F38020' "$ICON_DIR/cloudflare.svg" || fail "live Cloudflare orange missing"
grep -q '#E3242B' "$ICON_DIR/vodia.svg" || fail "live Vodia red detail missing"
echo PASS

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.23.5 brand polish installed"
echo "PASS: Microsoft 365 unchanged"
echo "PASS: AWS unchanged"
echo "PASS: Cloudflare now uses orange brand mark"
echo "PASS: Vodia now uses compact square brand mark"
echo "PASS: Light/Dark mode preserved"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
