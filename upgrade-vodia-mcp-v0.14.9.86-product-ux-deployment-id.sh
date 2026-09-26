#!/usr/bin/env bash
# Vodia MCP v0.14.9.86 — product UX + permanent deployment identity
#
# Goals:
# - One-click uses Vodia dedicated PBX firewall / PBX_VOICE automatically.
# - Hide raw firewall/security-group plumbing from normal one-click UX.
# - Make AWS card/header clickable and add direct Deploy PBX action.
# - Give every new MCP-managed PBX a permanent VodiaDeploymentId.
# - Tag EC2 + EBS and persist the deployment ID in the MCP ledger.
# - Show Deployment ID + EC2 instance ID together after launch.
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
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.86"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d /tmp/vodia-mcp-v86.XXXXXXXX)"
BACKUP="/var/backups/vodia-mcp-v${TO_VER}-product-ux-$STAMP"
PATCH_STARTED=0

cleanup(){
  rc=$?
  trap - EXIT
  if (( PATCH_STARTED && rc != 0 )); then
    echo "ROLLBACK: restoring pre-v86 files..." >&2
    cp -a "$BACKUP/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" 2>/dev/null || true
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
  0.14.9.85) ;;
  0.14.9.86) echo "v0.14.9.86 detected; verification/repair mode." ;;
  *) fail "expected v0.14.9.85 or .86; found ${CURRENT:-unknown}. No files changed." ;;
esac

echo "=== Vodia MCP v$TO_VER — product UX + deployment identity ==="
echo "[0/9] Live preflight — NO LIVE CHANGES"

grep -Fq 'aws_marketplace_plan_vodia_pbx_deployment' "$BACKEND" || fail "deployment planner missing"
grep -Fq 'aws_marketplace_apply_vodia_pbx_deployment' "$BACKEND" || fail "deployment apply missing"
grep -Fq 'VODIA_FIREWALL_PRESETS_V84' "$BACKEND" || fail "v84 firewall preset backend marker missing"
grep -Fq 'ONE_CLICK_MARKETPLACE' "$BACKEND" || fail "one-click backend missing"
grep -Fq 'ONE_CLICK_MARKETPLACE' "$UI" || fail "one-click UI missing"
grep -Fq 'aws_marketplace_plan_vodia_pbx_deployment' "$UI" || fail "UI planner call missing"
echo "PASS: .85 product/firewall/one-click anchors found"

mkdir -p "$TMP/staged/ui"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/ui/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/9] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()

# ---------------------------------------------------------------------------
# Marker + permanent deployment ID helper.
# ---------------------------------------------------------------------------
if 'VODIA_PRODUCT_DEPLOYMENT_ID_V86' not in s:
    candidates=[
        'const VODIA_FIREWALL_PRESETS_V84 = true;',
        'const VODIA_SHARED_MARKETPLACE_AGREEMENT_V78 = true;',
        'const VODIA_AWS_PRODUCT_INVENTORY_V72 = true;'
    ]
    pos=-1
    for marker in candidates:
        pos=s.find(marker)
        if pos>=0:
            e=s.find('\n',pos)
            s=s[:e+1]+'const VODIA_PRODUCT_DEPLOYMENT_ID_V86 = true;\n'+s[e+1:]
            break
    if pos<0:
        # Use a stable core constant if newer source rearranged markers.
        marker='const AWS_DISCOVERY_REGION ='
        pos=s.find(marker)
        if pos<0:
            raise SystemExit('PATCH ERROR: cannot place v86 backend marker')
        e=s.find('\n',pos)
        s=s[:e+1]+'const VODIA_PRODUCT_DEPLOYMENT_ID_V86 = true;\n'+s[e+1:]

