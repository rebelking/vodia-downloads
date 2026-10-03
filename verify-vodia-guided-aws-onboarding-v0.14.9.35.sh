#!/usr/bin/env bash
# Static verifier for Vodia MCP v0.14.9.35 guided AWS onboarding.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="${VODIA_MSP_GUIDED_UI_HTML:-$APP/ui/msp-guided-app.html}"
MODULE="${VODIA_MSP_GUIDED_MODULE:-$APP/msp-guided-app-v1.js}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

[[ -f "$UI" ]] || fail "missing UI file: $UI"
[[ -f "$MODULE" ]] || fail "missing guided module: $MODULE"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"

python3 - "$UI" "$MODULE" "$TMP/app.js" <<'PY'
from pathlib import Path
import re, sys

ui = Path(sys.argv[1]).read_text()
module = Path(sys.argv[2]).read_text()
js_out = Path(sys.argv[3])

checks = {
    "versioned UI resource": 'ui://vodia/msp-guided/v0.14.9.35/mcp-app.html' in module,
    "vodia_setup preserved": '"vodia_setup"' in module,
    "setup-scroll preserved": 'class="setup-scroll"' in ui and 'max-height:520px' in ui,
    "fullscreen toggle preserved": 'id="expandBtn"' in ui and '"ui/request-display-mode"' in ui,
    "no automatic fullscreen": 'setTimeout(()=>requestDisplayMode("fullscreen")' not in ui,
    "AWS connect button": 'id="connectAws"' in ui and 'Connect AWS' in ui,
    "AWS role ARN field": 'id="awsRoleArn"' in ui and 'VodiaMCPDeploymentRole' in ui,
    "External ID masked": 'id="awsExternalId" type="password"' in ui,
    "External ID not displayed after save": 'It is not displayed again after saving.' in ui,
    "Test and Connect button": 'id="saveAws"' in ui and 'Test &amp; Connect' in ui,
    "customer-scoped AWS save": '"msp_save_customer_aws_connection"' in ui,
    "customerId sent with AWS save": 'customerId:id' in ui,
    "External ID cleared": ui.count('$("awsExternalId").value=""') >= 3,
    "Continue to AWS": 'id="continueAws"' in ui and 'Continue to AWS' in ui,
    "AWS step panel": 'id="awsStepPanel"' in ui and '2 · AWS' in ui,
    "region discovery tool": '"aws_list_deployment_regions"' in ui,
    "region select": 'id="regionSelect"' in ui,
    "app UI version marker": 'appInfo:{name:"vodia-setup",version:"1.5.0"}' in ui,
    "existing customer flow preserved": all(x in ui for x in [
        '"msp_get_my_identity"',
        '"msp_list_organizations"',
        '"msp_list_customers"',
        '"msp_create_organization"',
        '"msp_create_customer"',
        '"msp_get_customer_aws_connection"'
    ]),
}

failed=[name for name,ok in checks.items() if not ok]
for name,ok in checks.items():
    print(("PASS" if ok else "FAIL")+": "+name)
if failed:
    raise SystemExit("Static AWS onboarding checks failed: "+", ".join(failed))

m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',ui)
if not m:
    raise SystemExit("Could not extract inline script")
js_out.write_text(m.group(1))
PY

node --check "$TMP/app.js"
pass "inline JavaScript syntax"

echo
echo "RESULT: PASS — Vodia guided AWS onboarding v0.14.9.35 static checks passed."
