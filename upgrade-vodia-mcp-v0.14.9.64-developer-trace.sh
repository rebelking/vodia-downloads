#!/usr/bin/env bash
# Vodia MCP v0.14.9.64 — in-card developer trace + live server debug helper
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.64"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-developer-trace-$STAMP"
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
  0.14.9.62|0.14.9.63) ;;
  0.14.9.64) echo "v0.14.9.64 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.62 or v0.14.9.63; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — developer trace ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Debug UI styles.
if '.debug-drawer{' not in s:
    css=r'''
.debugbtn{width:auto;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);background:transparent;color:CanvasText;padding:5px 8px;border-radius:8px;font-size:11px;font-weight:650;cursor:pointer}
.debugbtn.live{border-color:#22a06b}
.debug-drawer{margin-top:10px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:11px;background:color-mix(in srgb,CanvasText 3%,transparent);overflow:hidden}
.debug-head{display:flex;align-items:center;justify-content:space-between;gap:8px;padding:9px 10px;border-bottom:1px solid color-mix(in srgb,CanvasText 10%,transparent)}
.debug-title{font-size:11px;font-weight:750}.debug-actions{display:flex;gap:6px;flex-wrap:wrap}
.debug-actions button{width:auto;font-size:10px;padding:5px 7px}
.debug-console{max-height:230px;overflow:auto;padding:8px 10px;font:10px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace;white-space:pre-wrap;word-break:break-word}
.debug-line{padding:3px 0;border-bottom:1px dotted color-mix(in srgb,CanvasText 8%,transparent)}
.debug-line:last-child{border-bottom:0}
.debug-ok{opacity:.78}.debug-error{color:#ff6b6b}.debug-call{color:#7db7ff}.debug-info{opacity:.65}
'''
    s=s.replace('</style>',css+'</style>',1)

# Top Debug button.
top_anchor='<button id="expandBtn" class="expandbtn" type="button" hidden>Expand</button>'
if 'id="debugBtn"' not in s:
    if top_anchor not in s: raise SystemExit("PATCH ERROR: expand button anchor missing")
    s=s.replace(top_anchor,top_anchor+'\n        <button id="debugBtn" class="debugbtn live" type="button">Debug</button>',1)

# Drawer inside card, above setup scroll.
scroll_anchor='<div id="setupScroll" class="setup-scroll">'
if 'id="debugDrawer"' not in s:
    drawer='''<div id="debugDrawer" class="debug-drawer hidden">
      <div class="debug-head">
        <div>
          <div class="debug-title">Developer Trace <span id="debugState">LIVE</span></div>
          <div class="secret-note">Shows browser/card events and MCP tool calls. Sensitive fields are redacted.</div>
        </div>
        <div class="debug-actions">
          <button id="debugCopy" class="secondary" type="button">Copy</button>
          <button id="debugClear" class="secondary" type="button">Clear</button>
        </div>
      </div>
      <div id="debugConsole" class="debug-console"></div>
    </div>
    '''
    if scroll_anchor not in s: raise SystemExit("PATCH ERROR: setupScroll anchor missing")
    s=s.replace(scroll_anchor,drawer+scroll_anchor,1)

# State.
state_anchor='let fullscreenScrollTop = 0;'
if 'let debugEntries = [];' not in s:
    if state_anchor not in s: raise SystemExit("PATCH ERROR: state anchor missing")
    s=s.replace(state_anchor,state_anchor+'''
  let debugEntries = [];
  let debugSeq = 0;
  const DEBUG_MAX = 250;''',1)

# Debug helper functions before post().
post_anchor='  function post(msg){ window.parent.postMessage(msg, "*"); }'
if 'function debugLog(kind,label,payload)' not in s:
    helpers=r'''  function redactDebug(value,depth=0){
    if(depth>5) return "[depth-limit]";
    if(value===null || value===undefined) return value;
    if(typeof value==="string"){
      if(value.length>1200) return value.slice(0,1200)+"…";
      return value;
    }
    if(typeof value!=="object") return value;
    if(Array.isArray(value)) return value.slice(0,30).map(v=>redactDebug(v,depth+1));
    const out={};
    const deny=/external.?id|secret|password|authorization|credential|access.?key|token|approval|confirmation|private.?key/i;
    for(const [k,v] of Object.entries(value)){
      out[k]=deny.test(k)?"<REDACTED>":redactDebug(v,depth+1);
    }
    return out;
  }

  function debugString(value){
    if(value===undefined) return "";
    if(typeof value==="string") return value;
    try{return JSON.stringify(redactDebug(value))}catch{return String(value)}
  }

  function renderDebug(){
    const box=$("debugConsole");
    if(!box) return;
    box.innerHTML="";
    debugEntries.forEach(entry=>{
      const line=document.createElement("div");
      line.className="debug-line debug-"+entry.kind;
      line.textContent=entry.text;
      box.appendChild(line);
    });
    box.scrollTop=box.scrollHeight;
  }

  function debugLog(kind,label,payload){
    const stamp=new Date().toISOString().slice(11,23);
    const body=payload===undefined?"":(" "+debugString(payload));
    debugEntries.push({kind,text:stamp+" #"+(++debugSeq)+" "+label+body});
    if(debugEntries.length>DEBUG_MAX) debugEntries=debugEntries.slice(-DEBUG_MAX);
    renderDebug();
  }

  function debugSnapshot(){
    debugLog("info","STATE",{
      step:currentStep,
      displayMode:hostContext?.displayMode,
      customerId:customerId?.(),
      region:selectedRegion,
      marketplaceActive:marketplaceSubscriptionActive,
      hasNetwork:Boolean(currentNetwork),
      hasPlan:Boolean(currentDeploymentPlan),
      pbxName:$("pbxName")?.value||"",
      instanceType:$("instanceType")?.value||"",
      subnet:$("subnetSelect")?.value||"",
      securityGroup:$("securityGroupSelect")?.value||""
    });
  }

'''
    if post_anchor not in s: raise SystemExit("PATCH ERROR: post anchor missing")
    s=s.replace(post_anchor,helpers+post_anchor,1)

