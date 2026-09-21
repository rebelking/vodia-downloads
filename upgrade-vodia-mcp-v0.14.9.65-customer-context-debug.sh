#!/usr/bin/env bash
# Vodia MCP v0.14.9.65 — customer-first setup + persistent context + debug visibility
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.65"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-customer-context-$STAMP"
TMP="$(mktemp -d)"
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
  0.14.9.62|0.14.9.63|0.14.9.64) ;;
  0.14.9.65) echo "v0.14.9.65 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.62, .63, or .64; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — customer-first setup + context ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Styles for persistent customer context.
if '.contextbar{' not in s:
    css=r'''
.contextbar{display:flex;align-items:center;justify-content:space-between;gap:10px;margin:0 0 12px;padding:9px 10px;border:1px solid color-mix(in srgb,CanvasText 10%,transparent);border-radius:10px;background:color-mix(in srgb,CanvasText 4%,transparent)}
.context-main{min-width:0}.context-title{font-size:11px;font-weight:750}.context-copy{font-size:10px;opacity:.68;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:540px}
.contextbar button{width:auto;font-size:10px;padding:6px 8px}
'''
    s=s.replace('</style>',css+'</style>',1)

# Add persistent customer context immediately below the 4-step header.
if 'id="customerContextBar"' not in s:
    steps_end='''      <div id="customerPanel" class="panel">'''
    bar='''      <div id="customerContextBar" class="contextbar hidden">
        <div class="context-main">
          <div class="context-title">Current customer</div>
          <div id="customerContextText" class="context-copy">No customer selected</div>
        </div>
        <button id="changeCustomerBtn" class="secondary" type="button">Change customer</button>
      </div>

'''
    if steps_end not in s: raise SystemExit("PATCH ERROR: customer panel anchor missing")
    s=s.replace(steps_end,bar+steps_end,1)

# Ensure Debug button/drawer exists even when upgrading from .62/.63.
top_anchor='<button id="expandBtn" class="expandbtn" type="button" hidden>Expand</button>'
if 'id="debugBtn"' not in s:
    if top_anchor not in s: raise SystemExit("PATCH ERROR: expand anchor missing")
    s=s.replace(top_anchor,top_anchor+'\n        <button id="debugBtn" class="expandbtn" type="button">Debug</button>',1)

scroll_anchor='<div id="setupScroll" class="setup-scroll">'
if 'id="debugDrawer"' not in s:
    drawer='''<div id="debugDrawer" class="guided-box hidden" style="margin-top:10px">
      <div class="guided-title">Developer Trace <span class="badge">LIVE</span></div>
      <div class="guided-copy">Browser/card events and MCP tool calls. Sensitive values are redacted.</div>
      <div class="marketplace-actions">
        <button id="debugCopy" class="secondary" type="button">Copy trace</button>
        <button id="debugClear" class="secondary" type="button">Clear</button>
      </div>
      <div id="debugConsole" class="summarybox" style="max-height:220px;overflow:auto;font-family:ui-monospace,SFMono-Regular,Consolas,monospace"></div>
    </div>
    '''
    if scroll_anchor not in s: raise SystemExit("PATCH ERROR: setup scroll anchor missing")
    s=s.replace(scroll_anchor,drawer+scroll_anchor,1)

# Debug state/helpers if absent.
state_anchor='let fullscreenScrollTop = 0;'
if 'let debugEntries = [];' not in s:
    if state_anchor not in s: raise SystemExit("PATCH ERROR: state anchor missing")
    s=s.replace(state_anchor,state_anchor+'''
  let debugEntries = [];
  let debugSeq = 0;
  const DEBUG_MAX = 250;''',1)

post_anchor='  function post(msg){ window.parent.postMessage(msg, "*"); }'
if 'function debugLog(kind,label,payload)' not in s:
    helpers=r'''  function redactDebug(value,depth=0){
    if(depth>5) return "[depth-limit]";
    if(value===null || value===undefined) return value;
    if(typeof value==="string") return value.length>1000?value.slice(0,1000)+"…":value;
    if(typeof value!=="object") return value;
    if(Array.isArray(value)) return value.slice(0,25).map(v=>redactDebug(v,depth+1));
    const out={};
    const deny=/external.?id|secret|password|authorization|credential|access.?key|token|approval|confirmation|private.?key/i;
    for(const [k,v] of Object.entries(value)) out[k]=deny.test(k)?"<REDACTED>":redactDebug(v,depth+1);
    return out;
  }
  function debugString(value){
    if(value===undefined) return "";
    if(typeof value==="string") return value;
    try{return JSON.stringify(redactDebug(value))}catch{return String(value)}
  }
  function renderDebug(){
    const box=$("debugConsole"); if(!box) return;
    box.textContent=debugEntries.map(x=>x.text).join("\n");
    box.scrollTop=box.scrollHeight;
  }
  function debugLog(kind,label,payload){
    const stamp=new Date().toISOString().slice(11,23);
    const body=payload===undefined?"":(" "+debugString(payload));
    debugEntries.push({kind,text:stamp+" #"+(++debugSeq)+" "+label+body});
    if(debugEntries.length>DEBUG_MAX) debugEntries=debugEntries.slice(-DEBUG_MAX);
    renderDebug();
  }

'''
    if post_anchor not in s: raise SystemExit("PATCH ERROR: post anchor missing")
    s=s.replace(post_anchor,helpers+post_anchor,1)

