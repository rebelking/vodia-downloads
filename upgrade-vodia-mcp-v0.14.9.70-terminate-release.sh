#!/usr/bin/env bash
# Vodia MCP v0.14.9.70 — approval-gated EC2 termination and deployment-slot release
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
AWS_DIR="$APP/aws"
POLICY_TARGET="$AWS_DIR/aws-marketplace-vodia-deployment-role-policy-v2-terminate.json"
CF_TARGET="$AWS_DIR/cloudformation/vodia-mcp-customer-access-v2-terminate.yaml"
ASSET_COMMIT="1a3c96997e0d640f845219827d9b8be380404c07"
RAW="https://raw.githubusercontent.com/rebelking/vodia-downloads/$ASSET_COMMIT"
V69_COMMIT="61e943da006823112dc06df05b8389ffba002a2b"
V69_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/$V69_COMMIT/upgrade-vodia-mcp-v0.14.9.69-deployment-monitor.sh"
TO_VER="0.14.9.70"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-terminate-release-$STAMP"
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
if [[ "$CURRENT" == "0.14.9.68" ]]; then
  echo "[prerequisite] Installing deployment monitor v0.14.9.69"
  curl -fsSL "$V69_URL" -o "$TMP/upgrade-v69.sh"
  chmod 0700 "$TMP/upgrade-v69.sh"
  "$TMP/upgrade-v69.sh"
  CURRENT="$(read_version)"
fi
case "$CURRENT" in
  0.14.9.69) ;;
  0.14.9.70) echo "v0.14.9.70 already installed; verification mode." ;;
  *) fail "expected v0.14.9.68, .69, or .70; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — guarded terminate and release ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"
curl -fsSL "$RAW/aws-marketplace-vodia-deployment-role-policy-v2-terminate.json" -o "$TMP/staged/deployment-role-policy.json"
curl -fsSL "$RAW/vodia-mcp-customer-access-v2-terminate.yaml" -o "$TMP/staged/customer-access.yaml"

if [[ "$CURRENT" != "$TO_VER" ]]; then
  echo "[1/9] Patch staged backend — NO LIVE CHANGES"
  python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_TERMINATE_RELEASE_V70' in s:
    raise SystemExit(0)

import_anchor='''  DescribeInstanceStatusCommand,
  RunInstancesCommand'''
if import_anchor not in s:
    raise SystemExit("PATCH ERROR: EC2 command import anchor missing")
s=s.replace(import_anchor,'''  DescribeInstanceStatusCommand,
  DescribeInstanceAttributeCommand,
  TerminateInstancesCommand,
  RunInstancesCommand''',1)

map_anchor='''const deploymentLocks = new Set();'''
if map_anchor not in s:
    raise SystemExit("PATCH ERROR: deployment lock anchor missing")
s=s.replace(map_anchor,map_anchor+'''\nconst terminationPlans = new Map();
const VODIA_TERMINATION_PLAN_TTL_MS = Number(process.env.VODIA_MCP_AWS_TERMINATION_PLAN_TTL_MS || 10 * 60 * 1000);''',1)

register_anchor='''export function registerAwsMarketplaceDeployTools(server, ctx) {'''
if register_anchor not in s:
    raise SystemExit("PATCH ERROR: tool registration anchor missing")

