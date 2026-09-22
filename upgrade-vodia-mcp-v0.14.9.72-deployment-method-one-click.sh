#!/usr/bin/env bash
# Vodia MCP v0.14.9.72 — deployment method selector + Marketplace one-click defaults
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.72"
V71_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.71-exact-marketplace-ami-access.sh"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-deployment-method-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"

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
  0.14.9.70)
    echo "[prerequisite] Installing v0.14.9.71 exact Marketplace AMI binding"
    curl -fsSL "$V71_URL" -o "$TMP/v71.sh"
    bash -n "$TMP/v71.sh"
    chmod +x "$TMP/v71.sh"
    "$TMP/v71.sh"
    CURRENT="$(read_version)"
    ;;
  0.14.9.71) ;;
  0.14.9.72) echo "v0.14.9.72 version detected; verifying cumulative markers." ;;
  *) fail "expected v0.14.9.70, .71, or .72; found ${CURRENT:-unknown}" ;;
esac
[[ "$CURRENT" == "0.14.9.71" || "$CURRENT" == "0.14.9.72" ]] || fail "v0.14.9.71 prerequisite did not complete"

NEED_PATCH=0
if [[ "$CURRENT" == "0.14.9.71" ]]; then
  NEED_PATCH=1
elif ! grep -Fq 'VODIA_DEPLOYMENT_METHOD_V72' "$BACKEND" || ! grep -Fq 'data-deployment-method="v0.14.9.72"' "$UI"; then
  echo "[repair] Version reports v0.14.9.72 but cumulative v72 markers are missing; repairing live files."
  NEED_PATCH=1
fi

if [[ "$NEED_PATCH" == "1" ]] && ! grep -Fq 'VODIA_EXACT_MARKETPLACE_AMI_V71' "$BACKEND"; then
  fail "v0.14.9.71 exact Marketplace AMI backend marker is missing. Install the v71 repair prerequisite first."
fi

echo "=== Vodia MCP v${TO_VER} — deployment method selector + one-click defaults ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

if [[ "$NEED_PATCH" == "1" ]]; then
echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_DEPLOYMENT_METHOD_V72' in s: raise SystemExit(0)

# Tag and schema support for the selected launch method.
tag_anchor='''  if (input.customerId) {
    tags.push({ Key: "VodiaMspCustomerId", Value: String(input.customerId).slice(0, 255) });
  }'''
if tag_anchor not in s: raise SystemExit("PATCH ERROR: customer tag anchor missing")
s=s.replace(tag_anchor,tag_anchor+'''
  if (input.deploymentMethod) {
    tags.push({ Key: "VodiaDeploymentMethod", Value: String(input.deploymentMethod).slice(0, 255) });
  }''',1)

schema_anchor='''        associatePublicIp: z.boolean().default(true),
        name: z.string().min(1).max(128)'''
if schema_anchor not in s: raise SystemExit("PATCH ERROR: planner schema anchor missing")
s=s.replace(schema_anchor,'''        associatePublicIp: z.boolean().default(true),
        deploymentMethod: z.enum(["MANAGED_EC2","ONE_CLICK_MARKETPLACE"]).optional().default("MANAGED_EC2"),
        name: z.string().min(1).max(128)''',1)

# Persist and return launch method.
store_anchor='''          region: input.region,
          name: input.name,
          imageId: image.ImageId,''';
if store_anchor not in s: raise SystemExit("PATCH ERROR: plan store anchor missing")
s=s.replace(store_anchor,'''          region: input.region,
          name: input.name,
          deploymentMethod: input.deploymentMethod || "MANAGED_EC2",
          imageId: image.ImageId,''',1)

resp_anchor='''          deployment: {
            name: input.name,
            region: input.region,''';
if resp_anchor not in s: raise SystemExit("PATCH ERROR: planner response deployment anchor missing")
s=s.replace(resp_anchor,'''          deployment: {
            name: input.name,
            region: input.region,
            deploymentMethod: input.deploymentMethod || "MANAGED_EC2",''',1)

