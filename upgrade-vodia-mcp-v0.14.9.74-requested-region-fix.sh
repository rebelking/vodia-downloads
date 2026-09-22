#!/usr/bin/env bash
# Vodia MCP v0.14.9.74 — fix requestedRegion scope in one-click/load-network handler
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.74"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-requested-region-fix-$STAMP"
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
  0.14.9.73) ;;
  0.14.9.74) echo "v0.14.9.74 detected; verification/repair mode." ;;
  *) fail "expected v0.14.9.73 or .74; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v$TO_VER — requestedRegion scope fix ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Patch staged guided UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys

p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_REQUESTED_REGION_FIX_V74' not in s:
    start=s.find('async function handleLoadNetworkClickV73(')
    if start<0:
        start=s.find('async function handleLoadNetworkClickV74(')
    if start<0:
        raise SystemExit("PATCH ERROR: v73 load-network handler not found")

    onclick=s.find('$("loadNetwork").onclick=',start)
    if onclick<0:
        raise SystemExit("PATCH ERROR: loadNetwork onclick assignment not found")

    # Find the function's closing brace immediately before the onclick assignment.
    func_chunk=s[start:onclick]
    close=func_chunk.rfind('\n  }')
    if close<0:
        raise SystemExit("PATCH ERROR: load-network function closing brace not found")
    func_end=start+close+len('\n  }')
    func=s[start:func_end]

    # Normalize the function name/signature and onclick target.
    func=re.sub(r'async function handleLoadNetworkClickV7[34]\([^)]*\)\{',
                'async function handleLoadNetworkClickV74(ev){',func,count=1)

    # Remove any stale declaration of requestedRegion inside this handler so there
    # is exactly one declaration in a predictable scope.
    func=re.sub(r'^\s*(?:const|let)\s+requestedRegion\s*=.*?;\s*\n','',func,flags=re.M)

    id_anchor='    const id=customerId();\n'
    if id_anchor not in func:
        raise SystemExit("PATCH ERROR: customerId declaration anchor missing in load-network handler")

    region_block='''    const btn=ev?.currentTarget||$("loadNetwork");
    const requestedRegion=String($("regionSelect")?.value||selectedRegion||"").trim();
    if(requestedRegion) selectedRegion=requestedRegion;
    if(!id || !requestedRegion){
      debugLog("error","LOAD_NETWORK_BLOCKED",{customerId:id||null,region:requestedRegion||null});
      setMsg("deployMsg","Select a customer and deployment region first.");
      return;
    }
    if(btn?.disabled){
      debugLog("info","LOAD_NETWORK_DUPLICATE_IGNORED",{region:requestedRegion});
      return;
    }
'''
    func=func.replace(id_anchor,id_anchor+region_block,1)

    # Existing v73 guard used selectedRegion; keep only the v74 guard above.
    func=re.sub(
        r'\n\s*if\(!id \|\| !selectedRegion\)\{\n\s*debugLog\("error","LOAD_NETWORK_BLOCKED",\{customerId:id\|\|null,region:selectedRegion\|\|null\}\);\n\s*return;\n\s*\}',
        '',
        func,
        count=1
    )

    # Make the trace report the resolved/requested region.
    func=func.replace('region:selectedRegion||null,','region:requestedRegion||null,',1)

    # Keep caught-error telemetry on the same resolved region.
    func=func.replace('region:selectedRegion||null});','region:requestedRegion||null});')

    # Replace original function and onclick assignment.
    s=s[:start]+func+s[func_end:]
    s=s.replace('$("loadNetwork").onclick=handleLoadNetworkClickV73;',
                '$("loadNetwork").onclick=handleLoadNetworkClickV74;',1)

    # Stable marker near product ID.
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0:
        raise SystemExit("PATCH ERROR: Marketplace product ID anchor missing")
    line_end=s.find('\n',i)
    s=s[:line_end+1]+'  const VODIA_REQUESTED_REGION_FIX_V74 = true;\n'+s[line_end+1:]

# Version/debug markers.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.74"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.32.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                 'ui://vodia/msp-guided/v0.14.9.74/mcp-app.html',s,count=1)
if count!=1:
    raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
                 r'\g<1>'+to+r'\2',s,count=1)
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

python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
start=s.find('async function handleLoadNetworkClickV74(ev){')
end=s.find('$("loadNetwork").onclick=handleLoadNetworkClickV74;',start)
if start<0 or end<0: raise SystemExit("VALIDATION ERROR: v74 handler or onclick target missing")
block=s[start:end]
if block.count('const requestedRegion=') != 1:
    raise SystemExit(f"VALIDATION ERROR: expected exactly one requestedRegion declaration, found {block.count('const requestedRegion=')}")
decl=block.find('const requestedRegion=')
first_use=block.find('requestedRegion')
if decl<0 or first_use != decl+len('const '):
    raise SystemExit("VALIDATION ERROR: requestedRegion is referenced before its declaration")
for required in [
    'aws_marketplace_prepare_vodia_one_click',
    'LOAD_NETWORK_CLICK',
    'LOAD_NETWORK_ERROR',
    'LOAD_NETWORK_DUPLICATE_IGNORED'
]:
    if required not in block:
        raise SystemExit("VALIDATION ERROR: missing "+required)
print("PASS: requestedRegion declared exactly once before use; one-click call and click/error guards present")
PY

grep -Fq 'VODIA_REQUESTED_REGION_FIX_V74' "$TMP/staged/msp-guided-app.html" || fail "v74 marker missing"
echo "PASS: v74 guided UI staged and JavaScript-valid"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.74 staged patch validated successfully."
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
  echo "ROLLBACK: restoring pre-v74 files"
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
grep -q '"version":"0.14.9.74"' <<<"$HEALTH" || fail "health does not report v0.14.9.74"
echo "$HEALTH"

echo "[6/7] Live verification"
grep -Fq 'VODIA_REQUESTED_REGION_FIX_V74' "$UI" || fail "live v74 marker missing"
grep -Fq 'handleLoadNetworkClickV74' "$UI" || fail "live v74 handler missing"
grep -Fq 'LOAD_NETWORK_DUPLICATE_IGNORED' "$UI" || fail "live duplicate-click guard missing"
echo "PASS: requestedRegion scope fix and duplicate-click guard are live"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.74 installed."
echo "PASS: requestedRegion is resolved once at handler entry and remains in scope."
echo "PASS: rapid duplicate Load/Prepare clicks are ignored."
echo "PASS: one-click MCP call remains wired through aws_marketplace_prepare_vodia_one_click."
echo "Backup: $BACKUP_DIR"