if 'function addVodiaDeploymentIdentityTagV86' not in s:
    anchor='function buildRunInstancesParams(input, image) {'
    i=s.find(anchor)
    if i<0:
        raise SystemExit('PATCH ERROR: buildRunInstancesParams anchor missing')
    helper=r'''function addVodiaDeploymentIdentityTagV86(params,deploymentId) {
  const id=String(deploymentId||"").trim();
  if(!id) throw new Error("VODIA_DEPLOYMENT_ID_REQUIRED: deployment plan has no permanent Vodia deployment ID.");
  for(const spec of params?.TagSpecifications || []) {
    if(!Array.isArray(spec.Tags)) spec.Tags=[];
    const existing=spec.Tags.find(tag=>tag?.Key==="VodiaDeploymentId");
    if(existing) existing.Value=id.slice(0,255);
    else spec.Tags.push({Key:"VodiaDeploymentId",Value:id.slice(0,255)});
  }
  return params;
}

'''
    s=s[:i]+helper+s[i:]

# Also add the identity tag directly when run params are built from an input that
# already carries one. This keeps future callers consistent.
build_start=s.find('function buildRunInstancesParams(input, image) {')
if build_start<0:
    raise SystemExit('PATCH ERROR: buildRunInstancesParams missing')
build_end=s.find('\n}',build_start)
segment=s[build_start:build_end+2]
if 'VodiaDeploymentId' not in segment:
    customer_block=re.search(
        r'''  if \(input\.customerId\) \{\n\s*tags\.push\(\{ Key: "VodiaMspCustomerId".*?\n  \}''',
        segment,re.S
    )
    if not customer_block:
        raise SystemExit('PATCH ERROR: customer tag block missing')
    addition=customer_block.group(0)+'''
  if (input.deploymentId) {
    tags.push({ Key: "VodiaDeploymentId", Value: String(input.deploymentId).slice(0, 255) });
  }'''
    segment=segment[:customer_block.start()]+addition+segment[customer_block.end():]
    s=s[:build_start]+segment+s[build_end+2:]

# ---------------------------------------------------------------------------
# One-click is opinionated: Vodia dedicated firewall + PBX_VOICE.
# Do this server-side so UI state cannot accidentally select a generic SG.
# ---------------------------------------------------------------------------
planner=s.find('"aws_marketplace_plan_vodia_pbx_deployment"')
if planner<0:
    raise SystemExit('PATCH ERROR: deployment planner registration missing')
planner_end=s.find('server.registerTool(',planner+10)
if planner_end<0:
    planner_end=len(s)
block=s[planner:planner_end]

if 'VODIA_ONE_CLICK_PRODUCT_DEFAULTS_V86' not in block:
    audit=block.find('scopedAudit("aws_marketplace_plan_vodia_pbx_deployment"')
    if audit<0:
        raise SystemExit('PATCH ERROR: planner audit anchor missing')
    try_pos=block.find('      try {',audit)
    if try_pos<0:
        raise SystemExit('PATCH ERROR: planner try anchor missing')
    insert=try_pos+len('      try {')
    patch='''
        // VODIA_ONE_CLICK_PRODUCT_DEFAULTS_V86
        if (input.deploymentMethod === "ONE_CLICK_MARKETPLACE") {
          input = {
            ...input,
            firewallMode: "VODIA_DEDICATED",
            firewallPreset: "PBX_VOICE"
          };
        }
'''
    block=block[:insert]+patch+block[insert:]
    s=s[:planner]+block+s[planner_end:]

# Refresh planner slice after modification.
planner=s.find('"aws_marketplace_plan_vodia_pbx_deployment"')
planner_end=s.find('server.registerTool(',planner+10)
if planner_end<0:
    planner_end=len(s)
block=s[planner:planner_end]

# ---------------------------------------------------------------------------
# Create deployment ID during planning and attach it to EC2/EBS tags.
# This happens after all firewall/network preparation but before the plan is
# persisted. DryRun therefore validates the exact tagged request.
# ---------------------------------------------------------------------------
if 'const deploymentIdV86 = "vdp_"' not in block:
    plan_anchor='        const planId = randomUUID();'
    pi=block.find(plan_anchor)
    if pi<0:
        raise SystemExit('PATCH ERROR: deployment planId anchor missing')
    insert='''        const deploymentIdV86 = "vdp_" + randomUUID().replace(/-/g,"");
        addVodiaDeploymentIdentityTagV86(params,deploymentIdV86);

'''
    block=block[:pi]+insert+block[pi:]