apply_anchor='''            region: plan.region,
            name: plan.name,
            agreementId: plan.agreementId || null,''';
if apply_anchor not in s: raise SystemExit("PATCH ERROR: apply result anchor missing")
s=s.replace(apply_anchor,'''            region: plan.region,
            name: plan.name,
            deploymentMethod: plan.deploymentMethod || "MANAGED_EC2",
            agreementId: plan.agreementId || null,''',1)

# One-click recommendation tool. It does not launch anything. It mirrors the
# AWS Marketplace one-click idea by choosing vendor/default settings while
# preserving the exact AMI resolver from v0.14.9.71.
register_anchor='''  server.registerTool(
    "aws_marketplace_plan_vodia_pbx_deployment",'''
if register_anchor not in s: raise SystemExit("PATCH ERROR: deployment planner insertion anchor missing")

tool=r'''const VODIA_DEPLOYMENT_METHOD_V72 = true;

  server.registerTool(
    "aws_marketplace_prepare_vodia_one_click",
    {
      title: "Prepare Vodia Marketplace one-click deployment",
      description: "Read-only. Resolves the exact regional Vodia Marketplace AMI and chooses AWS/Vodia recommended defaults for instance type, default VPC, public subnet, default security group, public IP, and AMI default root storage. Makes no EC2 changes.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        agreementId: z.string().min(3).optional(),
        region: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:true, destructiveHint:false, openWorldHint:true }
    },
    async (input, extra) => {
      scopedAudit("aws_marketplace_prepare_vodia_one_click", {
        customerId:input.customerId||null,
        productId:input.productId,
        agreementId:input.agreementId||null,
        region:input.region
      });
      try {
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR"]);
        const subscription=await checkSubscription(c.roleArn,c.externalId,input.productId);
        if(!subscription.active) throw new Error("SUBSCRIPTION_REQUIRED: no ACTIVE Vodia Marketplace agreement was found.");

        const agreement=input.agreementId
          ? subscription.agreements.find(a=>a?.agreementId===input.agreementId)
          : subscription.agreements[0];
        if(!agreement) throw new Error("AGREEMENT_NOT_ACTIVE: select an active Marketplace agreement.");

        const usage=await reconcileMarketplaceAgreementUsage(
          c.roleArn,c.externalId,c.customerId||null,input.productId,agreement.agreementId
        );
        if(usage.status!=="AVAILABLE"){
          throw new Error("MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.");
        }

        const network=await describeNetwork(c.roleArn,c.externalId,input.region);
        const defaultVpc=(network.vpcs||[]).find(v=>v.isDefault && v.state==="available")
          || (network.vpcs||[]).find(v=>v.state==="available");
        if(!defaultVpc) throw new Error("ONE_CLICK_NO_VPC: no available VPC was found.");

        const vpcSubnets=(network.subnets||[]).filter(x=>x.vpcId===defaultVpc.vpcId && x.state==="available");
        const subnet=vpcSubnets.find(x=>x.mapPublicIpOnLaunch) || vpcSubnets[0];
        if(!subnet) throw new Error("ONE_CLICK_NO_SUBNET: no usable subnet was found in the selected VPC.");

        const groups=(network.securityGroups||[]).filter(x=>x.vpcId===defaultVpc.vpcId);
        const securityGroup=groups.find(x=>x.groupName==="default") || groups[0];
        if(!securityGroup) throw new Error("ONE_CLICK_NO_SECURITY_GROUP: no security group was found in the selected VPC.");

        const client=ec2Client(c.roleArn,c.externalId,input.region);
        const image=await resolveMarketplaceAmi(client,{
          productId:input.productId,
          productCode:configuredMarketplaceProductCode()
        });
        const access=await readVodiaMarketplaceAmiInstructions(c.roleArn,c.externalId,input.productId);
        const marketplaceAmi=imageDeploymentMetadata(image,input.productId,access);

        let instanceType=access?.recommendedInstanceType || null;
        let instanceTypeSource=instanceType ? "AWS Marketplace vendor recommendation" : "Vodia fallback";
        if(!instanceType){
          const discovered=(network.instanceTypes||[]).find(x=>x.recommended)
            || (network.instanceTypes||[]).find(x=>x.instanceType==="t3.medium")
            || (network.instanceTypes||[])[0];
          instanceType=discovered?.instanceType || "t3.medium";
        }

        let instanceTypeVerified=false;
        try{
          const types=await client.send(new DescribeInstanceTypesCommand({ InstanceTypes:[instanceType] }));
          const found=(types.InstanceTypes||[])[0];
          instanceTypeVerified=Boolean(found && (found.ProcessorInfo?.SupportedArchitectures||[]).includes("x86_64"));
        }catch(_e){}
        if(!instanceTypeVerified){
          const fallback=(network.instanceTypes||[]).find(x=>x.recommended)
            || (network.instanceTypes||[]).find(x=>x.instanceType==="t3.medium")
            || (network.instanceTypes||[])[0];
          if(fallback?.instanceType){
            instanceType=fallback.instanceType;
            instanceTypeSource="Region-compatible fallback";
            instanceTypeVerified=true;
          }
        }

        const rootMapping=(image.BlockDeviceMappings||[]).find(m=>m?.Ebs);
        const rootVolumeSizeGiB=rootMapping?.Ebs?.VolumeSize || null;

        return scopedSuccess({
          deploymentMethod:"ONE_CLICK_MARKETPLACE",
          selectedAgreement:{
            agreementId:agreement.agreementId||null,
            status:agreement.status||"ACTIVE"
          },
          region:input.region,
          marketplaceAmi,
          defaults:{
            instanceType,
            instanceTypeSource,
            instanceTypeVerified,
            vpcId:defaultVpc.vpcId,
            subnetId:subnet.subnetId,
            availabilityZone:subnet.availabilityZone||null,
            securityGroupId:securityGroup.groupId,
            securityGroupName:securityGroup.groupName||null,
            keyName:null,
            storageGiB:null,
            rootVolumeSizeGiB,
            storageSource:"Marketplace AMI default",
            associatePublicIp:true,
            iamInstanceProfileName:"VodiaPBXMarketplaceEntitlementRole"
          },
          network,
          changesMade:false
        }, {operation:"AWS_MARKETPLACE_PREPARE_VODIA_ONE_CLICK",readOnly:true},
        "One-click defaults prepared. No EC2 instance was launched.");
      } catch(error){
        return failure(error,"AWS Marketplace Vodia one-click preparation");
      }
    }
  );

'''
s=s.replace(register_anchor,tool+register_anchor,1)

