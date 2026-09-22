#!/usr/bin/env bash
# Vodia MCP v0.14.9.69 — Marketplace deployment monitor
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.69"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-deployment-monitor-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

read_version(){
  python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
}

CURRENT="$(read_version)"
case "$CURRENT" in
  0.14.9.68) ;;
  0.14.9.69) echo "v0.14.9.69 already installed; verification mode." ;;
  *) fail "expected v0.14.9.68 or .69; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Marketplace deployment monitor ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

if [[ "$CURRENT" != "$TO_VER" ]]; then
  echo "[1/8] Patch staged backend — NO LIVE CHANGES"
  python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_MARKETPLACE_MONITOR_V69' in s:
    raise SystemExit(0)

import_anchor='''  DescribeInstancesCommand,
  RunInstancesCommand'''
if import_anchor not in s:
    raise SystemExit("PATCH ERROR: EC2 import anchor missing")
s=s.replace(import_anchor,'''  DescribeInstancesCommand,
  DescribeInstanceStatusCommand,
  RunInstancesCommand''',1)

status_anchor='''        const out = await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
        const instance = out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${instanceId}`);
        return scopedSuccess({'''
if status_anchor not in s:
    raise SystemExit("PATCH ERROR: deployment status reader anchor missing")

enhanced=r'''        const out = await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
        const instance = out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${instanceId}`);

        // Customer isolation: v0.14.9.68+ instances carry the customer tag.
        // Legacy instances are accepted only when already reconciled into this
        // customer's Marketplace deployment ledger.
        const ledger = loadMarketplaceDeploymentLedger();
        const ledgerRecord = ledger.deployments.find(row =>
          row?.instanceId === instanceId &&
          (!c.customerId || !row.customerId || row.customerId === c.customerId)
        ) || null;
        const taggedCustomerId = requiredInstanceTag(instance, "VodiaMspCustomerId");
        if (c.customerId && taggedCustomerId && taggedCustomerId !== c.customerId) {
          throw new Error("DEPLOYMENT_CUSTOMER_MISMATCH: instance belongs to another MSP customer.");
        }
        if (c.customerId && !taggedCustomerId && !ledgerRecord) {
          throw new Error("DEPLOYMENT_NOT_IN_CUSTOMER_LEDGER: legacy instance is not assigned to the selected customer.");
        }

        let instanceStatus = null;
        let statusChecksError = null;
        try {
          const statusOut = await client.send(new DescribeInstanceStatusCommand({
            InstanceIds: [instanceId],
            IncludeAllInstances: true
          }));
          instanceStatus = (statusOut.InstanceStatuses || [])[0] || null;
        } catch (statusError) {
          statusChecksError = String(statusError?.message || statusError);
        }

        const systemStatus = instanceStatus?.SystemStatus?.Status || null;
        const ec2InstanceStatus = instanceStatus?.InstanceStatus?.Status || null;
        const checks = [systemStatus, ec2InstanceStatus];
        const checksPassed = checks.filter(value => value === "ok").length;
        const checkedAt = new Date().toISOString();
        const pbxName = requiredInstanceTag(instance, "Name");
        const marketplaceAgreementId = requiredInstanceTag(instance, "VodiaMarketplaceAgreementId") || ledgerRecord?.agreementId || null;
        const marketplaceProductId = requiredInstanceTag(instance, "VodiaMarketplaceProductId") || ledgerRecord?.productId || null;

        if (ledgerRecord) {
          upsertMarketplaceDeployment({
            ...ledgerRecord,
            name: pbxName || ledgerRecord.name || null,
            instanceState: instance.State?.Name || ledgerRecord.instanceState || null,
            publicIpAddress: instance.PublicIpAddress || null,
            publicDnsName: instance.PublicDnsName || null,
            lastStatusCheckAt: checkedAt,
            source: "deployment-monitor"
          });
        }

        return scopedSuccess({'''
s=s.replace(status_anchor,enhanced,1)

fields_anchor='''          launchTime: instance.LaunchTime || null,
          changesMade: false'''
if fields_anchor not in s:
    raise SystemExit("PATCH ERROR: deployment status output anchor missing")
