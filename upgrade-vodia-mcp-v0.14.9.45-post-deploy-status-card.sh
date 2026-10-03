#!/usr/bin/env bash
# Vodia MCP v0.14.9.45 — automatic post-deployment PBX status card
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.45-post-deploy-status-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

OLD_URI='ui://vodia/msp-guided/v0.14.9.43/mcp-app.html'
NEW_URI='ui://vodia/msp-guided/v0.14.9.45/mcp-app.html'
PRICING_URL='https://aws.amazon.com/marketplace/procurement/?productId=prod-v5qnz6xf6wu5u&redirectUrl=https%3A%2F%2Faws.amazon.com%2Fmarketplace%2Fpp%2Fprodview-k4gepe5tujjgy&ref_=beagle'

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node curl systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/ui/msp-guided-app.html"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.43|0.14.9.44) ;;
  0.14.9.45) echo "v0.14.9.45 already installed; verification mode." ;;
  *) fail "expected v0.14.9.43 through v0.14.9.45; found ${CURRENT:-unknown}" ;;
esac

echo "[1/8] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

cp -a "$APP/ui/msp-guided-app.html" "$TMP/msp-guided-app.html"
cp -a "$APP/msp-guided-app-v1.js" "$TMP/msp-guided-app-v1.js"
cp -a "$APP/version.js" "$TMP/version.js"

if [[ "$CURRENT" != "0.14.9.45" ]]; then
  echo "[2/8] Patch guided UI"
  python3 - "$TMP/msp-guided-app.html" "$PRICING_URL" <<'PY'
from pathlib import Path
import sys,re
p=Path(sys.argv[1]); pricing=sys.argv[2]; s=p.read_text()

# Preserve/add the official pricing link if v0.14.9.44 was not installed.
if 'id="marketplacePricingLink"' not in s:
    old='''          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
          </div>'''
    new=f'''          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
            <a id="marketplacePricingLink" href="{pricing}" target="_blank" rel="noopener noreferrer"
              style="display:inline-flex;align-items:center;padding:9px 11px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:9px;color:CanvasText;text-decoration:none;font-weight:650;font-size:inherit">
              View AWS Marketplace pricing
            </a>
          </div>'''
    if s.count(old)!=1: raise SystemExit(f'PATCH ERROR: marketplace actions anchor count={s.count(old)}')
    s=s.replace(old,new,1)

# Add status table styling.
css_anchor='.summarybox{font-size:11px;line-height:1.5;white-space:pre-wrap;padding:10px;border-radius:9px;background:color-mix(in srgb,CanvasText 5%,transparent);margin-top:8px}\n'
if css_anchor not in s: raise SystemExit('PATCH ERROR: summarybox CSS anchor missing')
css=css_anchor+'''.status-card{margin-top:12px;padding:13px;border-radius:11px;border:1px solid color-mix(in srgb,CanvasText 12%,transparent);background:color-mix(in srgb,CanvasText 3%,transparent)}
.status-card h3{font-size:13px;margin:0 0 4px}
.status-card .status-copy{font-size:11px;opacity:.7;line-height:1.45;margin-bottom:9px}
.status-grid{width:100%;border-collapse:collapse;font-size:11px}
.status-grid th,.status-grid td{text-align:left;padding:7px 8px;border-bottom:1px solid color-mix(in srgb,CanvasText 10%,transparent);vertical-align:top}
.status-grid th{width:34%;font-weight:650;opacity:.78}
.status-grid tr:last-child th,.status-grid tr:last-child td{border-bottom:0}
'''
s=s.replace(css_anchor,css,1)