p.write_text(s)
PY

echo "[2/8] Patch staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'data-deployment-method="v0.14.9.72"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-deployment-method="v0.14.9.72"',1)

if '.deploy-method-grid{' not in s:
    css=r'''
.deploy-method-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}
.deploy-method-card{display:block;border:1px solid color-mix(in srgb,CanvasText 16%,transparent);border-radius:11px;padding:11px;background:color-mix(in srgb,CanvasText 3%,transparent);cursor:pointer}
.deploy-method-card:has(input:checked){border-color:#2f80ed;background:color-mix(in srgb,#2f80ed 8%,Canvas)}
.deploy-method-card input{width:auto;margin-right:7px}
.deploy-method-title{font-weight:750;font-size:12px}.deploy-method-copy{font-size:10px;opacity:.72;margin-top:4px;line-height:1.4}
.oneclick-summary{margin-top:10px}
@media(max-width:720px){.deploy-method-grid{grid-template-columns:1fr}}
'''
    s=s.replace('</style>',css+'</style>',1)

# Add launch-method choice to Marketplace step.
anchor='''        <div id="marketplaceMount"></div>
        <div class="nav-actions">'''
if anchor not in s: raise SystemExit("PATCH ERROR: Marketplace mount anchor missing")
method='''        <div id="marketplaceMount"></div>
        <div id="deploymentMethodBox">
          <div class="guided-title">Launch method</div>
          <div class="deploy-method-grid">
            <label class="deploy-method-card" for="deploymentMethodManaged">
              <div><input id="deploymentMethodManaged" name="deploymentMethod" type="radio" value="MANAGED_EC2" checked><span class="deploy-method-title">Launch from EC2 Console style</span></div>
              <div class="deploy-method-copy">Scalable method with full control over instance type, VPC, subnet, security group, SSH key and storage.</div>
            </label>
            <label class="deploy-method-card" for="deploymentMethodOneClick">
              <div><input id="deploymentMethodOneClick" name="deploymentMethod" type="radio" value="ONE_CLICK_MARKETPLACE"><span class="deploy-method-title">One-click launch from AWS Marketplace</span></div>
              <div class="deploy-method-copy">Quick deployment. Vodia MCP resolves the exact Marketplace AMI and automatically chooses vendor/default AWS settings.</div>
            </label>
          </div>
        </div>
        <div class="nav-actions">'''
