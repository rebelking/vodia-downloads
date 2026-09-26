#!/usr/bin/env bash
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

python3 - "$UI" "$MODULE" "$TMP/app.js" <<'PY'
from pathlib import Path
import re,sys
ui=Path(sys.argv[1]).read_text()
module=Path(sys.argv[2]).read_text()
out=Path(sys.argv[3])

checks={
  "v0.14.9.36 UI URI": 'ui://vodia/msp-guided/v0.14.9.36/mcp-app.html' in module,
  "vodia_setup preserved": '"vodia_setup"' in module,
  "AWS role field present": 'id="awsRoleArn"' in ui,
  "External ID password field": 'id="awsExternalId" type="password"' in ui,
  "direct AWS prompt text": "Enter the AWS role ARN and External ID below to connect this customer." in ui,
  "required disconnected form auto-opens": re.search(r'if\(selected\)\{[\s\S]*?awsConnectForm[^\n]*classList\.remove\("hidden"\)',ui) is not None,
  "disconnected Connect button hidden": '$("connectAws").classList.add("hidden")' in ui,
  "disconnected Check button hidden": '$("checkAws").classList.add("hidden")' in ui,
  "connected Reconnect preserved": '$("connectAws").textContent="Reconnect"' in ui,
  "connected Check preserved": '$("checkAws").classList.remove("hidden")' in ui,
  "Test & Connect preserved": 'Test &amp; Connect' in ui,
  "customer scoped save preserved": '"msp_save_customer_aws_connection"' in ui,
  "External ID cleared after attempt": ui.count('$("awsExternalId").value=""') >= 3,
  "continue button preserved": 'id="continueAws"' in ui,
  "region discovery preserved": '"aws_list_deployment_regions"' in ui,
  "layout preserved": 'class="setup-scroll"' in ui and 'max-height:520px' in ui,
  "fullscreen preserved": '"ui/request-display-mode"' in ui,
  "UI version marker": 'appInfo:{name:"vodia-setup",version:"1.6.0"}' in ui,
}
bad=[k for k,v in checks.items() if not v]
for k,v in checks.items(): print(("PASS" if v else "FAIL")+": "+k)
if bad: raise SystemExit("Static checks failed: "+", ".join(bad))

m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',ui)
if not m: raise SystemExit("Could not extract inline JS")
out.write_text(m.group(1))
PY

node --check "$TMP/app.js"
pass "inline JavaScript syntax"
echo
echo "RESULT: PASS — direct AWS role ARN / External ID entry is wired into the guided setup."