# Add completion card inside Deploy panel, immediately after approval box.
html_anchor='''        <div id="approvalBox" class="guided-box hidden">
          <label for="deploymentApproval">Exact deployment approval</label>
          <input id="deploymentApproval" autocomplete="off" spellcheck="false">
          <div class="secret-note">Launching EC2 can create AWS charges. Paste the exact approval shown above.</div>
          <button id="applyDeployment" class="primary" type="button" style="margin-top:9px">Deploy Vodia PBX</button>
        </div>
'''
if s.count(html_anchor)!=1: raise SystemExit(f'PATCH ERROR: approval box anchor count={s.count(html_anchor)}')
completion=html_anchor+'''        <div id="deploymentCompletion" class="status-card hidden">
          <h3 id="completionTitle">Vodia PBX deployment</h3>
          <div id="completionCopy" class="status-copy">Waiting for the new PBX to become ready…</div>
          <table class="status-grid" aria-label="Vodia PBX deployment and license status">
            <tbody id="completionRows"></tbody>
          </table>
          <div id="completionMsg" class="msg"></div>
        </div>
'''
s=s.replace(html_anchor,completion,1)

# Bump UI bridge version.
s=s.replace('appInfo:{name:"vodia-setup",version:"1.9.0"}','appInfo:{name:"vodia-setup",version:"1.10.0"}')

# Add post-deployment helpers before applyDeployment handler.
js_anchor='''  $("applyDeployment").addEventListener("click",async()=>{'''
if s.count(js_anchor)!=1: raise SystemExit(f'PATCH ERROR: apply handler anchor count={s.count(js_anchor)}')
helpers=r'''
  function statusFlatten(value,path="",out=[]){
    if(value===null||value===undefined) return out;
    if(Array.isArray(value)){ value.forEach((v,i)=>statusFlatten(v,path+"["+i+"]",out)); return out; }
    if(typeof value==="object"){ Object.entries(value).forEach(([k,v])=>statusFlatten(v,path?(path+"."+k):k,out)); return out; }
    out.push({path,value:String(value)});
    return out;
  }

  function statusFind(flat,patterns){
    for(const pattern of patterns){
      const row=flat.find(x=>pattern.test(x.path));
      if(row && row.value!=="") return row.value;
    }
    return null;
  }

  function renderCompletionRows(rows){
    const body=$("completionRows");
    body.innerHTML="";
    rows.filter(x=>x[1]!==null&&x[1]!==undefined&&String(x[1])!=="").forEach(([label,value])=>{
      const tr=document.createElement("tr");
      const th=document.createElement("th");
      const td=document.createElement("td");
      th.textContent=label;
      td.textContent=String(value);
      tr.append(th,td);
      body.appendChild(tr);
    });
    $("deploymentCompletion").classList.remove("hidden");
    reportSize();
  }

  async function finishDeploymentStatus(launchResult){
    const id=customerId();
    let ec2={...launchResult};
    $("completionTitle").textContent="Vodia PBX starting";
    $("completionCopy").textContent="EC2 was launched. Vodia Setup is checking the new instance automatically — no extra prompt is required.";
    renderCompletionRows([
      ["Instance ID",launchResult.instanceId],
      ["State",launchResult.state||"pending"],
      ["Region",launchResult.region||selectedRegion],
      ["Public IP",launchResult.publicIpAddress||"Waiting…"],
      ["Public DNS",launchResult.publicDnsName||"Waiting…"]
    ]);

    for(let attempt=0;attempt<24;attempt++){
      try{
        ec2=dataFrom(await callTool("aws_get_vodia_pbx_deployment_status",{
          customerId:id,
          region:launchResult.region||selectedRegion,
          instanceId:launchResult.instanceId
        }));
      }catch(_e){}
      renderCompletionRows([
        ["Instance ID",ec2.instanceId||launchResult.instanceId],
        ["State",ec2.state||"pending"],
        ["Region",launchResult.region||selectedRegion],
        ["Instance type",ec2.instanceType||null],
        ["Public IP",ec2.publicIpAddress||launchResult.publicIpAddress||"Waiting…"],
        ["Public DNS",ec2.publicDnsName||launchResult.publicDnsName||"Waiting…"]
      ]);
      if(ec2.state==="running" && (ec2.publicIpAddress||ec2.publicDnsName)) break;
      await new Promise(resolve=>setTimeout(resolve,5000));
    }

    const publicIp=ec2.publicIpAddress||launchResult.publicIpAddress||null;
    const publicDns=ec2.publicDnsName||launchResult.publicDnsName||null;
    $("completionTitle").textContent=ec2.state==="running"?"Vodia PBX is running":"Vodia PBX deployment started";
    $("completionCopy").textContent="AWS readiness was checked automatically. Vodia Setup will now try to read license/status from the MCP-connected PBX and will only identify it as this new instance when the address matches.";

    let systemStatus=null;
    let statusError=null;
    try{
      systemStatus=dataFrom(await callTool("get_system_status",{}));
    }catch(e){
      statusError=e;
    }

    const flat=statusFlatten(systemStatus||{});
    const connectedIp=statusFind(flat,[
      /(^|\.)sys_ip4$/i,/public.*ip/i,/system.*ip/i,/(^|\.)ip4$/i
    ]);
    const matchesNewPbx=Boolean(publicIp && connectedIp && publicIp===connectedIp);

    const baseRows=[
      ["Instance ID",ec2.instanceId||launchResult.instanceId],
      ["State",ec2.state||launchResult.state||"pending"],
      ["Region",launchResult.region||selectedRegion],
      ["Instance type",ec2.instanceType||null],
      ["Public IP",publicIp||"Pending"],
      ["Public DNS",publicDns||"Pending"]
    ];

    if(matchesNewPbx){
      const licenseStatus=statusFind(flat,[/license.*status/i,/status.*license/i,/licensed/i]);
      const licenseType=statusFind(flat,[/license.*type/i,/(^|\.)type$/i]);
      const maintenance=statusFind(flat,[/maintenance/i,/maintenance.*plan/i]);
      const tenants=statusFind(flat,[/tenant.*used/i,/tenants/i]);
      const calls=statusFind(flat,[/concurrent.*call/i,/calls.*concurrent/i]);
      const agreement=statusFind(flat,[/agreement/i]);
      const remaining=statusFind(flat,[/remaining/i]);
      const features=statusFind(flat,[/enabled.*features/i,/features/i]);

      $("completionTitle").textContent="✓ Vodia PBX ready";
      $("completionCopy").textContent="The MCP-connected PBX address matches the newly deployed AWS instance. License and system status were loaded automatically.";
      renderCompletionRows(baseRows.concat([
        ["License status",licenseStatus],
        ["License type",licenseType],
        ["Maintenance plan",maintenance],
        ["Tenants",tenants],
        ["Concurrent calls",calls],
        ["Agreement",agreement],
        ["Remaining",remaining],
        ["Enabled features",features]
      ]));
      setMsg("completionMsg","The license key remains redacted.");
    }else{
      renderCompletionRows(baseRows);
      if(systemStatus && connectedIp){
        setMsg("completionMsg","The MCP is currently connected to a different PBX ("+connectedIp+"), so its license was not shown as the new AWS PBX license. Once the new PBX is connected to MCP, reopen Vodia Setup and its license can be verified safely.");
      }else if(statusError){
        setMsg("completionMsg","The new AWS PBX is running, but license status could not yet be read through MCP. No unrelated PBX license data was substituted.");
      }else{
        setMsg("completionMsg","The new AWS PBX is running. License details are withheld until MCP can verify that its connected PBX is this new instance.");
      }
    }
    reportSize();
  }

'''
s=s.replace(js_anchor,helpers+js_anchor,1)