fields=r'''          launchTime: instance.LaunchTime || null,
          checkedAt,
          pbxName,
          marketplaceAgreementId,
          marketplaceProductId,
          customerOwnershipVerified: Boolean(!c.customerId || taggedCustomerId === c.customerId || ledgerRecord),
          statusChecksAvailable: Boolean(instanceStatus),
          statusChecksPassed: checksPassed,
          statusChecksTotal: 2,
          statusCheckSummary: instanceStatus ? `${checksPassed}/2 passed` : "Unavailable",
          systemStatus,
          instanceStatus: ec2InstanceStatus,
          statusChecksError,
          scheduledEvents: (instanceStatus?.Events || []).map(event => ({
            code: event.Code || null,
            description: event.Description || null,
            notBefore: event.NotBefore || null,
            notAfter: event.NotAfter || null
          })),
          monitoringState: instance.Monitoring?.State || null,
          vpcId: instance.VpcId || null,
          subnetId: instance.SubnetId || null,
          securityGroupIds: (instance.SecurityGroups || []).map(group => group.GroupId).filter(Boolean),
          keyName: instance.KeyName || null,
          architecture: instance.Architecture || null,
          platformDetails: instance.PlatformDetails || null,
          rootDeviceName: instance.RootDeviceName || null,
          pbxApplicationReadiness: "NOT_CHECKED",
          changesMade: false'''
s=s.replace(fields_anchor,fields,1)

desc='description: "Reads the EC2 state and network addresses of a deployed Vodia PBX instance.",'
if desc in s:
    s=s.replace(desc,'description: "Reads a customer-owned Vodia PBX EC2 deployment, AWS status checks, network addresses, configuration, scheduled events, and Marketplace binding.",',1)

marker='const VODIA_EC2_LAUNCH_VERIFY_V68 = true;'
if marker not in s:
    raise SystemExit("PATCH ERROR: v0.14.9.68 verification marker missing")
s=s.replace(marker,marker+'\nconst VODIA_MARKETPLACE_MONITOR_V69 = true;',1)
p.write_text(s)
PY

  echo "[2/8] Patch staged guided UI"
  python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'data-deployment-monitor="v0.14.9.69"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-deployment-monitor="v0.14.9.69"',1)

if '.deployment-monitor{' not in s:
    css=r'''
.deployment-monitor{margin-top:12px;border:1px solid color-mix(in srgb,CanvasText 16%,transparent);border-radius:12px;padding:12px;background:color-mix(in srgb,CanvasText 4%,transparent)}
.deployment-monitor-head{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:8px}
.deployment-monitor-title{font-weight:750}.deployment-monitor-badge{font-size:10px;font-weight:750;border-radius:999px;padding:4px 8px;background:color-mix(in srgb,CanvasText 10%,transparent)}
.deployment-monitor-select{margin:0 0 9px}.deployment-monitor-select label{display:block;font-size:10px;font-weight:700;margin-bottom:4px}.deployment-monitor-output{white-space:pre-wrap;word-break:break-word;margin:0;padding:10px;border-radius:9px;background:color-mix(in srgb,CanvasText 6%,transparent);font:11px/1.5 ui-monospace,SFMono-Regular,Consolas,monospace}
.deployment-monitor-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin-top:9px}.deployment-monitor-actions button{width:auto}
.deployment-monitor-note{font-size:10px;opacity:.72;margin-top:8px}
'''
    s=s.replace('</style>',css+'</style>',1)

render_anchor='  function renderMarketplaceSubscription(active,message,subscription=null){'
if render_anchor not in s:
    raise SystemExit("PATCH ERROR: Marketplace renderer anchor missing")

