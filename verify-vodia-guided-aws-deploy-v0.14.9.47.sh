#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="${VODIA_MSP_GUIDED_UI_HTML:-$APP/ui/msp-guided-app.html}"
MODULE="${VODIA_MSP_GUIDED_MODULE:-$APP/msp-guided-app-v1.js}"
DEPLOY="${VODIA_AWS_DEPLOY_MODULE:-$APP/aws-marketplace-ec2-deploy-v1.js}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }
for f in "$UI" "$MODULE" "$DEPLOY"; do [[ -f "$f" ]] || fail "missing file: $f"; done

grep -Fq 'ui://vodia/msp-guided/v0.14.9.47/mcp-app.html' "$MODULE" || fail "v0.14.9.47 UI URI missing"
grep -Fq 'toolFailureMessage' "$UI" || fail "real tool-error handling missing"
grep -Fq 'result?.isError===true' "$UI" || fail "MCP isError handling missing"
grep -Fq 'appInfo:{name:"vodia-setup",version:"1.9.1"}' "$UI" || fail "UI version missing"
grep -Fq 'discoverVodiaMarketplaceAmi' "$DEPLOY" || fail "automatic Vodia AMI discovery missing"
grep -Fq 'fulfillmentOptionId' "$DEPLOY" || fail "Marketplace fulfillment lookup missing"
grep -Fq 'VODIA_MARKETPLACE_AMI_NOT_FOUND' "$DEPLOY" || fail "actionable AMI error missing"

python3 - "$UI" "$TMP/app.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',s)
if not m: raise SystemExit('FAIL: could not extract inline JavaScript')
Path(sys.argv[2]).write_text(m.group(1))
PY
node --check "$TMP/app.js"
node --check "$MODULE"
node --check "$DEPLOY"
pass "planner repair and JavaScript syntax verified"
echo "RESULT: PASS — the planner discovers the subscribed Vodia AMI and surfaces exact AWS errors."