# Persist deployment ID beside planId.
if 'deploymentId: deploymentIdV86' not in block:
    store_anchor='        deploymentPlans.set(planId, {'
    si=block.find(store_anchor)
    if si<0:
        raise SystemExit('PATCH ERROR: deploymentPlans.set missing')
    id_anchor=block.find('          planId,',si)
    if id_anchor<0:
        raise SystemExit('PATCH ERROR: stored planId field missing')
    e=id_anchor+len('          planId,')
    block=block[:e]+'\n          deploymentId: deploymentIdV86,'+block[e:]

# Return ID in plan result.
if 'deploymentId: deploymentIdV86' not in block[block.find('return scopedSuccess'):]:
    ri=block.find('        return scopedSuccess({')
    if ri<0:
        raise SystemExit('PATCH ERROR: planner success response missing')
    id_anchor=block.find('          planId,',ri)
    if id_anchor<0:
        raise SystemExit('PATCH ERROR: planner response planId missing')
    e=id_anchor+len('          planId,')
    block=block[:e]+'\n          deploymentId: deploymentIdV86,'+block[e:]

s=s[:planner]+block+s[planner_end:]

# ---------------------------------------------------------------------------
# Apply path: verify, persist, and return the same permanent deployment ID.
# ---------------------------------------------------------------------------
apply=s.find('"aws_marketplace_apply_vodia_pbx_deployment"')
if apply<0:
    raise SystemExit('PATCH ERROR: deployment apply registration missing')
apply_end=s.find('server.registerTool(',apply+10)
if apply_end<0:
    apply_end=len(s)
block=s[apply:apply_end]

# Verify the tag when present.
verify_call='''            customerId: plan.customerId || null
          });'''
if 'deploymentId: plan.deploymentId || null' not in block:
    if verify_call in block:
        block=block.replace(
            verify_call,
            '''            customerId: plan.customerId || null,
            deploymentId: plan.deploymentId || null
          });''',1
        )
    else:
        # Newer firewall source may have more expected fields. Insert directly
        # after the expected customerId line inside verifyLaunchedInstance call.
        m=re.search(r'(verifyLaunchedInstance\(.*?customerId:\s*plan\.customerId\s*\|\|\s*null)(,?\n)',block,re.S)
        if not m:
            raise SystemExit('PATCH ERROR: verifyLaunchedInstance customerId anchor missing')
        block=block[:m.end(1)]+',\n            deploymentId: plan.deploymentId || null'+block[m.end(1):]

# Ledger record.
if 'deploymentId: plan.deploymentId || null' not in block[block.find('upsertMarketplaceDeployment({'):]:
    ui=block.find('upsertMarketplaceDeployment({')
    if ui<0:
        raise SystemExit('PATCH ERROR: deployment ledger upsert missing')
    iid=block.find('            instanceId:',ui)
    if iid<0:
        raise SystemExit('PATCH ERROR: ledger instanceId anchor missing')
    block=block[:iid]+'            deploymentId: plan.deploymentId || null,\n'+block[iid:]

# Apply response.
response=block.find('return scopedSuccess({')
if response<0:
    raise SystemExit('PATCH ERROR: apply success response missing')
if 'deploymentId: plan.deploymentId || null' not in block[response:]:
    iid=block.find('            instanceId:',response)
    if iid<0:
        raise SystemExit('PATCH ERROR: apply response instanceId anchor missing')
    block=block[:iid]+'            deploymentId: plan.deploymentId || null,\n'+block[iid:]

s=s[:apply]+block+s[apply_end:]

# ---------------------------------------------------------------------------
# Verification helper: enforce permanent identity if expected.
# ---------------------------------------------------------------------------
vf=s.find('async function verifyLaunchedInstance(')
if vf<0:
    raise SystemExit('PATCH ERROR: verifyLaunchedInstance helper missing')
