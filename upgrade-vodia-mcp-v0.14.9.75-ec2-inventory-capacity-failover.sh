#!/usr/bin/env bash
# Vodia MCP v0.14.9.75 — EC2 account inventory + one-click capacity failover
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.75"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-ec2-inventory-capacity-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.74) ;;
  0.14.9.75) echo "v0.14.9.75 detected; verification/repair mode." ;;
  *) fail "expected v0.14.9.74 or .75; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v$TO_VER — EC2 account inventory + one-click capacity failover ==="
mkdir -p "$TMP/staged"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# ---------------------------------------------------------------------------
# A. Read-only EC2 inventory across the connected AWS account.
# ---------------------------------------------------------------------------
if 'VODIA_EC2_ACCOUNT_INVENTORY_V75' not in s:
    helper_anchor='function requiredInstanceTag(instance, key) {'
    hi=s.find(helper_anchor)
    if hi<0:
        raise SystemExit("PATCH ERROR: requiredInstanceTag helper anchor missing")
    helpers=r'''
const VODIA_EC2_ACCOUNT_INVENTORY_V75 = true;

function ec2InventoryTagMap(instance) {
  const out={};
  for (const tag of instance?.Tags || []) {
    if (tag?.Key) out[tag.Key]=tag.Value || "";
  }
  return out;
}

function normalizeEc2InventoryInstance(instance, region) {
  const tags=ec2InventoryTagMap(instance);
  return {
    instanceId:instance?.InstanceId || null,
    name:tags.Name || null,
    state:instance?.State?.Name || "unknown",
    instanceType:instance?.InstanceType || null,
    region,
    availabilityZone:instance?.Placement?.AvailabilityZone || null,
    imageId:instance?.ImageId || null,
    launchTime:instance?.LaunchTime ? new Date(instance.LaunchTime).toISOString() : null,
    publicIpAddress:instance?.PublicIpAddress || null,
    privateIpAddress:instance?.PrivateIpAddress || null,
    publicDnsName:instance?.PublicDnsName || null,
    privateDnsName:instance?.PrivateDnsName || null,
    vpcId:instance?.VpcId || null,
    subnetId:instance?.SubnetId || null,
    architecture:instance?.Architecture || null,
    platformDetails:instance?.PlatformDetails || null,
    managedByVodia:tags.ManagedBy==="VodiaMCP",
    vodiaMarketplaceProductId:tags.VodiaMarketplaceProductId || null,
    vodiaMarketplaceAgreementId:tags.VodiaMarketplaceAgreementId || null,
    vodiaMspCustomerId:tags.VodiaMspCustomerId || null,
    vodiaDeploymentMethod:tags.VodiaDeploymentMethod || null
  };
}

async function listCustomerEc2Inventory(roleArn, externalId, requestedRegion=null, includeTerminated=false) {
  const credentials=customerCredentials(roleArn,externalId);
  let regions=[];
  if (requestedRegion) {
    regions=[requestedRegion];
  } else {
    const discovery=new EC2Client({region:AWS_DISCOVERY_REGION,credentials});
    const regionOut=await discovery.send(new DescribeRegionsCommand({AllRegions:false}));
    regions=(regionOut.Regions || []).map(r=>r.RegionName).filter(Boolean).sort();
  }

  const scanRegion=async(region)=>{
    const client=new EC2Client({region,credentials});
    const instances=[];
    let nextToken;
    do {
      const out=await client.send(new DescribeInstancesCommand({NextToken:nextToken}));
      for (const reservation of out.Reservations || []) {
        for (const instance of reservation.Instances || []) {
          const normalized=normalizeEc2InventoryInstance(instance,region);
          if (!includeTerminated && normalized.state==="terminated") continue;
          instances.push(normalized);
        }
      }
      nextToken=out.NextToken;
    } while(nextToken);
    return instances;
  };

  const settled=await Promise.allSettled(regions.map(region=>scanRegion(region)));
  const instances=[];
  const regionErrors=[];
  settled.forEach((result,index)=>{
    if (result.status==="fulfilled") instances.push(...result.value);
    else regionErrors.push({region:regions[index],error:String(result.reason?.message || result.reason)});
  });
  instances.sort((a,b)=>{
    const stateOrder={running:0,pending:1,stopping:2,stopped:3,"shutting-down":4,terminated:5,unknown:6};
    const sa=stateOrder[a.state] ?? 9, sb=stateOrder[b.state] ?? 9;
    if(sa!==sb) return sa-sb;
    return String(a.name||a.instanceId||"").localeCompare(String(b.name||b.instanceId||""),undefined,{sensitivity:"base"});
  });
  return {
    instances,
    regionsScanned:regions.length,
    regionErrors,
    counts:{
      total:instances.length,
      running:instances.filter(x=>x.state==="running").length,
      stopped:instances.filter(x=>x.state==="stopped").length,
      pending:instances.filter(x=>x.state==="pending").length,
      vodiaManaged:instances.filter(x=>x.managedByVodia).length
    }
  };
}

function isInsufficientEc2CapacityError(error) {
  const name=String(error?.name || error?.Code || "");
  const message=String(error?.message || error || "");
  return /InsufficientInstanceCapacity/i.test(name)
    || /insufficient.{0,40}capacity/i.test(message)
    || /do not have sufficient.{0,80}capacity/i.test(message);
}

function runParamsForSubnet(baseParams, subnetId) {
  const params={
    ...baseParams,
    NetworkInterfaces:Array.isArray(baseParams?.NetworkInterfaces)
      ? baseParams.NetworkInterfaces.map((nic,index)=>index===0?{...nic,SubnetId:subnetId}:{...nic})
      : baseParams?.NetworkInterfaces
  };
  if (!Array.isArray(baseParams?.NetworkInterfaces) || !baseParams.NetworkInterfaces.length) {
    params.SubnetId=subnetId;
  } else {
    delete params.SubnetId;
  }
  return params;
}

'''
    s=s[:hi]+helpers+s[hi:]

    # Register read-only tool before region listing.
    tool_anchor='''  server.registerTool(
    "aws_list_deployment_regions",'''
    ti=s.find(tool_anchor)
    if ti<0:
        raise SystemExit("PATCH ERROR: aws_list_deployment_regions registration anchor missing")
    tool=r'''  server.registerTool(
    "aws_list_customer_ec2_instances",
    {
      title: "List EC2 machines in connected AWS account",
      description: "Read-only. Lists visible EC2 instances in the connected customer AWS account across all enabled regions, or one selected region. Includes state, instance type, IPs, subnet/AZ, AMI, and Vodia deployment tags.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3).optional(),
        includeTerminated: z.boolean().optional().default(false)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:true, destructiveHint:false, openWorldHint:true }
    },
    async (input, extra) => {
      scopedAudit("aws_list_customer_ec2_instances", {
        customerId:input.customerId||null,
        region:input.region||null,
        includeTerminated:Boolean(input.includeTerminated)
      });
      try {
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"]);
        const inventory=await listCustomerEc2Inventory(
          c.roleArn,c.externalId,input.region||null,Boolean(input.includeTerminated)
        );
        return scopedSuccess({
          ...inventory,
          customerId:c.customerId||null,
          changesMade:false
        }, {operation:"AWS_EC2_LIST_CUSTOMER_INSTANCES",readOnly:true},
        "Found "+inventory.instances.length+" EC2 machine(s) across "+inventory.regionsScanned+" region(s).");
      } catch(error) {
        return failure(error,"AWS EC2 account inventory");
      }
    }
  );

'''
    s=s[:ti]+tool+s[ti:]

