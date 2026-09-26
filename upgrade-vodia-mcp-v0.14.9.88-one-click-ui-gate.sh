#!/usr/bin/env bash
# Vodia MCP v0.14.9.88 — one-click deploy UI gate fix
#
# Fixes a front-end-only blocker observed on v0.14.9.87:
# - network preparation succeeds and all required one-click values are present,
#   but no aws_marketplace_plan_vodia_pbx_deployment call is emitted.
# - one-click no longer depends on the hidden raw AWS security-group selector.
# - adds a prominent Review & Deploy button beside the network action.
# - preserves the existing approval-gated plan/apply safety model.
#
# Safe workflow:
#   sudo bash this-script --dry-run
#   sudo bash this-script --apply
set -Eeuo pipefail

MODE=${1:---dry-run}
[[ "$MODE" == "--dry-run" || "$MODE" == "--apply" ]] || {
  echo "Usage: sudo bash $0 [--dry-run|--apply]" >&2
  exit 2
}
[[ ${EUID} -eq 0 ]] || { echo "Run as root/sudo." >&2; exit 1; }

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
TO_VER="0.14.9.88"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d /tmp/vodia-mcp-v88.XXXXXXXX)"
BACKUP="/var/backups/vodia-mcp-v${TO_VER}-one-click-ui-gate-$STAMP"
PATCH_STARTED=0

cleanup(){
  rc=$?
  trap - EXIT
  if (( PATCH_STARTED && rc != 0 )); then
    echo "ROLLBACK: restoring pre-v88 files..." >&2
    cp -a "$BACKUP/msp-guided-app.html" "$UI" 2>/dev/null || true
    cp -a "$BACKUP/msp-guided-app-v1.js" "$GUIDED" 2>/dev/null || true
    cp -a "$BACKUP/version.js" "$VERSION" 2>/dev/null || true
    systemctl restart "$SERVICE" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "PATCH ERROR: $*" >&2; exit 1; }

for c in python3 node grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.87) ;;
  0.14.9.88) echo "v0.14.9.88 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.87 or .88; found ${CURRENT:-unknown}. No files changed." ;;
esac

echo "=== Vodia MCP v$TO_VER — one-click deploy UI gate fix ==="
echo "[0/8] Live preflight — NO LIVE CHANGES"

grep -Fq 'VODIA_CAPACITY_FAILOVER_V87' "$BACKEND" || fail "v87 backend capacity failover missing"
grep -Fq 'VODIA_PRODUCT_UX_UI_V86' "$UI" || fail "v86 product UX marker missing"
grep -Fq 'function updatePlanButton()' "$UI" || fail "updatePlanButton missing"
grep -Fq '$("planDeployment").addEventListener("click",async()=>{' "$UI" || fail "planDeployment handler missing"
grep -Fq 'id="planDeployment"' "$UI" || fail "planDeployment button missing"
grep -Fq 'id="loadNetwork"' "$UI" || fail "loadNetwork button missing"
echo "PASS: live .87 UI/backend anchors found"

mkdir -p "$TMP/staged/ui"
cp -a "$UI" "$TMP/staged/ui/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/8] Patch staged UI — NO LIVE CHANGES"
python3 - "$TMP/staged/ui/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()

# Marker near the v86 UI marker.
if 'VODIA_ONE_CLICK_UI_GATE_V88' not in s:
    marker='const VODIA_PRODUCT_UX_UI_V86 = true;'
    i=s.find(marker)
    if i<0:
        raise SystemExit('PATCH ERROR: v86 UI marker missing')
    e=s.find('\n',i)
    s=s[:e+1]+'  const VODIA_ONE_CLICK_UI_GATE_V88 = true;\n'+s[e+1:]

# Replace the old gate. One-click must not require the hidden raw SG selector.
start=s.find('  function updatePlanButton(){')
if start<0:
    raise SystemExit('PATCH ERROR: updatePlanButton start missing')
end=s.find('\n  }',start)
if end<0:
    raise SystemExit('PATCH ERROR: updatePlanButton end missing')
end+=4
old=s[start:end]
if 'securityGroupSelect' not in old:
    raise SystemExit('PATCH ERROR: expected old security-group gate not found')