helpers=r'''
const VODIA_TERMINATE_RELEASE_V70 = true;

function cleanExpiredTerminationPlans() {
  const now=Date.now();
  for (const [id,plan] of terminationPlans.entries()) {
    if (plan.expiresAt <= now) terminationPlans.delete(id);
  }
}

function terminationLedgerRecord(instanceId, customerId) {
  const ledger=loadMarketplaceDeploymentLedger();
  return ledger.deployments.find(row =>
    row?.instanceId === instanceId &&
    (!customerId || !row.customerId || row.customerId === customerId)
  ) || null;
}

function validateTerminationTarget(instance, ledgerRecord, customerId) {
  if (!instance?.InstanceId) throw new Error("INSTANCE_NOT_FOUND: deployment instance is unavailable.");
  const managedBy=requiredInstanceTag(instance,"ManagedBy");
  const taggedCustomer=requiredInstanceTag(instance,"VodiaMspCustomerId");
  const productId=requiredInstanceTag(instance,"VodiaMarketplaceProductId") || ledgerRecord?.productId || null;
  const agreementId=requiredInstanceTag(instance,"VodiaMarketplaceAgreementId") || ledgerRecord?.agreementId || null;
  if (managedBy !== "VodiaMCP") throw new Error("TERMINATION_NOT_VODIA_MANAGED: only ManagedBy=VodiaMCP instances may be terminated.");
  if (!productId || !agreementId) throw new Error("TERMINATION_MARKETPLACE_BINDING_MISSING: product/agreement binding was not verified.");
  if (customerId && taggedCustomer && taggedCustomer !== customerId) {
    throw new Error("DEPLOYMENT_CUSTOMER_MISMATCH: instance belongs to another MSP customer.");
  }
  if (customerId && !taggedCustomer && !ledgerRecord) {
    throw new Error("DEPLOYMENT_NOT_IN_CUSTOMER_LEDGER: legacy instance is not assigned to the selected customer.");
  }
  return {
    name: requiredInstanceTag(instance,"Name") || ledgerRecord?.name || "Vodia-PBX",
    productId,
    agreementId,
    customerId: customerId || ledgerRecord?.customerId || taggedCustomer || null
  };
}

function terminationVolumeImpact(instance) {
  return (instance?.BlockDeviceMappings || []).map(mapping => ({
    deviceName: mapping.DeviceName || null,
    volumeId: mapping.Ebs?.VolumeId || null,
    deleteOnTermination: Boolean(mapping.Ebs?.DeleteOnTermination),
    status: mapping.Ebs?.Status || null
  }));
}

async function verifyTerminatePermission(client, instanceId) {
  try {
    await client.send(new TerminateInstancesCommand({ InstanceIds:[instanceId], DryRun:true }));
    throw new Error("TERMINATION_DRY_RUN_UNEXPECTED_SUCCESS: AWS did not return DryRunOperation.");
  } catch (error) {
    const code=String(error?.name || error?.Code || error?.code || "");
    const message=String(error?.message || error);
    if (code === "DryRunOperation" || /DryRunOperation/i.test(message)) return true;
    if (code === "UnauthorizedOperation" || /not authorized|UnauthorizedOperation/i.test(message)) {
      throw new Error("TERMINATE_PERMISSION_REQUIRED: VodiaMCPDeploymentRole needs ec2:TerminateInstances. Update the customer CloudFormation stack or role policy, then retry.");
    }
    throw error;
  }
}

'''
s=s.replace(register_anchor,helpers+register_anchor,1)

status_tool='''  server.registerTool(
    "aws_get_vodia_pbx_deployment_status",'''
if status_tool not in s:
    raise SystemExit("PATCH ERROR: status tool insertion anchor missing")