# ---------------------------------------------------------------------------
# B. Correct SSH username using Marketplace usage instructions.
# ---------------------------------------------------------------------------
old='sshUsername:process.env.VODIA_AWS_MARKETPLACE_SSH_USER || "root",'
if old in s:
    new='''sshUsername:process.env.VODIA_AWS_MARKETPLACE_SSH_USER || (/username\\s+ubuntu/i.test(String(accessInfo?.usageInstructions||"")) ? "ubuntu" : "root"),'''
    s=s.replace(old,new,1)

# ---------------------------------------------------------------------------
# C. Planner: calculate public-subnet fallbacks in the same VPC for one-click.
# ---------------------------------------------------------------------------
if 'capacityFailoverSubnetIds' not in s:
    old='''        const params = buildRunInstancesParams(input, image);
        await dryRunLaunch(client, params);

        const planId = randomUUID();'''
    if old not in s:
        raise SystemExit("PATCH ERROR: planner params/DryRun anchor missing")
    new='''        const params = buildRunInstancesParams(input, image);
        await dryRunLaunch(client, params);

        let capacityFailoverSubnetIds=[];
        if (input.deploymentMethod==="ONE_CLICK_MARKETPLACE") {
          const network=await describeNetwork(input.roleArn,input.externalId,input.region);
          const selectedSubnet=(network.subnets||[]).find(x=>x.subnetId===input.subnetId);
          if (selectedSubnet?.vpcId) {
            capacityFailoverSubnetIds=(network.subnets||[])
              .filter(x=>
                x.subnetId!==input.subnetId &&
                x.vpcId===selectedSubnet.vpcId &&
                x.state==="available" &&
                x.mapPublicIpOnLaunch===true
              )
              .sort((a,b)=>String(a.availabilityZone||"").localeCompare(String(b.availabilityZone||"")))
              .map(x=>x.subnetId);
          }
        }

        const planId = randomUUID();'''
    s=s.replace(old,new,1)

    # Persist fallback IDs with the plan.
    old='''          params,
          confirmation,''';
    if old not in s:
        raise SystemExit("PATCH ERROR: plan persistence params anchor missing")
    s=s.replace(old,'''          params,
          capacityFailoverSubnetIds,
          confirmation,''',1)

    # Expose them to Review.
    old='''          dryRunVerified: true,
          deployment: {'''
    if old not in s:
        raise SystemExit("PATCH ERROR: dryRun response anchor missing")
    s=s.replace(old,'''          dryRunVerified: true,
          dryRunMeaning:"AWS accepted the request parameters and permissions during DryRun; live capacity is checked at launch time.",
          capacityFailoverSubnetIds,
          deployment: {''',1)

