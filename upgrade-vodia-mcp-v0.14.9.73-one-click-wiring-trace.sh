#!/usr/bin/env bash
# Vodia MCP v0.14.9.73 — one-click button wiring + runtime trace hardening
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.73"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-one-click-wiring-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
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
  0.14.9.72) ;;
  0.14.9.73) echo "v0.14.9.73 detected; verification/repair mode." ;;
  *) fail "expected v0.14.9.72 or .73; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v$TO_VER — one-click wiring + runtime trace ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Patch staged guided UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_ONE_CLICK_WIRING_V73' not in s:
    # Add a stable marker/state constant near the Marketplace product ID.
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0:
        raise SystemExit("PATCH ERROR: Marketplace product ID anchor missing")
    line_end=s.find('\n',i)
    if line_end<0:
        raise SystemExit("PATCH ERROR: Marketplace product ID line malformed")
    s=s[:line_end+1]+'  const VODIA_ONE_CLICK_WIRING_V73 = true;\n'+s[line_end+1:]

    # Rewrite the anonymous loadNetwork click listener as one named handler.
    start=s.find('$("loadNetwork").addEventListener("click",async()=>{')
    if start<0:
        # If a prior repair already converted it, accept named handler.
        if 'async function handleLoadNetworkClickV73()' not in s:
            raise SystemExit("PATCH ERROR: loadNetwork listener anchor missing")
    else:
        end=s.find('\n  $("planDeployment").addEventListener',start)
        if end<0:
            raise SystemExit("PATCH ERROR: planDeployment boundary missing")
        block=s[start:end]
        stripped=block.rstrip()
        if not stripped.endswith('});'):
            raise SystemExit("PATCH ERROR: loadNetwork listener closing boundary unexpected")

        body_start=block.find('{')+1
        body_end=block.rfind('});')
        body=block[body_start:body_end]

        # Harden the one pre-try DOM read that can throw without any tool trace.
        body=body.replace(
            '    const previousKey=$("keyPairSelect").value;\n    try{',
            '    let previousKey="";\n    try{\n      previousKey=$("keyPairSelect")?.value||"";'
        )

        # Trace every button invocation before any early return.
        trace='''\n    debugLog("info","LOAD_NETWORK_CLICK",{\n      deploymentMethod:typeof deploymentMethod==="string"?deploymentMethod:"UNKNOWN",\n      customerId:id||null,\n      region:selectedRegion||null,\n      buttonDisabled:Boolean($("loadNetwork")?.disabled)\n    });\n    if(!id || !selectedRegion){\n      debugLog("error","LOAD_NETWORK_BLOCKED",{customerId:id||null,region:selectedRegion||null});\n      return;\n    }'''
        body=body.replace('\n    if(!id || !selectedRegion) return;', trace, 1)

        # Trace caught UI/runtime failures so they cannot silently look like an AWS no-op.
        body=body.replace(
            '    }catch(e){\n      currentNetwork=null;',
            '    }catch(e){\n      debugLog("error","LOAD_NETWORK_ERROR",{message:e?.message||String(e),stack:e?.stack||null,deploymentMethod:typeof deploymentMethod==="string"?deploymentMethod:"UNKNOWN",region:selectedRegion||null});\n      currentNetwork=null;'
        )

        # Preserve one-click button wording after success/failure.
        body=body.replace(
            '      $("loadNetwork").textContent=currentNetwork?"Reload EC2 options":"Load EC2 options";',
            '      $("loadNetwork").textContent=(typeof deploymentMethod==="string" && deploymentMethod==="ONE_CLICK_MARKETPLACE")\n        ?(currentNetwork?"Re-prepare one-click settings":"Prepare one-click settings")\n        :(currentNetwork?"Reload EC2 options":"Load EC2 options");'
        )

        replacement='''async function handleLoadNetworkClickV73(){'''+body+'''\n  }\n\n  $("loadNetwork").onclick=handleLoadNetworkClickV73;\n'''
        s=s[:start]+replacement+s[end:]

    # Add deployment method and button state to snapshots.
    old='''      region:selectedRegion,\n      marketplaceActive:marketplaceSubscriptionActive,''';
    new='''      region:selectedRegion,\n      deploymentMethod:typeof deploymentMethod==="string"?deploymentMethod:"UNKNOWN",\n      loadNetworkDisabled:Boolean($("loadNetwork")?.disabled),\n      marketplaceActive:marketplaceSubscriptionActive,''';
    if old in s:
        s=s.replace(old,new,1)

# Version/debug markers.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.73"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.31.0"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.73/mcp-app.html',s,count=1)
if count!=1:
    raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>'+to+r'\2',s,count=1)
if count!=1:
    raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

echo "[2/7] Validate staged UI"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline.js" >/dev/null || fail "guided UI JavaScript invalid"
grep -Fq 'VODIA_ONE_CLICK_WIRING_V73' "$TMP/staged/msp-guided-app.html" || fail "v73 marker missing"
grep -Fq 'async function handleLoadNetworkClickV73()' "$TMP/staged/msp-guided-app.html" || fail "named loadNetwork handler missing"
grep -Fq 'LOAD_NETWORK_CLICK' "$TMP/staged/msp-guided-app.html" || fail "click trace missing"
grep -Fq 'LOAD_NETWORK_ERROR' "$TMP/staged/msp-guided-app.html" || fail "runtime error trace missing"
grep -Fq 'aws_marketplace_prepare_vodia_one_click' "$TMP/staged/msp-guided-app.html" || fail "one-click tool call missing"
grep -Fq 'Prepare one-click settings' "$TMP/staged/msp-guided-app.html" || fail "one-click label missing"
echo "PASS: button wiring, one-click tool call, and runtime trace are staged and valid"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.73 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[3/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v73 files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/7] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/7] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.73"' <<<"$HEALTH" || fail "health does not report v0.14.9.73"
echo "$HEALTH"

echo "[6/7] Live marker verification"
grep -Fq 'VODIA_ONE_CLICK_WIRING_V73' "$UI" || fail "live v73 marker missing"
grep -Fq 'handleLoadNetworkClickV73' "$UI" || fail "live named click handler missing"
grep -Fq 'LOAD_NETWORK_ERROR' "$UI" || fail "live runtime trace missing"
echo "PASS: live one-click button wiring markers present"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.73 installed."
echo "PASS: Prepare one-click settings now uses one explicit named click handler."
echo "PASS: Developer Trace will log LOAD_NETWORK_CLICK before any tool call."
echo "PASS: Runtime UI failures will log LOAD_NETWORK_ERROR instead of silently returning."
echo "Backup: $BACKUP_DIR"
