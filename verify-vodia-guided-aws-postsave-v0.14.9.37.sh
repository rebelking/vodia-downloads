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
  "v0.14.9.37 UI URI": 'ui://vodia/msp-guided/v0.14.9.37/mcp-app.html' in module,
  "vodia_setup preserved": '"vodia_setup"' in module,
  "direct AWS entry preserved": 'id="awsRoleArn"' in ui and 'id="awsExternalId" type="password"' in ui,
  "customer-scoped AWS save preserved": '"msp_save_customer_aws_connection"' in ui,
  "canonical post-save re-read": 'Verifying saved AWS connection…' in ui and '"msp_get_customer_aws_connection"' in ui,
  "success requires configured connection": 'if(!connection?.configured)' in ui,
  "success message after canonical verification": 'AWS connection verified and saved securely.' in ui,
  "External ID cleared": ui.count('$("awsExternalId").value=""') >= 3,
  "continue preserved": 'id="continueAws"' in ui,
  "region discovery preserved": '"aws_list_deployment_regions"' in ui,
  "layout preserved": 'class="setup-scroll"' in ui and 'max-height:520px' in ui,
  "fullscreen preserved": '"ui/request-display-mode"' in ui,
  "UI app version": 'appInfo:{name:"vodia-setup",version:"1.7.0"}' in ui,
}

bad=[k for k,v in checks.items() if not v]
for k,v in checks.items():
    print(("PASS" if v else "FAIL")+": "+k)
if bad:
    raise SystemExit("Static checks failed: "+", ".join(bad))

m=re.search(r'<script>([\s\S]*?)</script>\s*</body>',ui)
if not m:
    raise SystemExit("Could not extract inline JavaScript")
out.write_text(m.group(1))
PY

node --check "$TMP/app.js"
pass "inline JavaScript syntax"
echo
echo "RESULT: PASS — AWS save is verified by a canonical customer connection re-read before UI success."