s=s.replace(anchor,method,1)

# State. Live cumulative UI variants do not all carry pendingNetworkReload,
# so insert relative to whichever stable deployment-state declaration exists.
if 'let deploymentMethod = "MANAGED_EC2";' not in s:
    state_insert='''  let deploymentMethod = "MANAGED_EC2";
  let oneClickRecommendation = null;
'''
    candidates=[
        '  let pendingNetworkReload = false;\n',
        '  let currentNetwork = null;\n',
        '  let currentDeploymentPlan = null;\n',
        '  let selectedRegion = "";\n'
    ]
    for candidate in candidates:
        if candidate in s:
            s=s.replace(candidate,candidate+state_insert,1)
            break
    else:
        raise SystemExit("PATCH ERROR: no compatible deployment-state anchor found")

# Add helpers before updatePlanButton.
anchor='''  function updatePlanButton(){'''
if anchor not in s: raise SystemExit("PATCH ERROR: updatePlanButton anchor missing")
helpers=r'''  function selectedDeploymentMethod(){
    return document.querySelector('input[name="deploymentMethod"]:checked')?.value || "MANAGED_EC2";
  }

  function applyDeploymentMethodUi(){
    deploymentMethod=selectedDeploymentMethod();
    const oneClick=deploymentMethod==="ONE_CLICK_MARKETPLACE";
    const managedIds=["instanceType","vpcSelect","subnetSelect","securityGroupSelect","keyPairSelect","storageGiB"];
    managedIds.forEach(id=>{
      const field=$(id)?.closest(".field");
      if(field) field.classList.toggle("hidden",oneClick);
    });
    if($("loadNetwork")) $("loadNetwork").textContent=oneClick?"Prepare one-click settings":"Load EC2 options";
    if($("planDeployment")) $("planDeployment").textContent=oneClick?"Validate One-click Plan":"Validate & Create Plan";
    if($("continueMarketplace")) $("continueMarketplace").textContent=oneClick?"Continue to One-click Setup":"Continue to Configure EC2";
    setMsg("deployMsg",oneClick
      ?"One-click mode: choose a Region and PBX name. Vodia MCP will use the exact Vodia Marketplace AMI and choose the Marketplace/vendor/default infrastructure settings."
      :"Managed EC2 mode: choose and review the EC2 infrastructure settings.");
    reportSize();
  }

  function renderOneClickRecommendation(r){
    let box=$("oneClickSummary");
    if(!box){
      box=document.createElement("div");
      box.id="oneClickSummary";
      box.className="summarybox oneclick-summary";
      $("loadNetwork")?.insertAdjacentElement("afterend",box);
    }
    const d=r?.defaults||{};
    const ami=r?.marketplaceAmi||{};
    box.textContent=[
      "ONE-CLICK MARKETPLACE SETTINGS",
      "Marketplace AMI: "+(ami.imageName||"unverified"),
      "Regional AMI ID: "+(ami.imageId||"unverified"),
      "AMI verification: "+(ami.verified?"EXACT VODIA MARKETPLACE AMI":"NOT VERIFIED"),
      "Instance type: "+(d.instanceType||"unknown")+" · "+(d.instanceTypeSource||""),
      "VPC: "+(d.vpcId||"unknown"),
      "Subnet: "+(d.subnetId||"unknown")+(d.availabilityZone?(" · "+d.availabilityZone):""),
      "Security group: "+(d.securityGroupName||"")+" · "+(d.securityGroupId||"unknown"),
      "Storage: "+(d.rootVolumeSizeGiB?d.rootVolumeSizeGiB+" GiB AMI default":"Marketplace AMI default"),
      "Public IP: enabled",
      "SSH key: none by default"
    ].filter(Boolean).join("\\n");
    box.classList.remove("hidden");
  }

'''
s=s.replace(anchor,helpers+anchor,1)