helpers=r'''  let marketplaceMonitorTimer=null;
  let marketplaceMonitorGeneration=0;
  let marketplaceMonitorBusy=false;
  let currentMonitoredDeployment=null;
  let marketplaceMonitoredDeployments=[];

  function ensureMarketplaceDeploymentMonitor(){
    let box=$("marketplaceDeploymentMonitor");
    if(box) return box;
    const summary=$("marketplaceSubscriptionSummary");
    if(!summary) return null;
    box=document.createElement("section");
    box.id="marketplaceDeploymentMonitor";
    box.className="deployment-monitor hidden";
    box.innerHTML=`<div class="deployment-monitor-head"><span class="deployment-monitor-title">Live deployment monitor</span><span id="marketplaceMonitorBadge" class="deployment-monitor-badge">Waiting</span></div><div class="deployment-monitor-select"><label for="marketplaceMonitorSelect">Deployment to monitor</label><select id="marketplaceMonitorSelect"></select></div><pre id="marketplaceMonitorOutput" class="deployment-monitor-output"></pre><div class="deployment-monitor-actions"><button id="refreshMarketplaceMonitor" class="secondary" type="button">Refresh machine status</button><span id="marketplaceMonitorActivity" class="muted"></span></div><div class="deployment-monitor-note">AWS machine status and Vodia application readiness are separate. EC2 running does not by itself mean that the PBX web service is ready.</div>`;
    summary.insertAdjacentElement("afterend",box);
    $("refreshMarketplaceMonitor").addEventListener("click",()=>refreshMarketplaceDeploymentMonitor(true));
    $("marketplaceMonitorSelect").addEventListener("change",event=>{
      const selected=marketplaceMonitoredDeployments.find(item=>
        (item.region+"|"+item.instanceId)===event.target.value
      );
      if(selected) startMarketplaceDeploymentMonitor(selected);
    });
    return box;
  }

  function stopMarketplaceDeploymentMonitor(clearDeployment=false){
    marketplaceMonitorGeneration++;
    if(marketplaceMonitorTimer){clearTimeout(marketplaceMonitorTimer);marketplaceMonitorTimer=null;}
    marketplaceMonitorBusy=false;
    if(clearDeployment) currentMonitoredDeployment=null;
  }

  function renderMarketplaceDeploymentMonitor(status,error=null){
    const box=ensureMarketplaceDeploymentMonitor();
    if(!box) return;
    box.classList.remove("hidden");
    const deployment=currentMonitoredDeployment||{};
    const state=String(status?.state||deployment.instanceState||"unknown").toLowerCase();
    $("marketplaceMonitorBadge").textContent=error?"Error":state;
    const events=Array.isArray(status?.scheduledEvents)?status.scheduledEvents:[];
    const checked=status?.checkedAt?new Date(status.checkedAt).toLocaleString():new Date().toLocaleString();
    const lines=[
      "PBX: "+(status?.pbxName||deployment.pbxName||"Unknown"),
      "Instance ID: "+(status?.instanceId||deployment.instanceId||"Unknown"),
      "Region: "+(status?.region||deployment.region||"Unknown"),
      "EC2 state: "+state,
      "AWS status checks: "+(status?.statusChecksAvailable
        ?(status.statusCheckSummary+" · system="+(status.systemStatus||"unknown")+" · instance="+(status.instanceStatus||"unknown"))
        :(status?.statusChecksError?"Unavailable · "+status.statusChecksError:"Waiting for AWS")),
      "Instance type: "+(status?.instanceType||"Unknown"),
      "AMI: "+(status?.imageId||"Unknown"),
      "Availability Zone: "+(status?.availabilityZone||"Unknown"),
      "Public IP: "+(status?.publicIpAddress||"Not assigned"),
      "Public DNS: "+(status?.publicDnsName||"Not assigned"),
      "Private IP: "+(status?.privateIpAddress||"Unknown"),
      "VPC / Subnet: "+[status?.vpcId,status?.subnetId].filter(Boolean).join(" / "),
      "Security groups: "+((status?.securityGroupIds||[]).join(", ")||"Unknown"),
      "Marketplace agreement: "+(status?.marketplaceAgreementId||deployment.agreementId||"Unknown"),
      "Vodia PBX readiness: "+(status?.pbxApplicationReadiness||"NOT_CHECKED"),
      events.length?("Scheduled AWS events: "+events.map(event=>event.code||event.description).filter(Boolean).join(", ")):"Scheduled AWS events: none",
      "Last checked: "+checked
    ];
    if(error) lines.push("Poll error: "+error);
    $("marketplaceMonitorOutput").textContent=lines.join("\n");
    $("marketplaceMonitorActivity").textContent=marketplaceMonitorBusy?"Checking AWS…":(error?"Automatic retry scheduled":"Monitoring while this step is open");
    reportSize();
  }

  function marketplaceMonitorDelay(state,error=false){
    if(error) return 30000;
    return ["pending","stopping","shutting-down"].includes(String(state||"").toLowerCase())?5000:30000;
  }

  function scheduleMarketplaceDeploymentMonitor(state,error=false){
    if(marketplaceMonitorTimer){clearTimeout(marketplaceMonitorTimer);marketplaceMonitorTimer=null;}
    const terminal=["stopped","terminated"].includes(String(state||"").toLowerCase());
    if(terminal||currentStep!==2||document.hidden||!currentMonitoredDeployment) return;
    const generation=marketplaceMonitorGeneration;
    marketplaceMonitorTimer=setTimeout(()=>{
      if(generation===marketplaceMonitorGeneration) refreshMarketplaceDeploymentMonitor(false);
    },marketplaceMonitorDelay(state,error));
  }

  async function refreshMarketplaceDeploymentMonitor(manual=false){
    const deployment=currentMonitoredDeployment;
    if(!deployment?.instanceId||!deployment?.region||marketplaceMonitorBusy) return;
    const generation=marketplaceMonitorGeneration;
    marketplaceMonitorBusy=true;
    if($("refreshMarketplaceMonitor")) $("refreshMarketplaceMonitor").disabled=true;
    if($("marketplaceMonitorActivity")) $("marketplaceMonitorActivity").textContent="Checking AWS…";
    try{
      const status=dataFrom(await callTool("aws_get_vodia_pbx_deployment_status",{
        customerId:customerId(),
        region:deployment.region,
        instanceId:deployment.instanceId
      }));
      if(generation!==marketplaceMonitorGeneration) return;
      if(status.instanceId!==deployment.instanceId) throw new Error("AWS returned a different instance ID; status was rejected.");
      marketplaceMonitorBusy=false;
      renderMarketplaceDeploymentMonitor({...status,region:deployment.region});
      scheduleMarketplaceDeploymentMonitor(status.state,false);
    }catch(e){
      if(generation!==marketplaceMonitorGeneration) return;
      marketplaceMonitorBusy=false;
      renderMarketplaceDeploymentMonitor(null,e.message||String(e));
      scheduleMarketplaceDeploymentMonitor(deployment.instanceState,true);
    }finally{
      marketplaceMonitorBusy=false;
      if($("refreshMarketplaceMonitor")) $("refreshMarketplaceMonitor").disabled=false;
      if(manual) reportSize();
    }
  }

  function startMarketplaceDeploymentMonitor(deployment){
    if(!deployment?.instanceId||!deployment?.region){
      stopMarketplaceDeploymentMonitor(true);
      $("marketplaceDeploymentMonitor")?.classList.add("hidden");
      return;
    }
    const same=currentMonitoredDeployment?.instanceId===deployment.instanceId
      && currentMonitoredDeployment?.region===deployment.region;
    currentMonitoredDeployment={...deployment};
    ensureMarketplaceDeploymentMonitor()?.classList.remove("hidden");
    if(!same){
      stopMarketplaceDeploymentMonitor(false);
      renderMarketplaceDeploymentMonitor({
        ...deployment,
        state:deployment.instanceState,
        pbxApplicationReadiness:"NOT_CHECKED"
      });
    }
    if(currentStep===2&&!document.hidden) refreshMarketplaceDeploymentMonitor(false);
  }

  function configureMarketplaceDeploymentMonitor(deployments){
    marketplaceMonitoredDeployments=(deployments||[]).filter(item=>item?.instanceId&&item?.region);
    if(!marketplaceMonitoredDeployments.length){
      stopMarketplaceDeploymentMonitor(true);
      $("marketplaceDeploymentMonitor")?.classList.add("hidden");
      return;
    }
    ensureMarketplaceDeploymentMonitor();
    const select=$("marketplaceMonitorSelect");
    const previous=currentMonitoredDeployment
      ?(currentMonitoredDeployment.region+"|"+currentMonitoredDeployment.instanceId):"";
    select.innerHTML="";
    marketplaceMonitoredDeployments.forEach(item=>{
      const option=document.createElement("option");
      option.value=item.region+"|"+item.instanceId;
      option.textContent=[item.pbxName||"Vodia PBX",item.instanceId,item.region,item.instanceState||null].filter(Boolean).join(" · ");
      select.appendChild(option);
    });
    const selected=marketplaceMonitoredDeployments.find(item=>(item.region+"|"+item.instanceId)===previous)
      || marketplaceMonitoredDeployments[0];
    select.value=selected.region+"|"+selected.instanceId;
    startMarketplaceDeploymentMonitor(selected);
  }

  document.addEventListener("visibilitychange",()=>{
    if(document.hidden){
      if(marketplaceMonitorTimer){clearTimeout(marketplaceMonitorTimer);marketplaceMonitorTimer=null;}
    }else if(currentStep===2&&currentMonitoredDeployment){
      refreshMarketplaceDeploymentMonitor(false);
    }
  });

'''
s=s.replace(render_anchor,helpers+render_anchor,1)