# ---------------------------------------------------------------------------
# D. Apply: on one-click capacity-only errors, retry another public subnet/AZ.
# ---------------------------------------------------------------------------
if 'capacityAttempts' not in s:
    pattern=re.compile(r'''          const clientToken = "vodia-" \+ planId\.replace\(/-\/g, ""\);\n          const out = await client\.send\(new RunInstancesCommand\(\{ \.\.\.plan\.params, ClientToken: clientToken \}\)\);''')
    m=pattern.search(s)
    if not m:
        raise SystemExit("PATCH ERROR: RunInstances launch block anchor missing")
    replacement='''          const baseClientToken="vodia-"+planId.replace(/-/g,"");
          const primarySubnet=plan.params?.NetworkInterfaces?.[0]?.SubnetId || plan.params?.SubnetId || null;
          const candidateSubnets=[
            primarySubnet,
            ...((plan.deploymentMethod==="ONE_CLICK_MARKETPLACE" ? plan.capacityFailoverSubnetIds : []) || [])
          ].filter((value,index,array)=>value && array.indexOf(value)===index);
          const capacityAttempts=[];
          let out=null;
          let launchedSubnetId=primarySubnet;
          for (let attemptIndex=0; attemptIndex<candidateSubnets.length; attemptIndex++) {
            const subnetId=candidateSubnets[attemptIndex];
            const attemptParams=runParamsForSubnet(plan.params,subnetId);
            const clientToken=baseClientToken+"-"+String(attemptIndex+1);
            try {
              out=await client.send(new RunInstancesCommand({...attemptParams,ClientToken:clientToken}));
              launchedSubnetId=subnetId;
              capacityAttempts.push({subnetId,status:"LAUNCHED"});
              break;
            } catch(error) {
              const canRetry=plan.deploymentMethod==="ONE_CLICK_MARKETPLACE"
                && isInsufficientEc2CapacityError(error)
                && attemptIndex<candidateSubnets.length-1;
              capacityAttempts.push({
                subnetId,
                status:canRetry?"CAPACITY_RETRY":"FAILED",
                error:String(error?.message || error)
              });
              if (!canRetry) throw error;
            }
          }
          if (!out) throw new Error("EC2_LAUNCH_NO_RESULT: no EC2 RunInstances result was returned after capacity failover attempts.");'''
    s=s[:m.start()]+replacement+s[m.end():]

    # Include actual subnet/AZ and attempt record in the APPLY success response.
    # Cumulative v71/v72/v74 builds may insert imageName/marketplaceAmi/
    # deploymentMethod fields between region and name, so do not depend on
    # adjacency. Scope the patch to the apply tool's scopedSuccess block.
    apply_tool_pos=s.find('"aws_marketplace_apply_vodia_pbx_deployment"')
    if apply_tool_pos<0:
        raise SystemExit("PATCH ERROR: apply tool registration missing")
    result_pos=s.find('return scopedSuccess({',apply_tool_pos)
    if result_pos<0:
        raise SystemExit("PATCH ERROR: apply success response missing")
    result_end=s.find('}, { operation: "AWS_MARKETPLACE_APPLY_VODIA_PBX_DEPLOYMENT"',result_pos)
    if result_end<0:
        # Accept cumulative source variants with no spaces around the meta object.
        result_end=s.find('operation:"AWS_MARKETPLACE_APPLY_VODIA_PBX_DEPLOYMENT"',result_pos)
    if result_end<0:
        raise SystemExit("PATCH ERROR: apply success response end missing")
    result_block=s[result_pos:result_end]
    if 'capacityFailoverUsed:' not in result_block:
        region_anchor='            region: plan.region,'
        rp=result_block.find(region_anchor)
        if rp<0:
            raise SystemExit("PATCH ERROR: apply success response region anchor missing")
        insert_at=rp+len(region_anchor)
        extra='''\n            availabilityZone:instance.Placement?.AvailabilityZone || null,
            subnetId:instance.SubnetId || launchedSubnetId || null,
            capacityFailoverUsed:Boolean(primarySubnet && (instance.SubnetId||launchedSubnetId)!==primarySubnet),
            capacityAttempts,'''
        result_block=result_block[:insert_at]+extra+result_block[insert_at:]
        s=s[:result_pos]+result_block+s[result_end:]