tools=r'''  server.registerTool(
    "aws_marketplace_plan_terminate_vodia_pbx",
    {
      title: "Plan Vodia PBX termination",
      description: "Read-only, customer-scoped termination preflight. Verifies Vodia ownership, Marketplace binding, termination protection, EBS volume impact, and ec2:TerminateInstances permission using AWS DryRun. Returns an exact approval phrase; it does not terminate anything.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3),
        instanceId: z.string().regex(/^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async (input, extra) => {
      scopedAudit("aws_marketplace_plan_terminate_vodia_pbx", { customerId:input.customerId||null, region:input.region, instanceId:input.instanceId });
      try {
        cleanExpiredTerminationPlans();
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN"]);
        const client=ec2Client(c.roleArn,c.externalId,input.region);
        const out=await client.send(new DescribeInstancesCommand({ InstanceIds:[input.instanceId] }));
        const instance=out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${input.instanceId}`);
        const ledgerRecord=terminationLedgerRecord(input.instanceId,c.customerId);
        const target=validateTerminationTarget(instance,ledgerRecord,c.customerId);
        const state=String(instance.State?.Name||"unknown").toLowerCase();
        if (state === "terminated") throw new Error("INSTANCE_ALREADY_TERMINATED: refresh the subscription to reconcile its release state.");
        if (["shutting-down"].includes(state)) throw new Error("INSTANCE_TERMINATION_ALREADY_IN_PROGRESS: wait for AWS to report terminated.");

        const protection=await client.send(new DescribeInstanceAttributeCommand({
          InstanceId:input.instanceId,
          Attribute:"disableApiTermination"
        }));
        if (protection.DisableApiTermination?.Value === true) {
          throw new Error("TERMINATION_PROTECTION_ENABLED: disable EC2 API termination protection in AWS before retrying.");
        }
        await verifyTerminatePermission(client,input.instanceId);

        const volumes=terminationVolumeImpact(instance);
        const deletingVolumes=volumes.filter(volume=>volume.deleteOnTermination);
        const preservedVolumes=volumes.filter(volume=>!volume.deleteOnTermination);
        const planId=randomUUID();
        const confirmation=`TERMINATE VODIA PBX ${target.name} INSTANCE ${input.instanceId} IN ${input.region}`;
        const expiresAt=Date.now()+VODIA_TERMINATION_PLAN_TTL_MS;
        terminationPlans.set(planId,{
          planId,
          customerId:c.customerId||null,
          roleArn:c.roleArn,
          externalId:c.externalId,
          region:input.region,
          instanceId:input.instanceId,
          name:target.name,
          productId:target.productId,
          agreementId:target.agreementId,
          ledgerRecord,
          confirmation,
          createdAt:Date.now(),
          expiresAt
        });
        return scopedSuccess({
          planId,
          expiresAt:new Date(expiresAt).toISOString(),
          confirmation,
          irreversible:true,
          permissionDryRunVerified:true,
          terminationProtection:false,
          deployment:{
            customerId:c.customerId||null,
            name:target.name,
            instanceId:input.instanceId,
            region:input.region,
            state,
            marketplaceAgreementId:target.agreementId,
            marketplaceProductId:target.productId
          },
          volumes,
          volumesDeletedOnTermination:deletingVolumes,
          volumesPreservedAfterTermination:preservedVolumes,
          changesMade:false
        }, { operation:"AWS_MARKETPLACE_PLAN_TERMINATE_VODIA_PBX", readOnly:true }, "Termination preflight passed. No AWS resource was changed. Review volume impact and enter the exact approval phrase to terminate.");
      } catch (error) {
        return failure(error,"AWS Marketplace Vodia PBX termination plan");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_apply_terminate_vodia_pbx",
    {
      title: "Terminate Vodia PBX and release deployment slot",
      description: "Permanently terminates one preflighted customer-owned Vodia EC2 instance after exact approval. The Vodia deployment slot is released only after AWS later reports the instance terminated.",
      inputSchema: {
        planId: z.string().uuid(),
        confirmation: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:false, destructiveHint:true, openWorldHint:true }
    },
    async ({planId,confirmation},extra) => {
      scopedAudit("aws_marketplace_apply_terminate_vodia_pbx",{planId});
      try {
        cleanExpiredTerminationPlans();
        const plan=terminationPlans.get(planId);
        if (!plan) throw new Error("TERMINATION_PLAN_NOT_FOUND_OR_EXPIRED: create a new termination plan.");
        if (confirmation !== plan.confirmation) throw new Error(`CONFIRMATION_MISMATCH: exact confirmation required: ${plan.confirmation}`);
        if (plan.customerId) requireCustomerAccess(extra,plan.customerId,["MSP_ADMIN","CUSTOMER_ADMIN"]);

        const client=ec2Client(plan.roleArn,plan.externalId,plan.region);
        const out=await client.send(new DescribeInstancesCommand({ InstanceIds:[plan.instanceId] }));
        const instance=out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${plan.instanceId}`);
        const currentLedger=terminationLedgerRecord(plan.instanceId,plan.customerId) || plan.ledgerRecord;
        const target=validateTerminationTarget(instance,currentLedger,plan.customerId);
        if (target.name !== plan.name || target.agreementId !== plan.agreementId || target.productId !== plan.productId) {
          throw new Error("TERMINATION_TARGET_CHANGED: instance identity or Marketplace binding changed after planning.");
        }
        const state=String(instance.State?.Name||"unknown").toLowerCase();
        if (state === "terminated") throw new Error("INSTANCE_ALREADY_TERMINATED: no termination request was sent.");
        if (state === "shutting-down") throw new Error("INSTANCE_TERMINATION_ALREADY_IN_PROGRESS: no duplicate request was sent.");

        const terminated=await client.send(new TerminateInstancesCommand({ InstanceIds:[plan.instanceId] }));
        const transition=(terminated.TerminatingInstances||[])[0]||{};
        const now=new Date().toISOString();
        upsertMarketplaceDeployment({
          ...(currentLedger||{}),
          customerId:plan.customerId||currentLedger?.customerId||null,
          productId:plan.productId,
          agreementId:plan.agreementId,
          instanceId:plan.instanceId,
          name:plan.name,
          region:plan.region,
          instanceState:transition.CurrentState?.Name||"shutting-down",
          terminationRequestedAt:now,
          terminationRequestedBy:"mcp-approved-plan",
          releaseAgreementOnTermination:true,
          agreementReleasedAt:null,
          source:"termination-requested"
        });
        terminationPlans.delete(planId);
        return scopedSuccess({
          instanceId:plan.instanceId,
          name:plan.name,
          region:plan.region,
          previousState:transition.PreviousState?.Name||state,
          state:transition.CurrentState?.Name||"shutting-down",
          terminationRequestedAt:now,
          agreementId:plan.agreementId,
          agreementReleasePending:true,
          agreementReleased:false,
          changesMade:true
        }, { operation:"AWS_MARKETPLACE_APPLY_TERMINATE_VODIA_PBX", readOnly:false }, `Termination requested for ${plan.instanceId}. The Vodia deployment slot will be released only after AWS confirms terminated.`);
      } catch (error) {
        return failure(error,"AWS Marketplace Vodia PBX termination apply");
      }
    }
  );

'''
s=s.replace(status_tool,tools+status_tool,1)