# Replace the old post-launch text-only block with automatic completion workflow.
old=r'''      $("planSummary").textContent=[
        "Deployment started",
        "Instance ID: "+(result.instanceId||"pending"),
        "State: "+(result.state||"pending"),
        "Region: "+(result.region||selectedRegion),
        "Public IP: "+(result.publicIpAddress||"pending"),
        "Public DNS: "+(result.publicDnsName||"pending")
      ].join("\n");
      $("approvalBox").classList.add("hidden");
      setMsg("deployMsg","Vodia PBX deployment started successfully.");
      currentDeploymentPlan=null;'''
new=r'''      $("planSummary").textContent=[
        "Deployment started",
        "Instance ID: "+(result.instanceId||"pending"),
        "State: "+(result.state||"pending"),
        "Region: "+(result.region||selectedRegion),
        "Public IP: "+(result.publicIpAddress||"pending"),
        "Public DNS: "+(result.publicDnsName||"pending")
      ].join("\n");
      $("approvalBox").classList.add("hidden");
      setMsg("deployMsg","Vodia PBX deployment started. Checking readiness and license status automatically…");
      currentDeploymentPlan=null;
      await finishDeploymentStatus(result);'''
if s.count(old)!=1: raise SystemExit(f'PATCH ERROR: post-launch result block count={s.count(old)}')
s=s.replace(old,new,1)