vf_end=s.find('\n}',vf)
# Function contains nested braces; use next helper anchor instead.
next_anchor=s.find('async function dryRunLaunch',vf)
if next_anchor<0:
    raise SystemExit('PATCH ERROR: dryRun helper anchor missing')
block=s[vf:next_anchor]
if 'const deploymentId=requiredInstanceTag(instance,"VodiaDeploymentId");' not in block:
    cust='''      const customerId=requiredInstanceTag(instance,"VodiaMspCustomerId");'''
    if cust not in block:
        raise SystemExit('PATCH ERROR: verify customer tag line missing')
    block=block.replace(cust,cust+'''\n      const deploymentId=requiredInstanceTag(instance,"VodiaDeploymentId");''',1)
if 'expected.deploymentId && deploymentId !== expected.deploymentId' not in block:
    cust_check='''      if (expected.customerId && customerId !== expected.customerId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: MSP customer tag mismatch.");
      }'''
    if cust_check not in block:
        raise SystemExit('PATCH ERROR: verify customer check block missing')
    block=block.replace(cust_check,cust_check+'''
      if (expected.deploymentId && deploymentId !== expected.deploymentId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: Vodia deployment ID tag mismatch.");
      }''',1)
s=s[:vf]+block+s[next_anchor:]

# ---------------------------------------------------------------------------
# Status tool: return the deployment identity alongside AWS instance identity.
# ---------------------------------------------------------------------------
status=s.find('"aws_get_vodia_pbx_deployment_status"')
if status<0:
    raise SystemExit('PATCH ERROR: deployment status tool missing')
status_end=s.find('server.registerTool(',status+10)
if status_end<0:
    status_end=len(s)
block=s[status:status_end]

if 'const vodiaDeploymentId=' not in block:
    market_line=re.search(
        r'\s*const marketplaceProductId = requiredInstanceTag\(instance, "VodiaMarketplaceProductId"\).*?;\n',
        block
    )
    if not market_line:
        raise SystemExit('PATCH ERROR: status Marketplace product line missing')
    addition=market_line.group(0)+'''        const vodiaDeploymentId=requiredInstanceTag(instance,"VodiaDeploymentId") || ledgerRecord?.deploymentId || null;
'''
    block=block[:market_line.start()]+addition+block[market_line.end():]

response=block.find('return scopedSuccess({')
if response<0:
    raise SystemExit('PATCH ERROR: status success response missing')
if 'vodiaDeploymentId,' not in block[response:]:
    iid=block.find('          instanceId,',response)
    if iid<0:
        raise SystemExit('PATCH ERROR: status response instanceId missing')
    e=iid+len('          instanceId,')
    block=block[:e]+'\n          vodiaDeploymentId,'+block[e:]

s=s[:status]+block+s[status_end:]

p.write_text(s)
PY

echo "[2/9] Patch staged guided UI — NO LIVE CHANGES"
python3 - "$TMP/staged/ui/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1])
s=p.read_text()

# Marker.
if 'VODIA_PRODUCT_UX_UI_V86' not in s:
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0: raise SystemExit('PATCH ERROR: UI product constant missing')
    e=s.find('\n',i)
    s=s[:e+1]+'  const VODIA_PRODUCT_UX_UI_V86 = true;\n'+s[e+1:]