# Ensure one-click instances carry deployment method tag if v72 did not already patch this exact block.
if '{ Key: "VodiaDeploymentMethod"' not in s:
    tag_anchor='''  if (input.customerId) {
    tags.push({ Key: "VodiaMspCustomerId", Value: String(input.customerId).slice(0, 255) });
  }'''
    if tag_anchor in s:
        s=s.replace(tag_anchor,tag_anchor+'''
  if (input.deploymentMethod) {
    tags.push({ Key: "VodiaDeploymentMethod", Value: String(input.deploymentMethod).slice(0, 255) });
  }''',1)

p.write_text(s)
PY

echo "[2/8] Patch staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Cosmetic: one-click summary should contain actual newlines, not literal backslash-n.
s=s.replace('].filter(Boolean).join("\\\\n");','].filter(Boolean).join("\\n");')

if 'VODIA_EC2_INVENTORY_UI_V75' not in s:
    # Add state marker after the v74 marker/product constant.
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0:
        raise SystemExit("PATCH ERROR: Marketplace product ID anchor missing")
    line_end=s.find('\n',i)
    if line_end<0:
        raise SystemExit("PATCH ERROR: product ID line malformed")
    marker='''  const VODIA_EC2_INVENTORY_UI_V75 = true;
  let ec2InventoryLoadedCustomerV75 = null;
  let ec2InventoryBusyV75 = false;
'''
    s=s[:line_end+1]+marker+s[line_end+1:]

    # Add styles.
    style_anchor='</style>'
    if style_anchor not in s:
        raise SystemExit("PATCH ERROR: style closing tag missing")
    css=r'''
.ec2-inventory-v75{margin-top:14px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:12px;padding:12px}
.ec2-inventory-v75-head{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap}
.ec2-inventory-v75-title{font-weight:800}
.ec2-inventory-v75-summary{font-size:11px;opacity:.75;margin:6px 0 10px}
.ec2-inventory-v75-scroll{overflow:auto;max-height:330px;border:1px solid color-mix(in srgb,CanvasText 10%,transparent);border-radius:9px}
.ec2-inventory-v75 table{border-collapse:collapse;width:100%;min-width:900px;font-size:11px}
.ec2-inventory-v75 th,.ec2-inventory-v75 td{text-align:left;padding:8px 9px;border-bottom:1px solid color-mix(in srgb,CanvasText 8%,transparent);white-space:nowrap}
.ec2-inventory-v75 th{position:sticky;top:0;background:Canvas;z-index:1}
.ec2-inventory-v75 .vodia-pill{font-weight:700}
'''
    s=s.replace(style_anchor,css+style_anchor,1)

    # Insert helper functions before renderAwsConnection, a stable customer/AWS UI point.
    fn_anchor='''  function renderAwsConnection(connection){'''
    if fn_anchor not in s:
        raise SystemExit("PATCH ERROR: renderAwsConnection anchor missing")
    funcs=r'''  function ensureEc2InventoryPanelV75(){
    let box=$("ec2InventoryV75");
    if(box) return box;
    box=document.createElement("section");
    box.id="ec2InventoryV75";
    box.className="ec2-inventory-v75 hidden";
    const head=document.createElement("div");
    head.className="ec2-inventory-v75-head";
    const title=document.createElement("div");
    title.className="ec2-inventory-v75-title";
    title.textContent="EC2 machines in this AWS account";
    const refresh=document.createElement("button");
    refresh.id="refreshEc2InventoryV75";
    refresh.type="button";
    refresh.className="secondary";
    refresh.textContent="Refresh EC2 machines";
    refresh.addEventListener("click",()=>refreshEc2InventoryV75(true));
    head.append(title,refresh);
    const summary=document.createElement("div");
    summary.id="ec2InventorySummaryV75";
    summary.className="ec2-inventory-v75-summary";
    summary.textContent="Connect AWS to load EC2 machines.";
    const scroll=document.createElement("div");
    scroll.className="ec2-inventory-v75-scroll";
    const table=document.createElement("table");
    table.innerHTML="<thead><tr><th>Name</th><th>Instance</th><th>State</th><th>Type</th><th>Region / AZ</th><th>Public IP</th><th>Private IP</th><th>VPC / Subnet</th><th>Vodia</th></tr></thead><tbody id=\"ec2InventoryBodyV75\"></tbody>";
    scroll.appendChild(table);
    box.append(head,summary,scroll);
    const mount=$("awsContinueRow") || $("awsSection");
    mount?.insertAdjacentElement("afterend",box);
    return box;
  }

  function renderEc2InventoryV75(data){
    const box=ensureEc2InventoryPanelV75();
    const body=$("ec2InventoryBodyV75");
    if(!box || !body) return;
    body.textContent="";
    const rows=Array.isArray(data?.instances)?data.instances:[];
    for(const row of rows){
      const tr=document.createElement("tr");
      const values=[
        row.name||"—",
        row.instanceId||"—",
        row.state||"unknown",
        row.instanceType||"—",
        [row.region,row.availabilityZone].filter(Boolean).join(" / ")||"—",
        row.publicIpAddress||"—",
        row.privateIpAddress||"—",
        [row.vpcId,row.subnetId].filter(Boolean).join(" / ")||"—"
      ];
      values.forEach(value=>{
        const td=document.createElement("td");
        td.textContent=value;
        tr.appendChild(td);
      });
      const vodia=document.createElement("td");
      vodia.className=row.managedByVodia?"vodia-pill":"";
      vodia.textContent=row.managedByVodia
        ? ("Yes"+(row.vodiaDeploymentMethod?(" · "+row.vodiaDeploymentMethod):""))
        : "No";
      tr.appendChild(vodia);
      body.appendChild(tr);
    }
    const counts=data?.counts||{};
    const errors=Array.isArray(data?.regionErrors)?data.regionErrors:[];
    $("ec2InventorySummaryV75").textContent=
      (counts.total??rows.length)+" visible machine(s) · "+
      (counts.running??rows.filter(x=>x.state==="running").length)+" running · "+
      (counts.stopped??rows.filter(x=>x.state==="stopped").length)+" stopped · "+
      (counts.vodiaManaged??rows.filter(x=>x.managedByVodia).length)+" Vodia-managed · "+
      (data?.regionsScanned??0)+" region(s) scanned"+
      (errors.length?(" · "+errors.length+" region error(s)"):"");
    box.classList.remove("hidden");
    reportSize();
  }

  async function refreshEc2InventoryV75(force=false){
    const id=customerId();
    if(!id || !currentAwsConnection?.configured || ec2InventoryBusyV75) return;
    if(!force && ec2InventoryLoadedCustomerV75===id) return;
    const box=ensureEc2InventoryPanelV75();
    box?.classList.remove("hidden");
    ec2InventoryBusyV75=true;
    const btn=$("refreshEc2InventoryV75");
    if(btn){btn.disabled=true;btn.textContent="Scanning EC2…";}
    if($("ec2InventorySummaryV75")) $("ec2InventorySummaryV75").textContent="Scanning EC2 machines across enabled AWS regions…";
    try{
      const raw=await callTool("aws_list_customer_ec2_instances",{customerId:id,includeTerminated:false});
      if(raw?.isError) throw new Error(toolErrorText(raw)||"EC2 inventory failed.");
      const data=dataFrom(raw);
      ec2InventoryLoadedCustomerV75=id;
      renderEc2InventoryV75(data);
    }catch(e){
      if($("ec2InventorySummaryV75")) $("ec2InventorySummaryV75").textContent=e?.message||String(e);
      debugLog("error","EC2_INVENTORY_ERROR",{message:e?.message||String(e)});
    }finally{
      ec2InventoryBusyV75=false;
      if(btn){btn.disabled=false;btn.textContent="Refresh EC2 machines";}
      reportSize();
    }
  }

'''
    s=s.replace(fn_anchor,funcs+fn_anchor,1)

    # When AWS is connected, show/load account machines once in the background.
    connected_anchor='''      $("awsContinueRow").classList.remove("hidden");
      updateCustomerContext();'''
    if connected_anchor not in s:
        raise SystemExit("PATCH ERROR: connected AWS UI anchor missing")
    s=s.replace(connected_anchor,'''      $("awsContinueRow").classList.remove("hidden");
      updateCustomerContext();
      ensureEc2InventoryPanelV75();
      queueMicrotask(()=>refreshEc2InventoryV75(false));''',1)

    # Hide/clear panel if AWS connection is absent.
    disconnected_anchor='''      $("awsContinueRow").classList.add("hidden");'''
    if disconnected_anchor in s:
      s=s.replace(disconnected_anchor,disconnected_anchor+'''
      ec2InventoryLoadedCustomerV75=null;
      $("ec2InventoryV75")?.classList.add("hidden");''',1)

