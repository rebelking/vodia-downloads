#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="${VODIA_MSP_GUIDED_UI_HTML:-$APP/ui/msp-guided-app.html}"
MODULE="${VODIA_MSP_GUIDED_MODULE:-$APP/msp-guided-app-v1.js}"
CONNECTIONS="${VODIA_MSP_CONNECTION_MODULE:-$APP/msp-customer-connections-v1.js}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

for f in "$UI" "$MODULE" "$CONNECTIONS"; do [[ -f "$f" ]] || fail "missing file: $f"; done

python3 - "$UI" "$MODULE" "$CONNECTIONS" "$TMP/app.js" <<'PY'
from pathlib import Path
import re,sys

ui=Path(sys.argv[1]).read_text()
module=Path(sys.argv[2]).read_text()
connections=Path(sys.argv[3]).read_text()
out=Path(sys.argv[4])

checks={
  "v0.14.9.39 UI URI": 'ui://vodia/msp-guided/v0.14.9.39/mcp-app.html' in module,
  "vodia_setup preserved": '"vodia_setup"' in module,
  "hosted setup preparation tool": 'msp_prepare_customer_aws_onboarding' in ui and '"msp_prepare_customer_aws_onboarding"' in connections,
  "hosted setup completion tool": 'msp_complete_customer_aws_onboarding' in ui and '"msp_complete_customer_aws_onboarding"' in connections,
  "customer-specific External ID": 'randomBytes(16)' in connections and '`vodia-${' in connections,
  "provider trust principal": 'VODIA_MCP_AWS_PROVIDER_ROLE_ARN' in connections and 'TrustVodiaMCP' in connections,
  "CloudShell installer": 'cloudShellScript' in connections and 'AWS Account ID:' in connections,
  "manual fallback preserved": 'id="awsRoleArn"' in ui and 'id="awsExternalId" type="password"' in ui,
  "real three-step navigation": 'id="continueDeploy"' in ui and 'id="deployStepPanel"' in ui and 'setStep(3)' in ui,
  "hard view replacement": 'el.hidden=!visible' in ui and 'aria-hidden' in ui and 'scrollTo({top:0' in ui,
  "region discovery": 'aws_list_deployment_regions' in ui,
  "network discovery": 'aws_discover_deployment_network' in ui,
  "subscription validation": 'aws_marketplace_check_subscription' in ui,
  "no-change planning": 'aws_marketplace_plan_vodia_pbx_deployment' in ui,
  "approval-gated deployment": 'aws_marketplace_apply_vodia_pbx_deployment' in ui and 'deploymentApproval' in ui,
  "canonical connection re-read": 'Verifying saved AWS connection…' in ui and 'msp_get_customer_aws_connection' in ui,
  "UI app version": 'appInfo:{name:"vodia-setup",version:"1.8.1"}' in ui,
}

bad=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(("PASS" if v else "FAIL")+": "+k)
if bad: raise SystemExit("Static checks failed: "+", ".join(bad))

m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',ui)
if not m: raise SystemExit("Could not extract inline JavaScript")
out.write_text(m.group(1))
PY

node --check "$TMP/app.js"
node --check "$MODULE"
node --check "$CONNECTIONS"
pass "JavaScript syntax"
echo
echo "RESULT: PASS — hosted AWS onboarding, manual fallback, step navigation, planning, and approval-gated deployment are present."