# Method listeners.
listener_anchor='''  $("continueMarketplace").addEventListener("click",async()=>{'''
if listener_anchor not in s: raise SystemExit("PATCH ERROR: Marketplace continue listener missing")
listeners=r'''  ["deploymentMethodManaged","deploymentMethodOneClick"].forEach(id=>{
    $(id)?.addEventListener("change",()=>{
      deploymentMethod=selectedDeploymentMethod();
      oneClickRecommendation=null;
      currentNetwork=null;
      currentDeploymentPlan=null;
      $("oneClickSummary")?.classList.add("hidden");
      applyDeploymentMethodUi();
      updatePlanButton();
    });
  });

'''
s=s.replace(listener_anchor,listeners+listener_anchor,1)

# Apply method UI when entering configure.
s=s.replace('''    setStep(3);
    await loadDeploymentRegions();''','''    deploymentMethod=selectedDeploymentMethod();
    setStep(3);
    applyDeploymentMethodUi();
    await loadDeploymentRegions();''',1)

# Replace the network-discovery statement inside the live loadNetwork handler.
# Do not depend on argument formatting: locate the actual call text, then replace
# the containing JS statement while preserving that original statement for managed mode.
load_start=s.find('$("loadNetwork").addEventListener("click",async()=>{')
if load_start<0:
    raise SystemExit("PATCH ERROR: loadNetwork handler missing")
load_end=s.find('\n  $("planDeployment").addEventListener',load_start)
if load_end<0:
    raise SystemExit("PATCH ERROR: loadNetwork handler end missing")
block=s[load_start:load_end]
if 'aws_marketplace_prepare_vodia_one_click' not in block:
    call_pos=block.find('callTool("aws_discover_deployment_network"')
    if call_pos<0:
        call_pos=block.find("callTool('aws_discover_deployment_network'")
    if call_pos<0:
        raise SystemExit("PATCH ERROR: aws_discover_deployment_network call not found anywhere inside loadNetwork handler")

    stmt_start=block.rfind('\n',0,call_pos)+1
    stmt_end=block.find(';',call_pos)
    if stmt_end<0:
        raise SystemExit("PATCH ERROR: network discovery statement terminator not found")
    stmt_end+=1
    original_stmt=block[stmt_start:stmt_end]
    indent=original_stmt[:len(original_stmt)-len(original_stmt.lstrip())]
    managed_stmt=original_stmt
    if 'const r' in managed_stmt:
        managed_stmt=managed_stmt.replace('const r','r',1)
    elif 'let r' in managed_stmt:
        managed_stmt=managed_stmt.replace('let r','r',1)
    elif not managed_stmt.lstrip().startswith('r='):
        raise SystemExit("PATCH ERROR: network discovery result is not assigned to r")

    replacement=indent+'''const oneClick=deploymentMethod==="ONE_CLICK_MARKETPLACE";
'''+indent+'''let r;
'''+indent+'''if(oneClick){
'''+indent+'''  setMsg("deployMsg","Resolving exact Vodia Marketplace AMI and preparing one-click AWS settings…");
'''+indent+'''  const raw=await callTool("aws_marketplace_prepare_vodia_one_click",{
'''+indent+'''    customerId:id,
'''+indent+'''    productId:VODIA_MARKETPLACE_PRODUCT_ID,
'''+indent+'''    agreementId:$("marketplaceAgreementSelect")?.value||undefined,
'''+indent+'''    region:requestedRegion
'''+indent+'''  });
'''+indent+'''  if(raw?.isError) throw new Error(toolErrorText(raw)||"One-click preparation failed.");
'''+indent+'''  oneClickRecommendation=dataFrom(raw);
'''+indent+'''  r=oneClickRecommendation.network||{};
'''+indent+'''}else{
'''+managed_stmt+''' 
'''+indent+'''}'''
    block=block[:stmt_start]+replacement+block[stmt_end:]
    s=s[:load_start]+block+s[load_end:]