# Released, terminated records make the Vodia deployment slot available while
# retaining the prior deployment as audit/history.
usage_anchor='''function marketplaceUsageView(record, source) {
  if (!record) return { status: "AVAILABLE", source: source || "none" };'''
if usage_anchor not in s:
    raise SystemExit("PATCH ERROR: Marketplace usage view anchor missing")
usage_new='''function marketplaceUsageView(record, source) {
  if (!record) return { status: "AVAILABLE", source: source || "none" };
  if (record.agreementReleasedAt && String(record.instanceState || "").toLowerCase() === "terminated") {
    return {
      status: "AVAILABLE",
      source: "released-after-termination",
      releasedAt: record.agreementReleasedAt,
      previousDeployment: {
        pbxName: record.name || null,
        instanceId: record.instanceId || null,
        region: record.region || null,
        terminatedAt: record.agreementReleasedAt
      }
    };
  }'''
s=s.replace(usage_anchor,usage_new,1)

# Reconciliation can complete the release even if the UI was closed while AWS
# transitioned from shutting-down to terminated.
terminated_anchor='''      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", source: "ledger-reconciled" });'''
terminated_new='''      const releasedAt = record.releaseAgreementOnTermination ? (record.agreementReleasedAt || new Date().toISOString()) : record.agreementReleasedAt;
      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", agreementReleasedAt: releasedAt || null, source: "ledger-reconciled" });'''
if s.count(terminated_anchor)<1:
    raise SystemExit("PATCH ERROR: missing-instance reconciliation anchor missing")
s=s.replace(terminated_anchor,terminated_new)

refresh_anchor='''      instanceState: instance.State?.Name || record.instanceState || null,
      publicIpAddress: instance.PublicIpAddress || null,'''
refresh_new='''      instanceState: instance.State?.Name || record.instanceState || null,
      agreementReleasedAt: (record.releaseAgreementOnTermination && instance.State?.Name === "terminated")
        ? (record.agreementReleasedAt || new Date().toISOString())
        : (record.agreementReleasedAt || null),
      publicIpAddress: instance.PublicIpAddress || null,'''
if refresh_anchor not in s:
    raise SystemExit("PATCH ERROR: ledger refresh anchor missing")
s=s.replace(refresh_anchor,refresh_new,1)