# Replace callTool with a traced wrapper.
call_pat=re.compile(r'  async function callTool\(name,args=\{\}\)\{.*?\n  \}',re.S)
m=call_pat.search(s)
if not m: raise SystemExit("PATCH ERROR: callTool function missing")
new_call=r'''  async function callTool(name,args={}){
    const started=performance.now();
    debugLog("call","→ "+name,redactDebug(args));
    try{
      let result;
      if(window.openai?.callTool) result=await window.openai.callTool(name,args);
      else{
        if(!initialized) await initBridge();
        result=await request("tools/call",{name,arguments:args});
      }
      const ms=Math.round(performance.now()-started);
      debugLog(result?.isError?"error":"ok","← "+name+" "+ms+"ms",redactDebug(result));
      return result;
    }catch(error){
      const ms=Math.round(performance.now()-started);
      debugLog("error","✕ "+name+" "+ms+"ms",{
        message:error?.message||String(error),
        stack:error?.stack||null
      });
      throw error;
    }
  }'''
s=s[:m.start()]+new_call+s[m.end():]

# Browser/card runtime errors.
init_anchor='  async function requestDisplayMode(mode){'
if 'window.addEventListener("error"' not in s:
    runtime=r'''  window.addEventListener("error",event=>{
    debugLog("error","BROWSER ERROR",{
      message:event.message,
      source:event.filename,
      line:event.lineno,
      column:event.colno
    });
  });
  window.addEventListener("unhandledrejection",event=>{
    debugLog("error","UNHANDLED PROMISE",{
      message:event.reason?.message||String(event.reason),
      stack:event.reason?.stack||null
    });
  });

'''
    if init_anchor not in s: raise SystemExit("PATCH ERROR: display mode anchor missing")
    s=s.replace(init_anchor,runtime+init_anchor,1)

# Log step changes.
step_marker='''  function setStep(step){
    currentStep=step;'''
if step_marker in s and 'debugLog("info","STEP"' not in s:
    s=s.replace(step_marker,'''  function setStep(step){
    currentStep=step;
    debugLog("info","STEP",{step});''',1)

# Debug buttons.
listener_anchor='''  $("expandBtn").addEventListener("click",async()=>{'''
if listener_anchor not in s: raise SystemExit("PATCH ERROR: expand listener anchor missing")
if '$("debugBtn").addEventListener' not in s:
    listeners=r'''  $("debugBtn").addEventListener("click",()=>{
    $("debugDrawer").classList.toggle("hidden");
    debugSnapshot();
    reportSize();
  });
  $("debugClear").addEventListener("click",()=>{
    debugEntries=[];
    debugSeq=0;
    renderDebug();
    debugLog("info","TRACE CLEARED");
  });
  $("debugCopy").addEventListener("click",async()=>{
    const text=debugEntries.map(x=>x.text).join("\n");
    try{
      await navigator.clipboard.writeText(text);
      debugLog("info","TRACE COPIED",{lines:debugEntries.length});
    }catch(e){
      debugLog("error","COPY FAILED",{message:e.message});
    }
  });

'''
    s=s.replace(listener_anchor,listeners+listener_anchor,1)

# Initial marker.
init='''  (async()=>{
    try{'''
if init in s and 'debugLog("info","UI START"' not in s:
    s=s.replace(init,'''  debugLog("info","UI START",{
    uiVersion:"0.14.9.64",
    userAgent:navigator.userAgent,
    hasOpenAiBridge:Boolean(window.openai?.callTool)
  });

  (async()=>{
    try{''',1)

# Version marker.
if 'data-developer-trace="v0.14.9.64"' not in s:
    # Add to card regardless of which previous marker exists.
    s=s.replace('<div class="card"', '<div class="card" data-developer-trace="v0.14.9.64"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.22.0"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.64/mcp-app.html',s,count=1)
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
echo "Press Ctrl-C to stop. This is read-only."
echo
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
grep -Fq 'id="debugBtn"' "$TMP/staged/msp-guided-app.html" || fail "Debug button missing"
grep -Fq 'id="debugDrawer"' "$TMP/staged/msp-guided-app.html" || fail "Debug drawer missing"
grep -Fq 'function debugLog(kind,label,payload)' "$TMP/staged/msp-guided-app.html" || fail "debug logger missing"
grep -Fq '→ "+name' "$TMP/staged/msp-guided-app.html" || fail "tool call tracing missing"
grep -Fq 'UNHANDLED PROMISE' "$TMP/staged/msp-guided-app.html" || fail "browser rejection tracing missing"
echo "PASS: in-card developer trace valid"

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
grep -q '"version":"0.14.9.64"' <<<"$HEALTH" || fail "health does not report v0.14.9.64"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.64 installed"
echo "PASS: Vodia Setup includes a live Developer Trace drawer."
echo "PASS: Every MCP tool call records start, response/error, and duration."
echo "PASS: Browser JavaScript errors and unhandled promises are captured."
echo "PASS: Sensitive key/secret/approval fields are redacted."
echo "PASS: /usr/local/bin/vodia-mcp-live-debug tails the MCP server journal in real time."
echo "NOTE: Debug tracing is observational only; it does not bypass approvals or safety controls."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message, click Debug, then reproduce the issue."