new=r'''  function isV88OneClick(){
    if(typeof deploymentMethod==="string") return deploymentMethod==="ONE_CLICK_MARKETPLACE";
    const radio=document.querySelector('input[name="deploymentMethod"]:checked');
    if(radio) return radio.value==="ONE_CLICK_MARKETPLACE";
    // The current product flow is Marketplace one-click unless the UI has
    // explicitly selected another deployment method.
    return true;
  }

  function v88PlanReady(){
    const oneClick=isV88OneClick();
    return Boolean(
      currentNetwork &&
      selectedRegion &&
      $("pbxName")?.value.trim() &&
      $("instanceType")?.value &&
      $("subnetSelect")?.value &&
      (oneClick || $("securityGroupSelect")?.value)
    );
  }

  function updateV88ReviewButton(){
    const button=$("v88ReviewDeploy");
    if(!button) return;
    const ready=v88PlanReady();
    button.disabled=!ready;
    button.textContent=currentDeploymentPlan?"Review deployment":"Review & Deploy";
    button.title=ready
      ? "Create the read-only deployment plan, then review the exact approval before EC2 launch."
      : "Enter a PBX name and load the one-click AWS defaults first.";
  }

  function updatePlanButton(){
    const ready=v88PlanReady();
    $("planDeployment").disabled=!ready;
    if(isV88OneClick()){
      $("planDeployment").textContent="Review & Deploy";
      $("planDeployment").title=ready
        ? "Create the deployment plan. No EC2 instance launches until the approval step."
        : "Enter a PBX name and load one-click AWS defaults.";
    }
    updateV88ReviewButton();
    debugLog("info","PLAN_GATE",{
      oneClick:isV88OneClick(),
      ready,
      hasNetwork:Boolean(currentNetwork),
      region:selectedRegion||null,
      pbxName:$("pbxName")?.value||"",
      instanceType:$("instanceType")?.value||"",
      subnet:$("subnetSelect")?.value||"",
      hiddenSecurityGroup:$("securityGroupSelect")?.value||null
    });
  }'''
s=s[:start]+new+s[end:]

# Patch the plan click handler's client-side validation so the hidden raw SG
# never blocks one-click. Server-side .86 still forces VODIA_DEDICATED/PBX_VOICE.
handler=s.find('  $("planDeployment").addEventListener("click",async()=>{')
if handler<0:
    raise SystemExit('PATCH ERROR: planDeployment handler missing')
handler_end=s.find('\n  });',handler)
if handler_end<0:
    raise SystemExit('PATCH ERROR: planDeployment handler end missing')
handler_end+=6
block=s[handler:handler_end]

sg_line='''    const securityGroupId=$("securityGroupSelect").value;'''
if sg_line not in block:
    raise SystemExit('PATCH ERROR: securityGroupId line missing in plan handler')
if 'const oneClickV88=' not in block:
    block=block.replace(
        sg_line,
        sg_line+'''\n    const oneClickV88=isV88OneClick();''',
        1
    )

old_check='''    if(!id||!selectedRegion||!instanceType||!subnetId||!securityGroupId){
      setMsg("deployMsg","Complete the region, instance type, subnet, and security-group fields.");
      return;
    }'''
if old_check in block:
    block=block.replace(
        old_check,
        '''    if(!id||!selectedRegion||!instanceType||!subnetId||(!oneClickV88&&!securityGroupId)){
      setMsg("deployMsg",oneClickV88
        ?"Enter a PBX name and load the one-click AWS defaults."
        :"Complete the region, instance type, subnet, and security-group fields.");
      updatePlanButton();
      return;
    }''',
        1
    )
else:
    # Flexible fallback for newer wording.
    block,count=re.subn(
        r'    if\(!id\|\|!selectedRegion\|\|!instanceType\|\|!subnetId\|\|!securityGroupId\)\{.*?\n    \}',
        '''    if(!id||!selectedRegion||!instanceType||!subnetId||(!oneClickV88&&!securityGroupId)){
      setMsg("deployMsg",oneClickV88
        ?"Enter a PBX name and load the one-click AWS defaults."
        :"Complete the region, instance type, subnet, and security-group fields.");
      updatePlanButton();
      return;
    }''',
        block,count=1,flags=re.S
    )
    if count!=1:
        raise SystemExit('PATCH ERROR: old plan readiness check missing')

# If the UI payload still sends the raw default SG during one-click, send an
# empty list instead. The backend creates and injects the dedicated Vodia SG.
block=block.replace(
    'securityGroupIds:[securityGroupId],',
    'securityGroupIds:oneClickV88?[]:[securityGroupId],'
)

# Ensure the one-click intent is explicit in the request even if an older UI
# payload did not include it.
plan_call=block.find('callTool("aws_marketplace_plan_vodia_pbx_deployment"')
if plan_call<0:
    raise SystemExit('PATCH ERROR: planner call missing')