# The live status poll is authoritative for completing the release.
monitor_upsert='''        if (ledgerRecord) {
          upsertMarketplaceDeployment({
            ...ledgerRecord,'''
if monitor_upsert not in s:
    raise SystemExit("PATCH ERROR: monitor ledger update anchor missing")
monitor_new='''        const agreementReleased = Boolean(
          ledgerRecord?.releaseAgreementOnTermination &&
          instance.State?.Name === "terminated"
        );
        const agreementReleasedAt = agreementReleased
          ? (ledgerRecord?.agreementReleasedAt || checkedAt)
          : (ledgerRecord?.agreementReleasedAt || null);

        if (ledgerRecord) {
          upsertMarketplaceDeployment({
            ...ledgerRecord,'''
s=s.replace(monitor_upsert,monitor_new,1)

monitor_fields='''            lastStatusCheckAt: checkedAt,
            source: "deployment-monitor"'''
monitor_fields_new='''            lastStatusCheckAt: checkedAt,
            agreementReleasedAt,
            source: agreementReleased ? "termination-confirmed" : "deployment-monitor"'''
if monitor_fields not in s:
    raise SystemExit("PATCH ERROR: monitor ledger fields anchor missing")
s=s.replace(monitor_fields,monitor_fields_new,1)

result_anchor='''          pbxApplicationReadiness: "NOT_CHECKED",
          changesMade: false'''
result_new='''          pbxApplicationReadiness: "NOT_CHECKED",
          terminationRequested: Boolean(ledgerRecord?.terminationRequestedAt),
          agreementReleasePending: Boolean(ledgerRecord?.releaseAgreementOnTermination && !agreementReleased),
          agreementReleased,
          agreementReleasedAt,
          changesMade: false'''
if result_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor result release anchor missing")
s=s.replace(result_anchor,result_new,1)

p.write_text(s)
PY

  echo "[2/9] Patch staged guided UI"
  python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'data-terminate-release="v0.14.9.70"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-terminate-release="v0.14.9.70"',1)

if '.danger-button{' not in s:
    css=r'''
.danger-button{width:auto;background:#b42318;color:#fff;border-color:#b42318}.danger-button:hover{background:#912018}.danger-button:disabled{opacity:.45}
.termination-box{margin-top:10px;border:1px solid #b42318;border-radius:10px;padding:10px;background:color-mix(in srgb,#b42318 8%,Canvas)}
.termination-warning{white-space:pre-wrap;word-break:break-word;font:11px/1.45 ui-monospace,SFMono-Regular,Consolas,monospace;margin-bottom:9px}
'''
    s=s.replace('</style>',css+'</style>',1)

html_anchor='''<button id="refreshMarketplaceMonitor" class="secondary" type="button">Refresh machine status</button><span id="marketplaceMonitorActivity" class="muted"></span></div><div class="deployment-monitor-note">'''
html_new='''<button id="refreshMarketplaceMonitor" class="secondary" type="button">Refresh machine status</button><button id="planMarketplaceTermination" class="danger-button" type="button">Terminate &amp; release</button><span id="marketplaceMonitorActivity" class="muted"></span></div><div id="marketplaceTerminationBox" class="termination-box hidden"><div id="marketplaceTerminationWarning" class="termination-warning"></div><label for="marketplaceTerminationApproval">Exact approval phrase</label><input id="marketplaceTerminationApproval" autocomplete="off" spellcheck="false"><div class="deployment-monitor-actions"><button id="applyMarketplaceTermination" class="danger-button" type="button">Permanently terminate instance</button><button id="cancelMarketplaceTermination" class="secondary" type="button">Cancel</button></div><div id="marketplaceTerminationMsg" class="msg"></div></div><div class="deployment-monitor-note">'''
if html_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor actions HTML anchor missing")
s=s.replace(html_anchor,html_new,1)

listener_anchor='''    $("refreshMarketplaceMonitor").addEventListener("click",()=>refreshMarketplaceDeploymentMonitor(true));'''
listener_new=listener_anchor+'''
    $("planMarketplaceTermination").addEventListener("click",planMarketplaceTermination);
    $("applyMarketplaceTermination").addEventListener("click",applyMarketplaceTermination);
    $("cancelMarketplaceTermination").addEventListener("click",cancelMarketplaceTermination);'''