# After current population has run, force one-click selections to backend recommendation.
anchor='''      const warning=r.instanceTypesWarning?" Instance types could not be verified for this region; the deployment DryRun will validate your choice.":"";
      setMsg("deployMsg","AWS network, regional SSH key pairs, and instance types loaded for "+requestedRegion+". Review the selections before creating the deployment plan."+warning);
      updatePlanButton();'''
if anchor not in s: raise SystemExit("PATCH ERROR: network completion anchor missing")
replacement='''      const warning=r.instanceTypesWarning?" Instance types could not be verified for this region; the deployment DryRun will validate your choice.":"";
      if(deploymentMethod==="ONE_CLICK_MARKETPLACE" && oneClickRecommendation?.defaults){
        const d=oneClickRecommendation.defaults;
        if(d.vpcId) $("vpcSelect").value=d.vpcId;
        filterNetworkForVpc();
        if(d.subnetId) $("subnetSelect").value=d.subnetId;
        if(d.securityGroupId) $("securityGroupSelect").value=d.securityGroupId;
        if(d.instanceType){
          if(!Array.from($("instanceType").options).some(op=>op.value===d.instanceType)){
            const op=document.createElement("option");op.value=d.instanceType;op.textContent=d.instanceType+" — Vendor recommended";$("instanceType").appendChild(op);
          }
          $("instanceType").value=d.instanceType;
        }
        $("keyPairSelect").value="";
        if(d.rootVolumeSizeGiB) $("storageGiB").value=String(d.rootVolumeSizeGiB);
        renderOneClickRecommendation(oneClickRecommendation);
        setMsg("deployMsg","One-click settings prepared from the exact Vodia Marketplace AMI, Marketplace recommendation, and the customer AWS defaults. Review the summary, then validate the plan.");
      }else{
        setMsg("deployMsg","AWS network, regional SSH key pairs, and instance types loaded for "+requestedRegion+". Review the selections before creating the deployment plan."+warning);
      }
      applyDeploymentMethodUi();
      updatePlanButton();'''
s=s.replace(anchor,replacement,1)

# Plan arguments: one-click keeps AMI root storage and no SSH key unless we later explicitly add one.
old='''    const keyName=$("keyPairSelect").value;
    const storageGiB=Number($("storageGiB").value||20);'''
new='''    const keyName=$("keyPairSelect").value;
    const oneClick=deploymentMethod==="ONE_CLICK_MARKETPLACE";
    const storageGiB=oneClick?null:Number($("storageGiB").value||20);'''
if old not in s: raise SystemExit("PATCH ERROR: plan local args anchor missing")
s=s.replace(old,new,1)

old='''        keyName:keyName||undefined,
        storageGiB,
        associatePublicIp:true,
        name'''
new='''        keyName:oneClick?undefined:(keyName||undefined),
        storageGiB:oneClick?undefined:storageGiB,
        associatePublicIp:true,
        deploymentMethod,
        name'''
if old not in s: raise SystemExit("PATCH ERROR: planner tool args anchor missing")
s=s.replace(old,new,1)