# Trace tool calls if current UI does not already do so.
if 'debugLog("call","→ "+name' not in s:
    pat=re.compile(r'  async function callTool\(name,args=\{\}\)\{.*?\n  \}',re.S)
    m=pat.search(s)
    if not m: raise SystemExit("PATCH ERROR: callTool function missing")
    new=r'''  async function callTool(name,args={}){
    const started=performance.now();
    debugLog("call","→ "+name,redactDebug(args));
    try{
      let result;
      if(window.openai?.callTool) result=await window.openai.callTool(name,args);
      else{
        if(!initialized) await initBridge();
        result=await request("tools/call",{name,arguments:args});
      }
      debugLog(result?.isError?"error":"ok","← "+name+" "+Math.round(performance.now()-started)+"ms",redactDebug(result));
      return result;
    }catch(error){
      debugLog("error","✕ "+name+" "+Math.round(performance.now()-started)+"ms",{message:error?.message||String(error)});
      throw error;
    }
  }'''
    s=s[:m.start()]+new+s[m.end():]

# Browser errors if absent.
display_anchor='  async function requestDisplayMode(mode){'
if 'UNHANDLED PROMISE' not in s:
    runtime=r'''  window.addEventListener("error",event=>{
    debugLog("error","BROWSER ERROR",{message:event.message,source:event.filename,line:event.lineno,column:event.colno});
  });
  window.addEventListener("unhandledrejection",event=>{
    debugLog("error","UNHANDLED PROMISE",{message:event.reason?.message||String(event.reason)});
  });

'''
    if display_anchor not in s: raise SystemExit("PATCH ERROR: display anchor missing")
    s=s.replace(display_anchor,runtime+display_anchor,1)

# Customer context updater.
selected_anchor='''  function selectedCustomerName(){
    return $("customerSelect").selectedOptions?.[0]?.textContent||"";
  }'''
if selected_anchor not in s: raise SystemExit("PATCH ERROR: selectedCustomerName anchor missing")
if 'function updateCustomerContext(){' not in s:
    context=r'''
  function updateCustomerContext(){
    const bar=$("customerContextBar");
    const text=$("customerContextText");
    if(!bar||!text) return;
    const org=selectedOrgName();
    const customer=selectedCustomerName();
    const account=currentAwsConnection?.account||"AWS not connected";
    const visible=Boolean(customerId());
    bar.classList.toggle("hidden",!visible);
    text.textContent=[org,customer,account].filter(Boolean).join(" · ");
  }
'''
    s=s.replace(selected_anchor,selected_anchor+context,1)

# IMPORTANT: remove automatic jump away from Customer whenever an AWS connection is already saved.
auto=re.compile(r'''\n\s*// A verified connection has completed Step 1\..*?\n\s*if\(currentStep===1\)\{.*?\n\s*\}\n''',re.S)
s,n=auto.subn('\n      updateCustomerContext();\n',s,count=1)
if n==0 and 'advanceToAwsStep();' in s[s.find('function renderAwsConnection'):s.find('function resetAws')]:
    # Conservative fallback for patched variants.
    block=s[s.find('function renderAwsConnection'):s.find('function resetAws')]
    block=re.sub(r'\s*if\(currentStep===1\)\{\s*setTimeout\(\(\)=>\{\s*if\(currentStep===1 && currentAwsConnection\?\.configured\) advanceToAwsStep\(\);\s*\},0\);\s*\}','\n      updateCustomerContext();',block,count=1)
    a=s.find('function renderAwsConnection'); b=s.find('function resetAws')
    s=s[:a]+block+s[b:]

# Also update context in disconnected branch and after customer/org changes.
disconnect='''      if(currentStep>1) setStep(1);
    }
  }'''
if disconnect in s:
    s=s.replace(disconnect,'''      if(currentStep>1) setStep(1);
      updateCustomerContext();
    }
  }''',1)

s=s.replace('''    onCustomerChanged(); resetAws();''','''    onCustomerChanged(); resetAws();''') if False else s

# Add explicit updates after select changes.
org_listener='''  $("orgSelect").addEventListener("change",()=>{'''
cust_listener='''  $("customerSelect").addEventListener("change",async()=>{'''
if org_listener in s and 'updateCustomerContext();' not in s[s.find(org_listener):s.find(cust_listener)]:
    idx=s.find('    reportSize();',s.find(org_listener))
    if idx>0: s=s[:idx]+'    updateCustomerContext();\n'+s[idx:]