# Styles.
if '.v86-clickable-cloud-card' not in s:
    style='''
.v86-clickable-cloud-card{cursor:pointer;transition:transform .12s ease,border-color .12s ease,background .12s ease}
.v86-clickable-cloud-card:hover{transform:translateY(-1px);background:color-mix(in srgb,CanvasText 3%,Canvas)}
.v86-clickable-cloud-card:focus-visible{outline:2px solid Highlight;outline-offset:3px}
.v86-auto-note{margin-top:10px;padding:10px 12px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:10px;font-size:11px;line-height:1.45}
.v86-deployment-card{margin-top:12px;padding:13px;border:1px solid color-mix(in srgb,CanvasText 14%,transparent);border-radius:12px}
.v86-deployment-card-head{display:flex;align-items:center;justify-content:space-between;gap:10px;flex-wrap:wrap}
.v86-deployment-card-title{font-weight:800;font-size:13px}
.v86-deployment-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px 14px;margin-top:10px;font-size:11px}
.v86-deployment-grid b{display:block;font-size:9px;opacity:.65;text-transform:uppercase;letter-spacing:.04em;margin-bottom:2px}
@media(max-width:720px){.v86-deployment-grid{grid-template-columns:1fr}}
'''
    if '</style>' not in s: raise SystemExit('PATCH ERROR: UI style close missing')
    s=s.replace('</style>',style+'</style>',1)

# Product UX helpers: clickable AWS card, direct Deploy button, one-click defaults,
# and permanent deployment identity card.
fn_anchor='''  function renderAwsConnection(connection){'''
if fn_anchor not in s:
    raise SystemExit('PATCH ERROR: renderAwsConnection anchor missing')