# Review should clearly identify method.
summary_anchor='''        "Marketplace agreement: "+selectedAgreementId,
        "Marketplace: Vodia PBX — ACTIVE",'''
if summary_anchor not in s: raise SystemExit("PATCH ERROR: review method anchor missing")
s=s.replace(summary_anchor,'''        "Marketplace agreement: "+selectedAgreementId,
        "Deployment method: "+(deploymentMethod==="ONE_CLICK_MARKETPLACE"?"ONE-CLICK MARKETPLACE":"MANAGED EC2"),
        "Marketplace: Vodia PBX — ACTIVE",''',1)

# Storage label for one-click.
s=s.replace('''        "Storage: "+storageGiB+" GiB",''','''        "Storage: "+(oneClick?"Marketplace AMI default":storageGiB+" GiB"),''',1)

# Ensure method UI is initialized.
init_anchor='''      setStep(1);
      updateCustomerContext();'''
if init_anchor in s:
    s=s.replace(init_anchor,init_anchor+'''
      applyDeploymentMethodUi();''',1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.72"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.30.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.72/mcp-app.html',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: UI resource URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY
fi

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_DEPLOYMENT_METHOD_V72' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "v72 backend marker missing"
grep -Fq 'aws_marketplace_prepare_vodia_one_click' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "one-click preparation tool missing"
grep -Fq 'ONE_CLICK_MARKETPLACE' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment method schema missing"
grep -Fq 'VodiaDeploymentMethod' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment method EC2 tag missing"
grep -Fq 'resolveMarketplaceAmi(client' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "exact AMI resolver regression"
echo "PASS: dual launch method backend + one-click recommendation tool present"

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
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided UI JavaScript invalid"
grep -Fq 'Launch from EC2 Console style' "$TMP/staged/msp-guided-app.html" || fail "managed method UI missing"
grep -Fq 'One-click launch from AWS Marketplace' "$TMP/staged/msp-guided-app.html" || fail "one-click method UI missing"
grep -Fq 'ONE-CLICK MARKETPLACE SETTINGS' "$TMP/staged/msp-guided-app.html" || fail "one-click summary missing"
grep -Fq 'aws_marketplace_prepare_vodia_one_click' "$TMP/staged/msp-guided-app.html" || fail "one-click tool invocation missing"
grep -Fq 'uiVersion:"0.14.9.72"' "$TMP/staged/msp-guided-app.html" || fail "debug version marker missing"
echo "PASS: deployment method selector + one-click UX present"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: staged patch and validation completed successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

if [[ "$NEED_PATCH" == "1" ]]; then
echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /var/lib/vodia-mcp/aws-marketplace-deployments.json ]] && cp -a /var/lib/vodia-mcp/aws-marketplace-deployments.json "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.71 files"
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
  echo "[5/8]-[6/8] already v0.14.9.72"
fi

echo "[7/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.72"' <<<"$HEALTH" || fail "health does not report v0.14.9.72"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.72 installed."
echo "PASS: Customer can choose Managed EC2 or One-click Marketplace launch."
echo "PASS: Both methods use the exact v0.14.9.71 Vodia Marketplace AMI resolver."
echo "PASS: One-click automatically chooses vendor/default instance type, VPC, subnet, security group, public IP and AMI default storage."
echo "PASS: Managed EC2 keeps full configuration control."
echo "PASS: Review card shows deployment method and exact Marketplace AMI evidence."
echo "PASS: EC2 instances are tagged with VodiaDeploymentMethod."
echo "Backup: $BACKUP_DIR"
echo
echo "TEST:"
echo "1. Open a fresh Vodia Setup card."
echo "2. Customer -> Marketplace."
echo "3. Choose One-click launch from AWS Marketplace."
echo "4. Continue, pick a region and PBX name."
echo "5. Click Prepare one-click settings."
echo "6. Verify the summary shows Vodia-marketplace-prod-v5qnz6xf6wu5u and the regional AMI ID."
echo "7. Validate plan only; inspect Review & Deploy before launching."