# ---------------------------------------------------------------------------
# UI polish: + New organization/customer becomes Cancel while form is open.
# ---------------------------------------------------------------------------
if 'VODIA_CREATE_CANCEL_TOGGLE_V75' not in s:
    marker_anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    mi=s.find(marker_anchor)
    if mi<0:
        raise SystemExit("PATCH ERROR: Marketplace product ID anchor missing for create/cancel marker")
    mle=s.find('\\n',mi)
    s=s[:mle+1]+'  const VODIA_CREATE_CANCEL_TOGGLE_V75 = true;\\n'+s[mle+1:]

    old_org='''  $("toggleOrg").addEventListener("click",()=>{
    $("newOrg").classList.toggle("hidden");
    if(!$("newOrg").classList.contains("hidden")) $("orgName").focus();
    reportSize();
  });'''
    new_org='''  function setNewOrgOpenV75(open){
    $("newOrg").classList.toggle("hidden",!open);
    $("toggleOrg").textContent=open?"Cancel":"+ New organization";
    if(open){
      $("orgManageBox")?.classList.add("hidden");
      setMsg("orgMsg","");
      $("orgName")?.focus();
    }else{
      $("orgName").value="";
      setMsg("orgMsg","");
    }
    reportSize();
  }

  $("toggleOrg").addEventListener("click",()=>{
    setNewOrgOpenV75($("newOrg").classList.contains("hidden"));
  });'''
    if old_org not in s:
        raise SystemExit("PATCH ERROR: toggleOrg handler anchor missing")
    s=s.replace(old_org,new_org,1)

    old_customer='''  $("toggleCustomer").addEventListener("click",()=>{
    if(!orgId()){ setMsg("customerMsg","Select an organization first."); return; }
    $("newCustomer").classList.toggle("hidden");
    if(!$("newCustomer").classList.contains("hidden")) $("customerName").focus();
    reportSize();
  });'''
    new_customer='''  function setNewCustomerOpenV75(open){
    $("newCustomer").classList.toggle("hidden",!open);
    $("toggleCustomer").textContent=open?"Cancel":"+ New customer";
    if(open){
      $("customerManageBox")?.classList.add("hidden");
      setMsg("customerMsg","");
      $("customerName")?.focus();
    }else{
      $("customerName").value="";
      setMsg("customerMsg","");
    }
    reportSize();
  }

  $("toggleCustomer").addEventListener("click",()=>{
    if(!orgId()){ setMsg("customerMsg","Select an organization first."); return; }
    setNewCustomerOpenV75($("newCustomer").classList.contains("hidden"));
  });'''
    if old_customer not in s:
        raise SystemExit("PATCH ERROR: toggleCustomer handler anchor missing")
    s=s.replace(old_customer,new_customer,1)

    # Keep button labels in sync when forms are closed by other workflows.
    s=s.replace('$("newCustomer").classList.add("hidden");\\n    $("orgManageBox")',
                '$("newCustomer").classList.add("hidden");\\n    $("toggleCustomer").textContent="+ New customer";\\n    $("orgManageBox")',1)
    s=s.replace('$("newOrg").classList.add("hidden");\\n      await refreshOrganizations(id);',
                '$("newOrg").classList.add("hidden");\\n      $("toggleOrg").textContent="+ New organization";\\n      await refreshOrganizations(id);',1)
    s=s.replace('$("newCustomer").classList.add("hidden");\\n      await refreshOrganizations(organizationId);',
                '$("newCustomer").classList.add("hidden");\\n      $("toggleCustomer").textContent="+ New customer";\\n      await refreshOrganizations(organizationId);',1)

    org_manage='''    const opening=$("orgManageBox").classList.contains("hidden");
    $("orgManageBox").classList.toggle("hidden",!opening);'''
    if org_manage in s:
        s=s.replace(org_manage,'''    const opening=$("orgManageBox").classList.contains("hidden");
    if(opening && !$("newOrg").classList.contains("hidden")) setNewOrgOpenV75(false);
    $("orgManageBox").classList.toggle("hidden",!opening);''',1)

    customer_manage='''    const opening=$("customerManageBox").classList.contains("hidden");
    $("customerManageBox").classList.toggle("hidden",!opening);'''
    if customer_manage in s:
        s=s.replace(customer_manage,'''    const opening=$("customerManageBox").classList.contains("hidden");
    if(opening && !$("newCustomer").classList.contains("hidden")) setNewCustomerOpenV75(false);
    $("customerManageBox").classList.toggle("hidden",!opening);''',1)