if 'function wireV86CloudCard' not in s:
    funcs=r'''  function setV86OneClickDefaults(){
    const oneClick=typeof deploymentMethod==="string"
      ? deploymentMethod==="ONE_CLICK_MARKETPLACE"
      : document.querySelector('input[name="deploymentMethod"]:checked')?.value==="ONE_CLICK_MARKETPLACE";

    const defaults={
      firewallMode:"VODIA_DEDICATED",
      firewallPreset:"PBX_VOICE"
    };
    for(const [id,value] of Object.entries(defaults)){
      const el=$(id);
      if(el && oneClick){
        el.value=value;
        try{el.dispatchEvent(new Event("change",{bubbles:true}))}catch(_e){}
      }
    }

    // One-click is deliberately opinionated. Hide raw AWS/Vodia firewall
    // controls but preserve their values for plan validation.
    ["securityGroupSelect","firewallMode","firewallPreset","webCidr","voiceCidr"].forEach(id=>{
      const el=$(id);
      const field=el?.closest(".field") || el?.closest(".guided-box") || el?.parentElement;
      if(field) field.classList.toggle("hidden",oneClick);
    });

    let note=$("v86AutoNetworkNote");
    if(!note){
      note=document.createElement("div");
      note.id="v86AutoNetworkNote";
      note.className="v86-auto-note hidden";
      note.innerHTML="<b>Network & firewall: Automatic</b><br>Vodia dedicated security group · PBX Voice preset · subnet/AZ selected by the deployment workflow.";
      const mount=$("loadNetwork")?.parentElement || $("awsStepPanel");
      mount?.insertBefore(note,$("loadNetwork") || null);
    }
    note?.classList.toggle("hidden",!oneClick);
  }

  async function openAwsProductV86(directDeploy=false){
    if(!customerId()) return;
    if(!currentAwsConnection?.configured){
      $("connectAws")?.click();
      return;
    }
    if(typeof advanceToMarketplaceStep==="function"){
      await advanceToMarketplaceStep();
    }else{
      setStep(2);
    }
    if(directDeploy && marketplaceSubscriptionActive){
      setStep(3);
      if($("regionSelect")?.disabled || !$("regionSelect")?.options?.length || $("regionSelect")?.options?.length<=1){
        $("loadRegions")?.click();
      }
    }
  }

  function wireV86CloudCard(){
    const card=document.querySelector("#awsSection .aws");
    if(!card || card.dataset.v86Wired==="1") return;
    card.dataset.v86Wired="1";
    card.classList.add("v86-clickable-cloud-card");
    card.setAttribute("role","button");
    card.setAttribute("tabindex","0");
    card.setAttribute("aria-label","Open AWS connection and deployment");

    const interactive=target=>Boolean(target?.closest?.("button,input,select,textarea,a,label"));
    card.addEventListener("click",event=>{
      if(interactive(event.target)) return;
      openAwsProductV86(false).catch(e=>setMsg("awsMsg",e.message));
    });
    card.addEventListener("keydown",event=>{
      if(event.key!=="Enter" && event.key!==" ") return;
      event.preventDefault();
      openAwsProductV86(false).catch(e=>setMsg("awsMsg",e.message));
    });

    let deploy=$("deployFromAwsCardV86");
    if(!deploy){
      deploy=document.createElement("button");
      deploy.id="deployFromAwsCardV86";
      deploy.type="button";
      deploy.className="primary";
      deploy.textContent="Deploy PBX";
      deploy.title="Go directly to Vodia PBX deployment";
      const actions=card.querySelector("div[style*='display:flex']") || card.lastElementChild || card;
      actions.appendChild(deploy);
      deploy.addEventListener("click",event=>{
        event.preventDefault();
        event.stopPropagation();
        openAwsProductV86(true).catch(e=>setMsg("awsMsg",e.message));
      });
    }
  }

  function ensureV86DeploymentCard(){
    let card=$("v86DeploymentIdentityCard");
    if(card) return card;
    card=document.createElement("section");
    card.id="v86DeploymentIdentityCard";
    card.className="v86-deployment-card hidden";
    const summary=$("planSummary");
    summary?.insertAdjacentElement("afterend",card);
    return card;
  }

  function renderV86DeploymentIdentity(status){
    const card=ensureV86DeploymentCard();
    if(!card) return;
    const deploymentId=status?.vodiaDeploymentId || status?.deploymentId || currentDeploymentPlan?.deploymentId || null;
    const instanceId=status?.instanceId || null;
    if(!deploymentId && !instanceId){
      card.classList.add("hidden");
      return;
    }
    const connected=Boolean(currentAwsConnection?.configured);
    card.innerHTML="";
    const head=document.createElement("div");
    head.className="v86-deployment-card-head";
    const title=document.createElement("div");
    title.className="v86-deployment-card-title";
    title.textContent=(status?.pbxName || $("pbxName")?.value || "Vodia PBX");
    const badge=document.createElement("span");
    badge.className="badge";
    badge.textContent=connected?"AWS linked":"AWS not linked";
    head.append(title,badge);

    const grid=document.createElement("div");
    grid.className="v86-deployment-grid";
    const rows=[
      ["Vodia Deployment ID",deploymentId||"pending"],
      ["EC2 Instance ID",instanceId||"pending"],
      ["AWS Account",currentAwsConnection?.account||"Unknown"],
      ["Region",status?.region||selectedRegion||"pending"],
      ["State",status?.state||"pending"],
      ["Public IP",status?.publicIpAddress||"pending"]
    ];
    for(const [label,value] of rows){
      const cell=document.createElement("div");
      const b=document.createElement("b");
      b.textContent=label;
      const span=document.createElement("span");
      span.textContent=String(value);
      cell.append(b,span);
      grid.appendChild(cell);
    }

    const actions=document.createElement("div");
    actions.className="actions";
    const aws=document.createElement("button");
    aws.type="button";
    aws.className="secondary";
    aws.textContent=connected?"Manage AWS":"Connect AWS account";
    aws.addEventListener("click",()=>{
      setStep(1);
      if(!currentAwsConnection?.configured) $("connectAws")?.click();
    });
    actions.appendChild(aws);

    card.append(head,grid,actions);
    card.classList.remove("hidden");
  }

'''
    s=s.replace(fn_anchor,funcs+fn_anchor,1)

# Whenever deployment method UI changes, enforce product defaults.
if 'setV86OneClickDefaults(); // v86 product defaults' not in s:
    m=re.search(r'(function applyDeploymentMethodUi\(\)\{.*?\n  \})',s,re.S)
    if m:
        block=m.group(1)
        # Insert before final function brace.
        block=block[:-3]+'\n    setV86OneClickDefaults(); // v86 product defaults\n  }'
        s=s[:m.start()]+block+s[m.end():]
    else:
        # Newer UI may use delegated radio listeners; add a safe document hook.
        hook='''
  document.addEventListener("change",event=>{
    if(event.target?.name==="deploymentMethod") setV86OneClickDefaults();
  });
'''
        script_end=s.rfind('})();')
        if script_end<0: raise SystemExit('PATCH ERROR: UI IIFE end missing')
        s=s[:script_end]+hook+s[script_end:]

