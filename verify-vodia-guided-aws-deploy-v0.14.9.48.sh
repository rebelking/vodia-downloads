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

python3 - "$UI" "$MODULE" "$DEPLOY" "$TMP/app.js" <<'PY'
from pathlib import Path
import re,sys
ui=Path(sys.argv[1]).read_text(); module=Path(sys.argv[2]).read_text(); deploy=Path(sys.argv[3]).read_text()
checks={
 "v0.14.9.48 UI URI": 'ui://vodia/msp-guided/v0.14.9.48/mcp-app.html' in module,
 "five-step navigation": all(x in ui for x in ['1 · Customer','2 · Connect AWS','3 · Marketplace','4 · Configure EC2','5 · Review &amp; Deploy']),
 "Marketplace before EC2": ui.index('id="marketplaceStepPanel"') < ui.index('id="awsStepPanel"'),
 "Marketplace separate from deploy": 'id="marketplaceBox"' not in ui[ui.index('id="deployStepPanel"'):],
 "live offer flow": 'aws_marketplace_present_vodia_offer' in ui and 'aws_marketplace_prepare_vodia_purchase' in ui,
 "subscription gate": '$("continueMarketplace").disabled=!marketplaceSubscriptionActive' in ui,
 "automatic offer display": 'if(!active && !currentMarketplaceOffer) await loadMarketplaceOffer()' in ui,
 "EC2 review gate": 'if(!selectedRegion || !currentNetwork || !marketplaceSubscriptionActive) return' in ui,
 "separate approvals": 'marketplaceApproval' in ui and 'deploymentApproval' in ui,
 "real planner errors": 'function toolFailureMessage' in ui and 'result?.isError===true' in ui,
 "automatic AMI discovery": 'discoverVodiaMarketplaceAmi' in deploy and 'fulfillmentOptionId' in deploy,
 "UI app version": 'appInfo:{name:"vodia-setup",version:"1.12.0"}' in ui,
}
for k,v in checks.items(): print(('PASS' if v else 'FAIL')+': '+k)
bad=[k for k,v in checks.items() if not v]
if bad: raise SystemExit('Static checks failed: '+', '.join(bad))
m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',ui)
if not m: raise SystemExit('Could not extract inline JavaScript')
Path(sys.argv[4]).write_text(m.group(1))
PY
node --check "$TMP/app.js"
node --check "$MODULE"
node --check "$DEPLOY"
pass "JavaScript syntax"
echo "RESULT: PASS — Marketplace subscription is a required step before EC2 configuration and deployment approval."