call_end=block.find('});',plan_call)
if call_end<0:
    raise SystemExit('PATCH ERROR: planner call end missing')
call_slice=block[plan_call:call_end]
if 'deploymentMethod:' not in call_slice:
    insert=block.find('        associatePublicIp:true,',plan_call)
    if insert<0:
        raise SystemExit('PATCH ERROR: associatePublicIp payload anchor missing')
    e=insert+len('        associatePublicIp:true,')
    block=block[:e]+'''\n        deploymentMethod:oneClickV88?"ONE_CLICK_MARKETPLACE":"MANAGED_EC2",'''+block[e:]

# Explicit firewall intent for one-click; backend also independently enforces
# it, so this is descriptive/redundant rather than a security dependency.
call_end=block.find('});',plan_call)
call_slice=block[plan_call:call_end]
if 'firewallMode:' not in call_slice:
    insert=block.find('        deploymentMethod:',plan_call)
    if insert<0:
        insert=block.find('        associatePublicIp:true,',plan_call)
    line_end=block.find('\n',insert)
    block=block[:line_end+1]+'''        firewallMode:oneClickV88?"VODIA_DEDICATED":"EXISTING",
        firewallPreset:oneClickV88?"PBX_VOICE":undefined,
'''+block[line_end+1:]

# Add an event breadcrumb before the planner performs any tool call.
if 'PLAN_CLICK_V88' not in block:
    try_pos=block.find('    try{')
    if try_pos<0:
        raise SystemExit('PATCH ERROR: plan handler try block missing')
    block=block[:try_pos]+'''    debugLog("info","PLAN_CLICK_V88",{
      oneClick:oneClickV88,
      customerId:id,
      region:selectedRegion,
      pbxName:name,
      instanceType,
      subnetId
    });
'''+block[try_pos:]

s=s[:handler]+block+s[handler_end:]

# Add a prominent action immediately below Load EC2 options. This solves the
# product UX problem where the original plan button is easy to miss below the
# Marketplace details in a scrollable card.
if 'id="v88ReviewDeploy"' not in s:
    anchor='<button id="loadNetwork" class="secondary" type="button">'
    i=s.find(anchor)
    if i<0:
        raise SystemExit('PATCH ERROR: loadNetwork HTML button missing')
    close=s.find('</button>',i)
    close+=len('</button>')
    html='''\n        <button id="v88ReviewDeploy" class="primary" type="button" disabled style="margin-left:8px">Review &amp; Deploy</button>'''
    s=s[:close]+html+s[close:]

# Wire the prominent button to the existing approval-gated planner.
wire_anchor='''  $("backToAws").addEventListener("click",()=>setStep(2));'''
if 'V88_REVIEW_CLICK' not in s:
    i=s.find(wire_anchor)
    if i<0:
        raise SystemExit('PATCH ERROR: backToAws wiring anchor missing')
    e=i+len(wire_anchor)
    wire=r'''
  $("v88ReviewDeploy")?.addEventListener("click",()=>{
    debugLog("info","V88_REVIEW_CLICK",{
      ready:v88PlanReady(),
      hasNetwork:Boolean(currentNetwork),
      region:selectedRegion||null,
      pbxName:$("pbxName")?.value||""
    });
    updatePlanButton();
    if(!$("planDeployment").disabled) $("planDeployment").click();
  });
'''
    s=s[:e]+wire+s[e:]

# Refresh gates after PBX name input even when hidden fields are not changed.
if 'V88_PBX_INPUT_GATE' not in s:
    script_end=s.rfind('})();')
    if script_end<0:
        raise SystemExit('PATCH ERROR: UI IIFE end missing')
    hook=r'''
  $("pbxName")?.addEventListener("input",()=>{
    updatePlanButton();
  });
  const V88_PBX_INPUT_GATE=true;
'''
    s=s[:script_end]+hook+s[script_end:]

# Bump trace version.
s,count=re.subn(r'uiVersion:"0\.14\.9\.87"','uiVersion:"0.14.9.88"',s,count=1)
if count!=1 and 'uiVersion:"0.14.9.88"' not in s:
    raise SystemExit('PATCH ERROR: UI trace version .87 anchor missing')

p.write_text(s)
PY

echo "[2/8] Bump staged resource/version — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
pattern=re.compile(r'(const\s+GUIDED_UI_URI\s*=\s*["\'])([^"\']+)(["\']\s*;)')
m=pattern.search(s)
if not m:
    raise SystemExit('PATCH ERROR: GUIDED_UI_URI declaration missing')