# Version/debug markers.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.75"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.33.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                 'ui://vodia/msp-guided/v0.14.9.75/mcp-app.html',s,count=1)
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

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null || fail "backend JavaScript invalid"
for marker in   'VODIA_EC2_ACCOUNT_INVENTORY_V75'   'aws_list_customer_ec2_instances'   'listCustomerEc2Inventory'   'isInsufficientEc2CapacityError'   'capacityFailoverSubnetIds'   'capacityAttempts'; do
  grep -Fq "$marker" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend marker missing: $marker"
done
echo "PASS: EC2 inventory + capacity failover backend present"

echo "[4/8] Validate staged UI"
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
for marker in   'VODIA_EC2_INVENTORY_UI_V75'   'EC2 machines in this AWS account'   'aws_list_customer_ec2_instances'   'refreshEc2InventoryV75'   'VODIA_CREATE_CANCEL_TOGGLE_V75'   'setNewOrgOpenV75'   'setNewCustomerOpenV75'; do
  grep -Fq "$marker" "$TMP/staged/msp-guided-app.html" || fail "UI marker missing: $marker"
done
echo "PASS: EC2 account inventory UI + create/cancel toggles present"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.75 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v75 files"
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/8] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[7/8] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.75"' <<<"$HEALTH" || fail "health does not report v0.14.9.75"
echo "$HEALTH"
grep -Fq 'VODIA_EC2_ACCOUNT_INVENTORY_V75' "$BACKEND" || fail "live EC2 inventory backend marker missing"
grep -Fq 'VODIA_EC2_INVENTORY_UI_V75' "$UI" || fail "live EC2 inventory UI marker missing"
grep -Fq 'capacityAttempts' "$BACKEND" || fail "live capacity failover marker missing"
echo "PASS: live v75 markers present"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.75 installed."
echo "PASS: Connected customer now has a read-only EC2 machine inventory across enabled regions."
echo "PASS: UI shows Name, instance ID, state, type, Region/AZ, IPs, VPC/subnet and Vodia-managed status."
echo "PASS: One-click launch retries alternate public subnets/AZs only for insufficient-capacity errors."
echo "PASS: Marketplace SSH username follows usage instructions when they explicitly name ubuntu."
echo "PASS: DryRun wording now distinguishes request validation from live capacity."
echo "PASS: + New organization and + New customer change to Cancel while their create forms are open."
echo "Backup: $BACKUP_DIR"