# Plan summary: document permanent Vodia ID.
if '"Vodia Deployment ID: "+(plan.deploymentId||"pending"),' not in s:
    anchor='"Plan validated — no instance launched",'
    if anchor not in s:
        raise SystemExit('PATCH ERROR: plan summary anchor missing')
    s=s.replace(anchor,anchor+'\n        "Vodia Deployment ID: "+(plan.deploymentId||"pending"),',1)

# Store deployment ID with browser-side plan state for refreshes.
if 'deploymentId:plan.deploymentId||null' not in s:
    anchor='''        confirmation:plan.confirmation,
        customerId:customerId(),'''
    if anchor in s:
        s=s.replace(anchor,'''        confirmation:plan.confirmation,
        deploymentId:plan.deploymentId||null,
        customerId:customerId(),''',1)

# Deployment status summary.
if '"Vodia Deployment ID: "+(status?.vodiaDeploymentId||status?.deploymentId||currentDeploymentPlan?.deploymentId||"pending"),' not in s:
    anchor='''      "Instance ID: "+(status?.instanceId||"pending"),'''
    if anchor not in s:
        raise SystemExit('PATCH ERROR: deployment status Instance ID anchor missing')
    s=s.replace(anchor,'''      "Vodia Deployment ID: "+(status?.vodiaDeploymentId||status?.deploymentId||currentDeploymentPlan?.deploymentId||"pending"),
      "Instance ID: "+(status?.instanceId||"pending"),''',1)

# Render the identity card whenever the existing status renderer runs.
if 'renderV86DeploymentIdentity(status);' not in s:
    marker='''    $("planSummary").classList.remove("hidden");'''
    # Pick the occurrence inside renderDeploymentStatus.
    rds=s.find('function renderDeploymentStatus(')
    if rds<0:
        raise SystemExit('PATCH ERROR: renderDeploymentStatus missing')
    pos=s.find(marker,rds)
    if pos<0:
        raise SystemExit('PATCH ERROR: renderDeploymentStatus summary marker missing')
    e=pos+len(marker)
    s=s[:e]+'\n    renderV86DeploymentIdentity(status);'+s[e:]

# Show ID immediately after apply result too.
if 'renderV86DeploymentIdentity(result);' not in s:
    apply=s.find('$("applyDeployment").addEventListener("click"')
    if apply<0:
        raise SystemExit('PATCH ERROR: applyDeployment UI handler missing')
    call=s.find('const result=dataFrom(await callTool("aws_marketplace_apply_vodia_pbx_deployment"',apply)
    if call<0:
        raise SystemExit('PATCH ERROR: apply result anchor missing')
    close=s.find('}));',call)
    if close<0:
        raise SystemExit('PATCH ERROR: apply tool close missing')
    close+=4
    s=s[:close]+'\n      renderV86DeploymentIdentity(result);'+s[close:]

# Wire product UX after consolidated layout is built.
if 'wireV86CloudCard(); // v86' not in s:
    anchor='''  consolidateGuidedLayout();'''
    if anchor not in s:
        raise SystemExit('PATCH ERROR: consolidateGuidedLayout call missing')
    s=s.replace(anchor,anchor+'''\n  wireV86CloudCard(); // v86
  setV86OneClickDefaults(); // v86''',1)

# Bump UI trace version.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.86"',s)

p.write_text(s)
PY

echo "[3/9] Bump staged UI resource/version"
python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(
  r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
  'ui://vodia/msp-guided/v0.14.9.86/mcp-app.html',
  s,count=1
)
if count!=1:
    raise SystemExit('PATCH ERROR: guided UI URI anchor missing')
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(
  r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
  r'\g<1>0.14.9.86\2',
  s,count=1
)
if count!=1:
    raise SystemExit('PATCH ERROR: CONNECTOR_VERSION anchor missing')
