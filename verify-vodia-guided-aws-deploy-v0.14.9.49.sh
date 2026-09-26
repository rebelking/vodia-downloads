#!/usr/bin/env bash
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="${VODIA_MSP_GUIDED_UI_HTML:-$APP/ui/msp-guided-app.html}"
MODULE="${VODIA_MSP_GUIDED_MODULE:-$APP/msp-guided-app-v1.js}"
DEPLOY="${VODIA_AWS_DEPLOY_MODULE:-$APP/aws-marketplace-ec2-deploy-v1.js}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
for f in "$UI" "$MODULE" "$DEPLOY"; do [[ -f "$f" ]] || fail "missing $f"; done
python3 - "$UI" "$MODULE" "$DEPLOY" "$TMP/app.js" <<'PY'
from pathlib import Path
import re,sys
ui=Path(sys.argv[1]).read_text(); module=Path(sys.argv[2]).read_text(); deploy=Path(sys.argv[3]).read_text()
checks={
 'v0.14.9.49 UI URI':'ui://vodia/msp-guided/v0.14.9.49/mcp-app.html' in module,
 'five-step flow':all(x in ui for x in ['3 · Marketplace','4 · Configure EC2','5 · Review &amp; Deploy']),
 'visible verification status':'id="awsVerifyStatus"' in ui and 'aria-live="polite"' in ui,
 'no silent customer failure':'Select the customer again before verifying AWS.' in ui,
 'two-stage progress':'Step 1 of 2: testing STS AssumeRole' in ui and 'Step 2 of 2: confirming' in ui,
 'account mismatch protection':'AWS account mismatch: expected' in ui,
 'automatic Marketplace continuation':'await advanceToMarketplaceStep()' in ui,
 'exact error feedback':'AWS connection failed: ' in ui,
 'planner error handling':'function toolFailureMessage' in ui,
 'AMI discovery':'discoverVodiaMarketplaceAmi' in deploy,
 'UI app version':'appInfo:{name:"vodia-setup",version:"1.13.0"}' in ui,
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
echo "PASS: AWS verification feedback, account validation, Marketplace continuation, and JavaScript syntax verified."