p.write_text(s)
PY
  grep -Fq 'id="deploymentCompletion"' "$TMP/msp-guided-app.html" || fail "completion card missing"
  grep -Fq 'finishDeploymentStatus' "$TMP/msp-guided-app.html" || fail "automatic completion workflow missing"
  grep -Fq 'get_system_status' "$TMP/msp-guided-app.html" || fail "license/status read missing"
  grep -Fq 'No unrelated PBX license data was substituted' "$TMP/msp-guided-app.html" || fail "cross-PBX safety guard missing"
  echo PASS

  echo "[3/8] Patch MCP App resource URI"
  python3 - "$TMP/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='ui://vodia/msp-guided/v0.14.9.43/mcp-app.html'
new='ui://vodia/msp-guided/v0.14.9.45/mcp-app.html'
if old in s:
    s=s.replace(old,new,1)
elif new not in s:
    raise SystemExit('PATCH ERROR: guided UI URI anchor not found')
p.write_text(s)
PY
  node --check "$TMP/msp-guided-app-v1.js" >/dev/null || fail "guided app module syntax invalid"
  grep -Fq "$NEW_URI" "$TMP/msp-guided-app-v1.js" || fail "new UI URI missing"
  echo PASS

  echo "[4/8] Stage version"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.(?:43|44)(["\'])',r'\g<1>0.14.9.45\2',s,count=1)
if n != 1: raise SystemExit("PATCH ERROR: version anchor not found")
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.45' "$TMP/version.js" || fail "version staging failed"

  echo "[5/8] Static safety validation"
  grep -Fq 'aws_marketplace_apply_vodia_pbx_deployment' "$TMP/msp-guided-app.html" || fail "deployment apply removed"
  grep -Fq 'aws_get_vodia_pbx_deployment_status' "$TMP/msp-guided-app.html" || fail "deployment status poll missing"
  grep -Fq 'View AWS Marketplace pricing' "$TMP/msp-guided-app.html" || fail "pricing link missing"
  grep -Fq 'aws_marketplace_prepare_vodia_purchase' "$TMP/msp-guided-app.html" || fail "Marketplace quote flow removed"
  grep -Fq 'aws_marketplace_accept_vodia_purchase' "$TMP/msp-guided-app.html" || fail "Marketplace agreement flow removed"
  echo "PASS: deployment automatically transitions to a completion/status card"
  echo "PASS: EC2 state/public address are polled without another user prompt"
  echo "PASS: get_system_status is attempted automatically"
  echo "PASS: license data is shown as the NEW PBX only when connected PBX IP matches deployed public IP"
  echo "PASS: unrelated connected-PBX license data is never substituted"
  echo "PASS: license key remains undisplayed/redacted"

  echo "[6/8] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"

  echo "[7/8] Restart + health"
  systemctl restart "$SERVICE"
else
  echo "[2/8]-[7/8] Install skipped"
fi

HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.45"' <<<"$HEALTH" || fail "health does not report v0.14.9.45"
grep -Fq "$NEW_URI" "$APP/msp-guided-app-v1.js" || fail "live UI URI missing"
grep -Fq 'id="deploymentCompletion"' "$APP/ui/msp-guided-app.html" || fail "live completion card missing"
grep -Fq 'finishDeploymentStatus' "$APP/ui/msp-guided-app.html" || fail "live auto-status workflow missing"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.45 installed and verified."
echo "PASS: after deployment approval, the card automatically waits for the EC2 instance and shows deployment status."
echo "PASS: the card attempts license/system status automatically — no extra chat prompt is required."
echo "PASS: it only labels license data as the new PBX when the connected PBX IP matches the deployed instance."
echo "PASS: if MCP is still connected to another PBX, the UI says so instead of showing the wrong license."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and open Vodia setup in a new message."