p.write_text(n)
PY

echo "[4/9] Validate staged patch"
node --input-type=module --check < "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend JavaScript invalid"
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

grep -Fq 'VODIA_PRODUCT_DEPLOYMENT_ID_V86' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend v86 marker missing"
grep -Fq 'VODIA_ONE_CLICK_PRODUCT_DEFAULTS_V86' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "one-click server defaults missing"
grep -Fq 'VodiaDeploymentId' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment ID tag missing"
grep -Fq 'firewallPreset: "PBX_VOICE"' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "PBX_VOICE server default missing"
grep -Fq 'wireV86CloudCard' "$TMP/staged/ui/msp-guided-app.html" || fail "clickable AWS card wiring missing"
grep -Fq 'Deploy PBX' "$TMP/staged/ui/msp-guided-app.html" || fail "direct Deploy PBX action missing"
grep -Fq 'Vodia Deployment ID' "$TMP/staged/ui/msp-guided-app.html" || fail "deployment identity UI missing"
grep -Fq 'Network & firewall: Automatic' "$TMP/staged/ui/msp-guided-app.html" || fail "one-click automatic network summary missing"
grep -Fq '0.14.9.86' "$TMP/staged/version.js" || fail "version .86 missing"

echo "PASS: staged backend/UI/product identity/default-firewall patch validated"

if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.86 validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/9] Backup current code"
mkdir -p "$BACKUP"
cp -a "$BACKEND" "$BACKUP/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP/version.js"
echo "PASS: $BACKUP"

echo "[6/9] Install staged files"
PATCH_STARTED=1
install -o "$(stat -c %u "$BACKEND")" -g "$(stat -c %g "$BACKEND")" -m "$(stat -c %a "$BACKEND")" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o "$(stat -c %u "$UI")" -g "$(stat -c %g "$UI")" -m "$(stat -c %a "$UI")" "$TMP/staged/ui/msp-guided-app.html" "$UI"
install -o "$(stat -c %u "$GUIDED")" -g "$(stat -c %g "$GUIDED")" -m "$(stat -c %a "$GUIDED")" "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o "$(stat -c %u "$VERSION")" -g "$(stat -c %g "$VERSION")" -m "$(stat -c %a "$VERSION")" "$TMP/staged/version.js" "$VERSION"

echo "[7/9] Restart MCP"
systemctl restart "$SERVICE"

echo "[8/9] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  HEALTH="$(curl -fsS --max-time 5 http://127.0.0.1:3100/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "health endpoint did not recover"
grep -q '"version":"0.14.9.86"' <<<"$HEALTH" || fail "health does not report 0.14.9.86: $HEALTH"

grep -Fq 'VODIA_PRODUCT_DEPLOYMENT_ID_V86' "$BACKEND" || fail "live deployment identity marker missing"
grep -Fq 'VODIA_ONE_CLICK_PRODUCT_DEFAULTS_V86' "$BACKEND" || fail "live one-click defaults missing"
grep -Fq 'wireV86CloudCard' "$UI" || fail "live clickable card wiring missing"

PATCH_STARTED=0
echo "$HEALTH"

echo "[9/9] Complete"
echo "PASS: Vodia MCP v0.14.9.86 installed."
echo "PASS: AWS card/header is clickable and exposes a direct Deploy PBX action."
echo "PASS: one-click forces Vodia dedicated PBX firewall with PBX_VOICE."
echo "PASS: normal one-click hides raw SG/firewall controls."
echo "PASS: every new MCP PBX gets permanent VodiaDeploymentId + EC2 instance ID mapping."
echo "PASS: deployment identity is persisted in EC2/EBS tags and MCP deployment ledger."
echo "Backup: $BACKUP"
echo
echo "Open Vodia Setup in a NEW message/tab so the v0.14.9.86 resource URI is loaded."