message_anchor='''    setMsg("marketplaceMsg",message||(active'''
if message_anchor not in s:
    raise SystemExit("PATCH ERROR: Marketplace monitor start anchor missing")
monitor_start=r'''    const monitoredDeployments=agreements.filter(agreement=>{
      const usage=agreement?.deploymentUsage||{};
      return usage.instanceId&&usage.region&&usage.status!=="AVAILABLE";
    }).map(agreement=>({
      ...(agreement.deploymentUsage||{}),
      agreementId:agreement.agreementId||agreement.id||null
    }));
    if(active&&monitoredDeployments.length){
      configureMarketplaceDeploymentMonitor(monitoredDeployments);
    }else{
      configureMarketplaceDeploymentMonitor([]);
    }

'''
s=s.replace(message_anchor,monitor_start+message_anchor,1)

setstep_anchor='''  function setStep(step){
    currentStep=step;'''
if setstep_anchor not in s:
    raise SystemExit("PATCH ERROR: four-step router anchor missing")
setstep_new='''  function setStep(step){
    currentStep=step;
    if(step!==2){
      if(marketplaceMonitorTimer){clearTimeout(marketplaceMonitorTimer);marketplaceMonitorTimer=null;}
    }else if(currentMonitoredDeployment&&!document.hidden){
      queueMicrotask(()=>refreshMarketplaceDeploymentMonitor(false));
    }'''