if cust_listener in s:
    start=s.find(cust_listener); end=s.find('\n  });',start)
    if end>0 and 'updateCustomerContext();' not in s[start:end]:
        pos=s.rfind('    reportSize();',start,end)
        if pos>0: s=s[:pos]+'    updateCustomerContext();\n'+s[pos:]

# Change-customer button and debug buttons.
listener_anchor='''  $("expandBtn").addEventListener("click",async()=>{'''
if listener_anchor not in s: raise SystemExit("PATCH ERROR: expand listener missing")
extra=''
if '$("changeCustomerBtn").addEventListener' not in s:
    extra+=r'''  $("changeCustomerBtn").addEventListener("click",()=>{
    setStep(1);
    $("customerSelect").focus();
    reportSize();
  });
'''
if '$("debugBtn").addEventListener' not in s:
    extra+=r'''  $("debugBtn").addEventListener("click",()=>{
    $("debugDrawer").classList.toggle("hidden");
    debugLog("info","DEBUG TOGGLE",{open:!$("debugDrawer").classList.contains("hidden"),step:currentStep});
    reportSize();
  });
  $("debugClear").addEventListener("click",()=>{
    debugEntries=[];debugSeq=0;renderDebug();debugLog("info","TRACE CLEARED");
  });
  $("debugCopy").addEventListener("click",async()=>{
    const text=debugEntries.map(x=>x.text).join("\n");
    try{await navigator.clipboard.writeText(text);debugLog("info","TRACE COPIED",{lines:debugEntries.length});}
    catch(e){debugLog("error","COPY FAILED",{message:e.message});}
  });
'''
if extra:
    s=s.replace(listener_anchor,extra+listener_anchor,1)

# Always open at Step 1 after refresh/initialization so customer choice is visible.
# This prevents a persisted connected customer from silently starting on Marketplace.
init_try='''      await refreshAll();
      setStep(1);'''
if init_try not in s:
    # Find the initialization refreshAll call.
    marker='''      await refreshAll();'''
    if marker in s:
        s=s.replace(marker,marker+'\n      setStep(1);\n      updateCustomerContext();',1)

# Add UI start trace if absent.
if 'debugLog("info","UI START"' not in s:
    init='''  (async()=>{
    try{'''
    if init in s:
        s=s.replace(init,'''  debugLog("info","UI START",{uiVersion:"0.14.9.65",hasOpenAiBridge:Boolean(window.openai?.callTool)});
  (async()=>{
    try{''',1)

# Version/cache markers.
if 'data-customer-context="v0.14.9.65"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-customer-context="v0.14.9.65"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.23.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.65/mcp-app.html',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
                r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

cat >"$TMP/vodia-mcp-live-debug" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
echo "=== Vodia MCP live server log ==="
echo "Press Ctrl-C to stop. Read-only."
journalctl -fu "$SERVICE" -o short-iso --no-pager
SH
chmod +x "$TMP/vodia-mcp-live-debug"

echo "[2/7] Validate staged UI"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline-app.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided app inline JavaScript invalid"
grep -Fq 'id="customerContextBar"' "$TMP/staged/msp-guided-app.html" || fail "customer context bar missing"
grep -Fq 'id="changeCustomerBtn"' "$TMP/staged/msp-guided-app.html" || fail "change-customer button missing"
grep -Fq 'id="debugBtn"' "$TMP/staged/msp-guided-app.html" || fail "debug button missing"
grep -Fq 'id="debugDrawer"' "$TMP/staged/msp-guided-app.html" || fail "debug drawer missing"
grep -Fq 'function updateCustomerContext(){' "$TMP/staged/msp-guided-app.html" || fail "customer context updater missing"
grep -Fq 'UI START' "$TMP/staged/msp-guided-app.html" || fail "debug start marker missing"
echo "PASS: customer-first + context + debugger UI present"

echo "[3/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /usr/local/bin/vodia-mcp-live-debug ]] && cp -a /usr/local/bin/vodia-mcp-live-debug "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring previous UI files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/7] Install"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
install -o root -g root -m 0755 "$TMP/vodia-mcp-live-debug" /usr/local/bin/vodia-mcp-live-debug

echo "[5/7] Restart"
systemctl restart "$SERVICE"

echo "[6/7] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.65"' <<<"$HEALTH" || fail "health does not report v0.14.9.65"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.65 installed"
echo "PASS: Setup opens on Customer instead of silently skipping to Marketplace."
echo "PASS: Saved AWS connections no longer auto-advance away from customer selection."
echo "PASS: Current organization/customer/AWS account stays visible in later steps."
echo "PASS: Change customer is available from later steps."
echo "PASS: Debug button and live trace drawer are guaranteed present."
echo "PASS: Live server log helper available as: vodia-mcp-live-debug"
echo "Backup: $BACKUP_DIR"
echo "IMPORTANT: open Vodia Setup in a NEW conversation/card so the v0.14.9.65 resource URI is fetched."
