#!/usr/bin/env bash
# Static verifier for the Vodia guided MCP App layout.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="${VODIA_MSP_GUIDED_UI_HTML:-$APP/ui/msp-guided-app.html}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
pass(){ echo "PASS: $*"; }

[[ -f "$UI" ]] || fail "missing UI file: $UI"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
command -v node >/dev/null 2>&1 || fail "node is required"

python3 - "$UI" "$TMP/app.js" <<'PY'
from pathlib import Path
import re, sys

ui = Path(sys.argv[1]).read_text()
js_out = Path(sys.argv[2])

checks = {
    "setup-scroll container": 'class="setup-scroll"' in ui and 'id="setupScroll"' in ui,
    "inline max-height": re.search(r'\.setup-scroll\s*\{[^}]*max-height\s*:\s*520px', ui, re.S) is not None,
    "inline vertical scroll": re.search(r'\.setup-scroll\s*\{[^}]*overflow-y\s*:\s*auto', ui, re.S) is not None,
    "inline overscroll containment": re.search(r'\.setup-scroll\s*\{[^}]*overscroll-behavior\s*:\s*contain', ui, re.S) is not None,
    "fullscreen body height": re.search(r'body\.fullscreen\s*\{[^}]*height\s*:\s*100vh', ui, re.S) is not None,
    "fullscreen body scrolling": re.search(r'body\.fullscreen\s*\{[^}]*overflow-y\s*:\s*auto', ui, re.S) is not None,
    "fullscreen removes content cap": re.search(r'body\.fullscreen\s+\.setup-scroll\s*\{[^}]*max-height\s*:\s*none', ui, re.S) is not None,
    "fullscreen removes inner scrolling": re.search(r'body\.fullscreen\s+\.setup-scroll\s*\{[^}]*overflow\s*:\s*visible', ui, re.S) is not None,
    "expand button starts hidden": 'id="expandBtn"' in ui and 'id="expandBtn" class="expandbtn" type="button" hidden' in ui,
    "size changed wire method": '"ui/notifications/size-changed"' in ui,
    "size report includes width and height": 'params:{width,height}' in ui,
    "display mode request": '"ui/request-display-mode"' in ui,
    "host context change handler": '"ui/notifications/host-context-changed"' in ui,
    "app declares inline/fullscreen": 'appCapabilities:{availableDisplayModes:["inline","fullscreen"]}' in ui,
    "no automatic fullscreen request": 'setTimeout(()=>requestDisplayMode("fullscreen")' not in ui,
    "tool call bridge preserved": 'request("tools/call",{name,arguments:args})' in ui,
    "existing setup tools preserved": all(x in ui for x in [
        '"msp_get_my_identity"',
        '"msp_list_organizations"',
        '"msp_list_customers"',
        '"msp_create_organization"',
        '"msp_create_customer"',
        '"msp_get_customer_aws_connection"'
    ]),
}

failed = [name for name, ok in checks.items() if not ok]
for name, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + name)

if failed:
    raise SystemExit("Static layout checks failed: " + ", ".join(failed))

m = re.search(r'<script>([\s\S]*?)</script>\s*</body>', ui)
if not m:
    raise SystemExit("Could not extract inline script")
js_out.write_text(m.group(1))
PY

node --check "$TMP/app.js"
pass "inline JavaScript syntax"

echo
echo "RESULT: PASS — Vodia guided UI satisfies the v0.14.9.33 static layout checks."