s=s.replace(setstep_anchor,setstep_new,1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"', 'uiVersion:"0.14.9.69"', s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.27.0"}',s,count=1)
p.write_text(s)
PY

  python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.69/mcp-app.html',s,count=1)
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
fi

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_MARKETPLACE_MONITOR_V69' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "monitor marker missing"
grep -Fq 'DescribeInstanceStatusCommand' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "AWS status checks missing"
grep -Fq 'IncludeAllInstances: true' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "all-state status monitoring missing"
grep -Fq 'DEPLOYMENT_NOT_IN_CUSTOMER_LEDGER' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "customer ledger isolation missing"
grep -Fq 'statusCheckSummary' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "status check summary missing"
grep -Fq 'pbxApplicationReadiness: "NOT_CHECKED"' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "PBX readiness separation missing"
grep -Fq 'VODIA_EC2_LAUNCH_VERIFY_V68' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "v0.14.9.68 launch verification regression"
grep -Fq 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement protection regression"
echo "PASS: customer-scoped EC2 details, AWS 2/2 checks, events, ledger refresh, and readiness separation present"

echo "[4/8] Validate staged UI"
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
grep -Fq 'data-deployment-monitor="v0.14.9.69"' "$TMP/staged/msp-guided-app.html" || fail "UI monitor marker missing"
grep -Fq 'Live deployment monitor' "$TMP/staged/msp-guided-app.html" || fail "monitor panel missing"
grep -Fq 'Deployment to monitor' "$TMP/staged/msp-guided-app.html" || fail "multi-deployment selector missing"
grep -Fq 'Refresh machine status' "$TMP/staged/msp-guided-app.html" || fail "manual refresh missing"
grep -Fq 'refreshMarketplaceDeploymentMonitor' "$TMP/staged/msp-guided-app.html" || fail "automatic polling missing"
grep -Fq 'AWS status checks:' "$TMP/staged/msp-guided-app.html" || fail "AWS check display missing"
grep -Fq 'Vodia PBX readiness:' "$TMP/staged/msp-guided-app.html" || fail "readiness distinction missing"
grep -Fq 'uiVersion:"0.14.9.69"' "$TMP/staged/msp-guided-app.html" || fail "debug version marker missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.69/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "v0.14.9.69 UI URI missing"
echo "PASS: automatic/manual Marketplace deployment monitoring UI and JavaScript syntax verified"

if [[ "$CURRENT" != "$TO_VER" ]]; then
  echo "[5/8] Backup"
  mkdir -p "$BACKUP_DIR"
  cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
  cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
  cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
  cp -a "$VERSION" "$BACKUP_DIR/version.js"
  [[ -f /var/lib/vodia-mcp/aws-marketplace-deployments.json ]] && cp -a /var/lib/vodia-mcp/aws-marketplace-deployments.json "$BACKUP_DIR/" || true
  echo "PASS: $BACKUP_DIR"

  rollback(){
    echo "ROLLBACK: restoring v0.14.9.68 files"
    cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
    cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
    cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
    cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
    systemctl restart "$SERVICE" || true
  }
  trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

  echo "[6/8] Install + restart"
  install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
  install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
  install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
  install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
  systemctl restart "$SERVICE"
else
  echo "[5/8]-[6/8] Backup/install skipped"
fi

echo "[7/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.69"' <<<"$HEALTH" || fail "health does not report v0.14.9.69"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.69 installed and verified."
echo "PASS: Marketplace IN USE deployments now open a live customer-scoped EC2 monitor."
echo "PASS: pending/transitional instances poll every 5 seconds; running instances poll every 30 seconds while Marketplace is open."
echo "PASS: exact ID, EC2 state, AWS 2/2 checks, IP/DNS, instance configuration, Marketplace binding, events, and last-check time are displayed."
echo "PASS: EC2 machine status remains explicitly separate from Vodia PBX application readiness."
echo "NOTE: this installer does not launch, stop, reboot, or terminate any EC2 instance."
[[ -d "$BACKUP_DIR" ]] && echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh card, select the customer, go to Marketplace, and click Check subscription."
