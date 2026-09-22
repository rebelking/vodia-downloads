#!/usr/bin/env bash
# Vodia MCP v0.14.9.71/.72 preflight debugger — READ ONLY
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass(){ printf 'PASS: %s\n' "$*"; }
warn(){ printf 'WARN: %s\n' "$*"; }
fail(){ printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }
info(){ printf 'INFO: %s\n' "$*"; }
FAILS=0

echo "=== Vodia MCP Marketplace preflight debugger (READ ONLY) ==="
echo "No files will be modified. No service will be restarted. No AWS resources will be changed."
echo

for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do
  [[ -f "$f" ]] && pass "found $f" || fail "missing $f"
done

if [[ -f "$VERSION" ]]; then
  CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "unknown")
PY
)"
  info "connector version: $CURRENT"
fi

systemctl is-active --quiet "$SERVICE" && pass "$SERVICE is active" || fail "$SERVICE is not active"

if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then
  pass "health endpoint responded"
  printf 'INFO: health: %s\n' "$HEALTH"
else
  fail "health endpoint did not respond"
fi

node --check "$BACKEND" >/dev/null 2>&1 && pass "backend JavaScript syntax" || fail "backend JavaScript syntax"
node --check "$GUIDED" >/dev/null 2>&1 && pass "guided resource JavaScript syntax" || fail "guided resource JavaScript syntax"
node --check "$VERSION" >/dev/null 2>&1 && pass "version JavaScript syntax" || fail "version JavaScript syntax"

python3 - "$UI" "$TMP/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts:
    raise SystemExit(2)
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
if [[ -s "$TMP/inline.js" ]] && node --check "$TMP/inline.js" >/dev/null 2>&1; then
  pass "guided UI inline JavaScript syntax"
else
  fail "guided UI inline JavaScript syntax"
fi

check_marker(){
  local file="$1" marker="$2" label="$3"
  grep -Fq "$marker" "$file" && pass "$label" || fail "$label"
}

echo
echo "--- Required v0.14.9.71 exact Marketplace AMI markers ---"
check_marker "$BACKEND" 'VODIA_EXACT_MARKETPLACE_AMI_V71' 'v71 backend marker'
check_marker "$BACKEND" 'expectedVodiaMarketplaceAmiName' 'exact AMI-name resolver'
check_marker "$BACKEND" 'MARKETPLACE_AMI_NAME_MISMATCH' 'AMI-name mismatch guard'
check_marker "$BACKEND" 'readVodiaMarketplaceAmiInstructions' 'Marketplace usage-instructions reader'
check_marker "$UI" 'Marketplace AMI:' 'review screen AMI evidence'
check_marker "$UI" 'PBX access URL:' 'post-deployment PBX access field'

echo
echo "--- Required v0.14.9.72 deployment-method markers ---"
if grep -Fq 'VODIA_DEPLOYMENT_METHOD_V72' "$BACKEND"; then
  pass "v72 backend marker"
else
  warn "v72 backend marker missing (expected in partial .72 state before repair)"
fi
if grep -Fq 'data-deployment-method="v0.14.9.72"' "$UI"; then
  pass "v72 UI marker"
else
  warn "v72 UI marker missing (expected in partial .72 state before repair)"
fi
grep -Fq 'Launch from EC2 Console style' "$UI" && pass "Managed EC2 launch-method UI" || warn "Managed EC2 launch-method UI not present yet"
grep -Fq 'One-click launch from AWS Marketplace' "$UI" && pass "One-click Marketplace launch-method UI" || warn "One-click Marketplace launch-method UI not present yet"

echo
echo "--- Patch-anchor compatibility ---"
grep -Fq 'async function resolveMarketplaceAmi(' "$BACKEND" && pass "backend resolver replacement anchor" || fail "backend resolver replacement anchor"
grep -Fq 'function buildRunInstancesParams(' "$BACKEND" && pass "backend RunInstances builder anchor" || fail "backend RunInstances builder anchor"
grep -Fq '"PBX: "+name' "$UI" && pass "review summary PBX anchor" || fail "review summary PBX anchor"
if grep -Fq '"AMI: "+(status?.imageId||launchResult?.imageId||"")' "$UI"; then
  pass "legacy running-summary AMI anchor"
elif grep -Fq '"AMI: "+(status?.imageId||"Unknown")' "$UI"; then
  pass "live deployment-monitor AMI anchor"
else
  fail "no compatible running/deployment-monitor AMI anchor"
fi
grep -Fq '<div id="marketplaceMount"></div>' "$UI" && pass "Marketplace launch-method insertion anchor" || fail "Marketplace launch-method insertion anchor"
grep -Fq 'function updatePlanButton()' "$UI" && pass "updatePlanButton insertion anchor" || fail "updatePlanButton insertion anchor"

echo
echo "--- Marketplace product-code environment ---"
ENV_LINE="$(systemctl show "$SERVICE" --property=Environment --no-pager 2>/dev/null || true)"
if grep -q 'VODIA_AWS_MARKETPLACE_PRODUCT_CODE=' <<<"$ENV_LINE"; then
  CODE="$(sed -n 's/.*VODIA_AWS_MARKETPLACE_PRODUCT_CODE=\([^ "]*\).*/\1/p' <<<"$ENV_LINE" | head -n1)"
  if [[ "$CODE" == "f2uxc9d4cmfl8r00q3sem6nyk" ]]; then
    pass "Marketplace product code configured: $CODE"
  else
    warn "Marketplace product code is configured but differs from expected Vodia code: $CODE"
  fi
else
  fail "VODIA_AWS_MARKETPLACE_PRODUCT_CODE is not present in service environment"
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "RESULT: PASS — installer anchors and prerequisites look compatible."
  exit 0
else
  echo "RESULT: FAIL — $FAILS blocking preflight issue(s) found. Do not run the installer until corrected."
  exit 2
fi