if listener_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor listener anchor missing")
s=s.replace(listener_anchor,listener_new,1)

state_anchor='''  let marketplaceMonitoredDeployments=[];'''
if state_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor state anchor missing")
s=s.replace(state_anchor,state_anchor+'\n  let currentTerminationPlan=null;',1)

render_anchor='''    $("marketplaceMonitorBadge").textContent=error?"Error":state;'''
render_new=render_anchor+'''
    if($("planMarketplaceTermination")){
      $("planMarketplaceTermination").disabled=Boolean(error||["shutting-down","terminated"].includes(state));
      $("planMarketplaceTermination").textContent=state==="shutting-down"?"Termination pending":state==="terminated"?"Instance terminated":"Terminate & release";
    }'''
if render_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor render state anchor missing")
s=s.replace(render_anchor,render_new,1)

function_anchor='''  function stopMarketplaceDeploymentMonitor(clearDeployment=false){'''
if function_anchor not in s:
    raise SystemExit("PATCH ERROR: termination UI insertion anchor missing")
functions=r'''  function terminationToolError(result,fallback){
    if(!result?.isError) return "";
    return (typeof toolErrorText==="function"?toolErrorText(result):"")||fallback;
  }

  function cancelMarketplaceTermination(){
    currentTerminationPlan=null;
    if($("marketplaceTerminationApproval")) $("marketplaceTerminationApproval").value="";
    $("marketplaceTerminationBox")?.classList.add("hidden");
    if($("marketplaceTerminationMsg")) setMsg("marketplaceTerminationMsg","");
    reportSize();
  }

  async function planMarketplaceTermination(){
    const deployment=currentMonitoredDeployment;
    if(!deployment?.instanceId||!deployment?.region) return;
    try{
      $("planMarketplaceTermination").disabled=true;
      $("planMarketplaceTermination").textContent="Checking…";
      const raw=await callTool("aws_marketplace_plan_terminate_vodia_pbx",{
        customerId:customerId(),
        region:deployment.region,
        instanceId:deployment.instanceId
      });
      const error=terminationToolError(raw,"Termination preflight failed.");
      if(error) throw new Error(error);
      const plan=dataFrom(raw);
      if(!plan?.planId||!plan?.confirmation) throw new Error("Termination planner did not return an approval.");
      currentTerminationPlan=plan;
      const deleting=Array.isArray(plan.volumesDeletedOnTermination)?plan.volumesDeletedOnTermination:[];
      const preserved=Array.isArray(plan.volumesPreservedAfterTermination)?plan.volumesPreservedAfterTermination:[];
      $("marketplaceTerminationWarning").textContent=[
        "PERMANENT AND IRREVERSIBLE",
        "PBX: "+(plan.deployment?.name||deployment.pbxName||"Vodia PBX"),
        "Instance: "+deployment.instanceId,
        "Region: "+deployment.region,
        "Current state: "+(plan.deployment?.state||deployment.instanceState||"unknown"),
        "EBS volumes deleted on termination: "+(deleting.length?deleting.map(v=>v.volumeId||v.deviceName).join(", "):"none reported"),
        "EBS volumes preserved: "+(preserved.length?preserved.map(v=>v.volumeId||v.deviceName).join(", "):"none reported"),
        "The deployment slot is released only after AWS confirms TERMINATED.",
        "",
        "Required approval: "+plan.confirmation
      ].join("\n");
      $("marketplaceTerminationApproval").value="";
      $("marketplaceTerminationApproval").placeholder=plan.confirmation;
      $("marketplaceTerminationBox").classList.remove("hidden");
      setMsg("marketplaceTerminationMsg","Review the permanent data-loss warning, then enter the exact approval phrase.");
    }catch(e){
      currentTerminationPlan=null;
      $("marketplaceTerminationBox")?.classList.remove("hidden");
      $("marketplaceTerminationWarning").textContent="Termination preflight failed. No AWS resource was changed.";
      setMsg("marketplaceTerminationMsg",e.message||String(e));
    }finally{
      $("planMarketplaceTermination").disabled=false;
      $("planMarketplaceTermination").textContent="Terminate & release";
      reportSize();
    }
  }

  async function applyMarketplaceTermination(){
    if(!currentTerminationPlan?.planId) return;
    const confirmation=$("marketplaceTerminationApproval").value.trim();
    if(confirmation!==currentTerminationPlan.confirmation){
      setMsg("marketplaceTerminationMsg","Enter the exact approval phrase shown above.");
      return;
    }
    try{
      $("applyMarketplaceTermination").disabled=true;
      $("applyMarketplaceTermination").textContent="Terminating…";
      const raw=await callTool("aws_marketplace_apply_terminate_vodia_pbx",{
        planId:currentTerminationPlan.planId,
        confirmation
      });
      const error=terminationToolError(raw,"Termination request failed.");
      if(error) throw new Error(error);
      const result=dataFrom(raw);
      if(result.instanceId!==currentMonitoredDeployment?.instanceId){
        throw new Error("Termination result returned a different instance ID; refresh status immediately.");
      }
      currentMonitoredDeployment={...currentMonitoredDeployment,instanceState:result.state||"shutting-down"};
      currentTerminationPlan=null;
      $("marketplaceTerminationBox").classList.add("hidden");
      setMsg("marketplaceMsg","Termination requested. Monitoring AWS; the deployment slot remains locked until AWS confirms terminated.");
      renderMarketplaceDeploymentMonitor({...result,pbxName:currentMonitoredDeployment.pbxName});
      await refreshMarketplaceDeploymentMonitor(true);
    }catch(e){
      setMsg("marketplaceTerminationMsg",e.message||String(e));
    }finally{
      $("applyMarketplaceTermination").disabled=false;
      $("applyMarketplaceTermination").textContent="Permanently terminate instance";
      reportSize();
    }
  }

'''
s=s.replace(function_anchor,functions+function_anchor,1)

