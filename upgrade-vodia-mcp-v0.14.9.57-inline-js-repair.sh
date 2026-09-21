#!/usr/bin/env bash
# Vodia MCP v0.14.9.57 — repair guided-app inline JavaScript after v0.14.9.56
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.57"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-inline-js-repair-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.56) ;;
  0.14.9.57) echo "v0.14.9.57 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.56; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — inline JavaScript repair ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/6] Repair staged HTML — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# v0.14.9.56 injected a Python triple-quoted string containing JS "\n".
# Python converted it into a literal newline inside a JavaScript quoted string:
#   .join("
#   ");
# which prevents the MCP App from starting. Repair every such occurrence.
s, n = re.subn(r'\.join\("\s*\n\s*"\)', '.join("\\\\n")', s)
if n < 1:
    # Also accept already-repaired content for safe reruns/staging.
    if '.join("\\n")' not in s:
        raise SystemExit("PATCH ERROR: broken join newline pattern not found")

# Ensure Marketplace summary/review and resilient approval code from .56 remain.
required = [
  'id="marketplaceSubscriptionSummary"',
  '"Marketplace: Vodia PBX — ACTIVE"',
  'function resolvedDeploymentPlan(){',
  'Approval matches. Ready to deploy.',
  'Deployment plan state was lost or expired.'
]
for marker in required:
    if marker not in s:
        raise SystemExit("PATCH ERROR: required v0.14.9.56 marker missing: "+marker)

# Bump UI app marker/version.
if 'data-inline-js-repair="v0.14.9.57"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-inline-js-repair="v0.14.9.57"', 1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.18.1"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.57/mcp-app.html',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
                r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

echo "[2/6] Validate BOTH module JS and inline HTML JS"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline-app.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts:
    raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
print("Extracted inline script for syntax validation.")
PY
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided app inline JavaScript is invalid"

grep -Fq 'data-inline-js-repair="v0.14.9.57"' "$TMP/staged/msp-guided-app.html" || fail "repair marker missing"
grep -Fq 'id="marketplaceSubscriptionSummary"' "$TMP/staged/msp-guided-app.html" || fail "Marketplace summary missing"
grep -Fq 'function resolvedDeploymentPlan(){' "$TMP/staged/msp-guided-app.html" || fail "approval recovery missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.57/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "cache-bust URI missing"
echo "PASS: inline guided-app JavaScript syntax valid"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.56 application files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/6] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.57"' <<<"$HEALTH" || fail "health does not report v0.14.9.57"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"
echo "PASS"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.57 installed"
echo "PASS: Guided Vodia Setup inline JavaScript validated."
echo "PASS: Marketplace summary and deployment-approval fixes retained."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.57 UI resource."