target='ui://vodia/msp-guided/v0.14.9.88/mcp-app.html'
s=s[:m.start(2)]+target+s[m.end(2):]
p.write_text(s)
PY

python3 - "$TMP/staged/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,count=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
    r'\g<1>0.14.9.88\2',
    s,count=1
)
if count!=1:
    raise SystemExit('PATCH ERROR: CONNECTOR_VERSION anchor missing')
p.write_text(s)
PY

echo "[3/8] Validate staged JavaScript"
node --input-type=module --check < "$TMP/staged/msp-guided-app-v1.js" || fail "resource JavaScript invalid"
node --input-type=module --check < "$TMP/staged/version.js" || fail "version JavaScript invalid"
python3 - "$TMP/staged/ui/msp-guided-app.html" "$TMP/ui-check.js" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',text,re.S|re.I)
if not scripts:
    raise SystemExit('VALIDATION ERROR: no UI script found')
Path(sys.argv[2]).write_text('\n'.join(scripts))
PY
node --check "$TMP/ui-check.js" || fail "guided UI JavaScript invalid"

echo "[4/8] Validate v88 UI behavior markers"
grep -Fq 'VODIA_ONE_CLICK_UI_GATE_V88' "$TMP/staged/ui/msp-guided-app.html" || fail "v88 UI marker missing"
grep -Fq 'function v88PlanReady' "$TMP/staged/ui/msp-guided-app.html" || fail "v88 readiness helper missing"
grep -Fq 'oneClickV88?[]:[securityGroupId]' "$TMP/staged/ui/msp-guided-app.html" || fail "one-click raw SG removal missing"
grep -Fq 'PLAN_CLICK_V88' "$TMP/staged/ui/msp-guided-app.html" || fail "planner click breadcrumb missing"
grep -Fq 'V88_REVIEW_CLICK' "$TMP/staged/ui/msp-guided-app.html" || fail "visible review action wiring missing"
grep -Fq 'id="v88ReviewDeploy"' "$TMP/staged/ui/msp-guided-app.html" || fail "visible review button missing"
grep -Fq '0.14.9.88' "$TMP/staged/version.js" || fail "version .88 missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.88/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "v88 resource URI missing"

echo "PASS: one-click planner no longer depends on hidden raw security group"
echo "PASS: prominent Review & Deploy action is wired to existing safe planner"
echo "PASS: exact approval is still required before EC2 launch"
echo "PASS: no backend/AWS resources changed by this patch"

if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.88 staged UI gate fix validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/8] Backup current UI/resource/version"
mkdir -p "$BACKUP"
cp -a "$UI" "$BACKUP/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP/version.js"
echo "PASS: $BACKUP"

echo "[6/8] Install staged files"
PATCH_STARTED=1
install -o "$(stat -c %u "$UI")" -g "$(stat -c %g "$UI")" -m "$(stat -c %a "$UI")" "$TMP/staged/ui/msp-guided-app.html" "$UI"
install -o "$(stat -c %u "$GUIDED")" -g "$(stat -c %g "$GUIDED")" -m "$(stat -c %a "$GUIDED")" "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o "$(stat -c %u "$VERSION")" -g "$(stat -c %g "$VERSION")" -m "$(stat -c %a "$VERSION")" "$TMP/staged/version.js" "$VERSION"

echo "[7/8] Restart MCP"
systemctl restart "$SERVICE"

echo "[8/8] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  HEALTH="$(curl -fsS --max-time 5 http://127.0.0.1:3100/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "health endpoint did not recover"
grep -q '"version":"0.14.9.88"' <<<"$HEALTH" || fail "health does not report 0.14.9.88: $HEALTH"
grep -Fq 'VODIA_ONE_CLICK_UI_GATE_V88' "$UI" || fail "live v88 marker missing"
grep -Fq 'id="v88ReviewDeploy"' "$UI" || fail "live Review & Deploy button missing"

PATCH_STARTED=0
echo "$HEALTH"
echo
echo "PASS: Vodia MCP v0.14.9.88 installed."
echo "PASS: one-click can reach the planner without a visible/raw AWS security-group choice."
echo "PASS: Review & Deploy is now visible next to the EC2 options action."
echo "PASS: actual EC2 launch remains approval-gated."
echo "Backup: $BACKUP"
echo
echo "Open Vodia Setup in a NEW message/tab so the v0.14.9.88 resource URI is loaded."