# When AWS confirms termination, refresh Marketplace usage so the released slot
# becomes AVAILABLE without requiring the customer to understand the ledger.
poll_anchor='''      renderMarketplaceDeploymentMonitor({...status,region:deployment.region});
      scheduleMarketplaceDeploymentMonitor(status.state,false);'''
poll_new='''      renderMarketplaceDeploymentMonitor({...status,region:deployment.region});
      if(status.agreementReleased){
        setMsg("marketplaceMsg","AWS confirmed the instance is terminated. The Vodia deployment slot has been released.");
        cancelMarketplaceTermination();
        await checkMarketplaceSubscription();
        return;
      }
      scheduleMarketplaceDeploymentMonitor(status.state,false);'''
if poll_anchor not in s:
    raise SystemExit("PATCH ERROR: monitor release refresh anchor missing")
s=s.replace(poll_anchor,poll_new,1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.70"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.28.0"}',s,count=1)
p.write_text(s)
PY

  python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.70/mcp-app.html',s,count=1)
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

echo "[3/9] Validate IAM assets"
python3 -m json.tool "$TMP/staged/deployment-role-policy.json" >/dev/null
grep -Fq 'ec2:TerminateInstances' "$TMP/staged/deployment-role-policy.json" || fail "terminate permission missing from role policy"
grep -Fq 'ec2:DescribeInstanceAttribute' "$TMP/staged/deployment-role-policy.json" || fail "termination-protection read missing from role policy"
grep -Fq 'ec2:TerminateInstances' "$TMP/staged/customer-access.yaml" || fail "terminate permission missing from CloudFormation"
grep -Fq 'ec2:DescribeInstanceAttribute' "$TMP/staged/customer-access.yaml" || fail "termination-protection read missing from CloudFormation"
echo "PASS: updated role policy and CloudFormation template include terminate + protection preflight permissions"

echo "[4/9] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_TERMINATE_RELEASE_V70' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "terminate-release marker missing"
grep -Fq 'aws_marketplace_plan_terminate_vodia_pbx' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "termination planner missing"
grep -Fq 'aws_marketplace_apply_terminate_vodia_pbx' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "termination apply missing"
grep -Fq 'DryRun:true' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "termination permission DryRun missing"
grep -Fq 'TERMINATION_PROTECTION_ENABLED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "termination protection guard missing"
grep -Fq 'TERMINATION_NOT_VODIA_MANAGED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "Vodia ownership guard missing"
grep -Fq 'releaseAgreementOnTermination:true' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deferred release marker missing"
grep -Fq 'released-after-termination' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "released slot state missing"
grep -Fq 'destructiveHint:true' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "destructive annotation missing"
grep -Fq 'VODIA_MARKETPLACE_MONITOR_V69' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment monitor regression"
grep -Fq 'VODIA_EC2_LAUNCH_VERIFY_V68' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "verified launch regression"
echo "PASS: plan/apply termination, exact approval, ownership, protection, volume impact, deferred release, and prior guards present"

echo "[5/9] Validate staged UI"
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
grep -Fq 'data-terminate-release="v0.14.9.70"' "$TMP/staged/msp-guided-app.html" || fail "UI release marker missing"
grep -Fq 'Terminate &amp; release' "$TMP/staged/msp-guided-app.html" || fail "termination action missing"
grep -Fq 'PERMANENT AND IRREVERSIBLE' "$TMP/staged/msp-guided-app.html" || fail "data-loss warning missing"
grep -Fq 'Exact approval phrase' "$TMP/staged/msp-guided-app.html" || fail "exact approval UI missing"
grep -Fq 'volumesDeletedOnTermination' "$TMP/staged/msp-guided-app.html" || fail "volume-impact display missing"
grep -Fq 'status.agreementReleased' "$TMP/staged/msp-guided-app.html" || fail "automatic release refresh missing"
grep -Fq 'uiVersion:"0.14.9.70"' "$TMP/staged/msp-guided-app.html" || fail "debug version missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.70/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "v0.14.9.70 UI URI missing"
echo "PASS: guarded termination UI, volume warning, exact approval, monitoring, and JavaScript syntax verified"

if [[ "$CURRENT" != "$TO_VER" ]]; then
  echo "[6/9] Backup"
  mkdir -p "$BACKUP_DIR"
  cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
  cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
  cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
  cp -a "$VERSION" "$BACKUP_DIR/version.js"
  [[ -f /var/lib/vodia-mcp/aws-marketplace-deployments.json ]] && cp -a /var/lib/vodia-mcp/aws-marketplace-deployments.json "$BACKUP_DIR/" || true
  echo "PASS: $BACKUP_DIR"

  rollback(){
    echo "ROLLBACK: restoring v0.14.9.69 service files"
    cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
    cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
    cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
    cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
    systemctl restart "$SERVICE" || true
  }
  trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

  echo "[7/9] Install + restart"
  mkdir -p "$AWS_DIR/cloudformation"
  install -o root -g root -m 0644 "$TMP/staged/deployment-role-policy.json" "$POLICY_TARGET"
  install -o root -g root -m 0644 "$TMP/staged/customer-access.yaml" "$CF_TARGET"
  install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
  install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
  install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
  install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
  systemctl restart "$SERVICE"
else
  echo "[6/9]-[7/9] Backup/install skipped"
fi

echo "[8/9] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.70"' <<<"$HEALTH" || fail "health does not report v0.14.9.70"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[9/9] Complete"
echo "PASS: Vodia MCP v0.14.9.70 installed and verified."
echo "PASS: only customer-owned ManagedBy=VodiaMCP instances can enter the termination workflow."
echo "PASS: termination requires read-only preflight, AWS DryRun permission, disabled termination protection, volume-impact review, and exact approval."
echo "PASS: the deployment slot remains locked while AWS is shutting down and becomes AVAILABLE only after terminated is confirmed."
echo "PASS: no EC2 instance was terminated by this installer."
echo "IAM POLICY FOR EXISTING CUSTOMER ROLE: $POLICY_TARGET"
echo "CLOUDFORMATION TEMPLATE FOR NEW/UPDATED CUSTOMERS: $CF_TARGET"
[[ -d "$BACKUP_DIR" ]] && echo "Backup: $BACKUP_DIR"
echo
echo "IMPORTANT: update the existing customer's VodiaMCPDeploymentRole policy before testing termination."
