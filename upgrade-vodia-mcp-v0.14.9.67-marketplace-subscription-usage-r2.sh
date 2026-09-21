#!/usr/bin/env bash
# Vodia MCP v0.14.9.67 — Marketplace subscription usage tracking
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.67"
LEDGER="${VODIA_MCP_MARKETPLACE_DEPLOYMENT_LEDGER:-/var/lib/vodia-mcp/aws-marketplace-deployments.json}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-subscription-usage-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.64|0.14.9.65|0.14.9.66) ;;
  0.14.9.67) echo "v0.14.9.67 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.64, .65, or .66; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Marketplace subscription usage tracking ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Persistent deployment ledger imports.
if 'from "node:fs"' not in s:
    anchor='import { randomUUID } from "node:crypto";'
    if anchor not in s: raise SystemExit("PATCH ERROR: crypto import anchor missing")
    s=s.replace(anchor,anchor+'\nimport { mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";\nimport { dirname } from "node:path";',1)

# Ledger path.
const_anchor='const AWS_DEPLOY_PLAN_TTL_MS ='
if 'VODIA_MARKETPLACE_DEPLOYMENT_LEDGER' not in s:
    i=s.find(const_anchor)
    if i<0: raise SystemExit("PATCH ERROR: const anchor missing")
    s=s[:i]+'const VODIA_MARKETPLACE_DEPLOYMENT_LEDGER = process.env.VODIA_MCP_MARKETPLACE_DEPLOYMENT_LEDGER || "/var/lib/vodia-mcp/aws-marketplace-deployments.json";\n'+s[i:]

# Add reconciliation helpers immediately before tool registration.
reg_anchor='export function registerAwsMarketplaceDeployTools(server, ctx) {'
if reg_anchor not in s: raise SystemExit("PATCH ERROR: tool registration anchor missing")
if 'async function reconcileMarketplaceAgreementUsage(' not in s:
    helpers=r'''
function instanceTagValue(instance, key) {
  return (instance?.Tags || []).find(t => t?.Key === key)?.Value || null;
}

function loadMarketplaceDeploymentLedger() {
  try {
    const parsed = JSON.parse(readFileSync(VODIA_MARKETPLACE_DEPLOYMENT_LEDGER, "utf8"));
    if (!parsed || typeof parsed !== "object") return { version: 1, deployments: [] };
    if (!Array.isArray(parsed.deployments)) parsed.deployments = [];
    return { version: 1, deployments: parsed.deployments };
  } catch (error) {
    if (error?.code === "ENOENT") return { version: 1, deployments: [] };
    throw new Error("MARKETPLACE_DEPLOYMENT_LEDGER_READ_FAILED: " + (error?.message || String(error)));
  }
}

function saveMarketplaceDeploymentLedger(ledger) {
  mkdirSync(dirname(VODIA_MARKETPLACE_DEPLOYMENT_LEDGER), { recursive: true, mode: 0o700 });
  const tmp = VODIA_MARKETPLACE_DEPLOYMENT_LEDGER + ".tmp";
  writeFileSync(tmp, JSON.stringify({ version: 1, deployments: ledger.deployments || [] }, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, VODIA_MARKETPLACE_DEPLOYMENT_LEDGER);
}

function upsertMarketplaceDeployment(record) {
  const ledger = loadMarketplaceDeploymentLedger();
  const now = new Date().toISOString();
  const key = record.instanceId
    ? (row => row.instanceId === record.instanceId)
    : (row => row.customerId === record.customerId && row.productId === record.productId && row.agreementId === record.agreementId);
  const index = ledger.deployments.findIndex(key);
  if (index >= 0) {
    ledger.deployments[index] = { ...ledger.deployments[index], ...record, updatedAt: now };
  } else {
    ledger.deployments.push({ ...record, createdAt: record.createdAt || now, updatedAt: now });
  }
  saveMarketplaceDeploymentLedger(ledger);
  return index >= 0 ? ledger.deployments[index] : ledger.deployments[ledger.deployments.length - 1];
}

function marketplaceUsageStatusForState(state) {
  const value = String(state || "").toLowerCase();
  if (["pending","running","stopping","shutting-down"].includes(value)) return "IN_USE";
  if (value === "stopped") return "INSTANCE_STOPPED";
  if (value === "terminated") return "INSTANCE_TERMINATED";
  return "RECONCILIATION_NEEDED";
}

function marketplaceUsageView(record, source) {
  if (!record) return { status: "AVAILABLE", source: source || "none" };
  return {
    status: marketplaceUsageStatusForState(record.instanceState),
    source: source || record.source || "ledger",
    pbxName: record.name || null,
    instanceId: record.instanceId || null,
    region: record.region || null,
    instanceState: record.instanceState || null,
    launchTime: record.launchTime || null,
    publicIpAddress: record.publicIpAddress || null,
    publicDnsName: record.publicDnsName || null,
    agreementId: record.agreementId || null
  };
}

async function refreshLedgerDeploymentStatus(roleArn, externalId, record) {
  if (!record?.region || !record?.instanceId) return marketplaceUsageView(record, "ledger");
  try {
    const client = ec2Client(roleArn, externalId, record.region);
    const out = await client.send(new DescribeInstancesCommand({ InstanceIds: [record.instanceId] }));
    const instance = out.Reservations?.[0]?.Instances?.[0];
    if (!instance) {
      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", source: "ledger-reconciled" });
      return marketplaceUsageView(updated, "ledger-reconciled");
    }
    const updated = upsertMarketplaceDeployment({
      ...record,
      name: instanceTagValue(instance, "Name") || record.name || null,
      instanceState: instance.State?.Name || record.instanceState || null,
      publicIpAddress: instance.PublicIpAddress || null,
      publicDnsName: instance.PublicDnsName || null,
      launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : record.launchTime || null,
      source: "ledger-reconciled"
    });
    return marketplaceUsageView(updated, "ledger-reconciled");
  } catch (error) {
    const msg = String(error?.message || error);
    if (/InvalidInstanceID\.NotFound|does not exist/i.test(msg)) {
      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", source: "ledger-reconciled" });
      return marketplaceUsageView(updated, "ledger-reconciled");
    }
    return { ...marketplaceUsageView(record, "ledger"), status: "RECONCILIATION_NEEDED", reconciliationError: msg };
  }
}

async function discoverAgreementDeployment(roleArn, externalId, customerId, productId, agreementId) {
  const discovery = ec2Client(roleArn, externalId, AWS_DISCOVERY_REGION);
  const regionsOut = await discovery.send(new DescribeRegionsCommand({ AllRegions: false }));
  const regions = (regionsOut.Regions || []).map(r => r.RegionName).filter(Boolean);

  const checks = await Promise.allSettled(regions.map(async region => {
    const client = ec2Client(roleArn, externalId, region);
    const out = await client.send(new DescribeInstancesCommand({
      Filters: [
        { Name: "tag:ManagedBy", Values: ["VodiaMCP"] },
        { Name: "tag:VodiaMarketplaceProductId", Values: [productId] },
        { Name: "tag:VodiaMarketplaceAgreementId", Values: [agreementId] }
      ]
    }));
    const instances = (out.Reservations || []).flatMap(r => r.Instances || []);
    instances.sort((a,b) => new Date(b.LaunchTime || 0) - new Date(a.LaunchTime || 0));
    return { region, instance: instances[0] || null };
  }));

  const matches = checks
    .filter(x => x.status === "fulfilled" && x.value?.instance)
    .map(x => x.value)
    .sort((a,b) => new Date(b.instance.LaunchTime || 0) - new Date(a.instance.LaunchTime || 0));

  if (!matches.length) return null;
  const { region, instance } = matches[0];
  return upsertMarketplaceDeployment({
    customerId: customerId || null,
    productId,
    agreementId,
    instanceId: instance.InstanceId,
    name: instanceTagValue(instance, "Name") || null,
    region,
    instanceState: instance.State?.Name || null,
    publicIpAddress: instance.PublicIpAddress || null,
    publicDnsName: instance.PublicDnsName || null,
    launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : null,
    source: "ec2-reconciled"
  });
}

async function reconcileMarketplaceAgreementUsage(roleArn, externalId, customerId, productId, agreementId) {
  const ledger = loadMarketplaceDeploymentLedger();
  const rows = ledger.deployments
    .filter(row =>
      row?.agreementId === agreementId &&
      row?.productId === productId &&
      (!customerId || !row.customerId || row.customerId === customerId)
    )
    .sort((a,b) => new Date(b.launchTime || b.createdAt || 0) - new Date(a.launchTime || a.createdAt || 0));

  if (rows[0]) return refreshLedgerDeploymentStatus(roleArn, externalId, rows[0]);

  const discovered = await discoverAgreementDeployment(roleArn, externalId, customerId, productId, agreementId);
  return discovered ? marketplaceUsageView(discovered, "ec2-reconciled") : { status: "AVAILABLE", source: "ec2-scan" };
}

async function enrichMarketplaceSubscriptionUsage(roleArn, externalId, customerId, productId, subscription) {
  const agreements = [];
  for (const agreement of subscription.agreements || []) {
    const agreementId = agreement?.agreementId;
    let deploymentUsage = { status: "RECONCILIATION_NEEDED", source: "invalid-agreement" };
    if (agreementId) {
      deploymentUsage = await reconcileMarketplaceAgreementUsage(roleArn, externalId, customerId, productId, agreementId);
    }
    agreements.push({ ...agreement, deploymentUsage });
  }
  const availableAgreementCount = agreements.filter(a => a.deploymentUsage?.status === "AVAILABLE").length;
  const inUseAgreementCount = agreements.length - availableAgreementCount;
  return { ...subscription, agreements, availableAgreementCount, inUseAgreementCount };
}

'''
    s=s.replace(reg_anchor,helpers+reg_anchor,1)

# Enrich the Marketplace subscription check with usage state.
old='''        const result = await checkSubscription(c.roleArn, c.externalId, productId);
        return scopedSuccess({ ...result, changesMade: false }, { operation: "AWS_MARKETPLACE_CHECK_SUBSCRIPTION", readOnly: true }, result.active ? "Active Marketplace agreement found." : "No active Marketplace agreement found.");'''
new='''        const result = await checkSubscription(c.roleArn, c.externalId, productId);
        const enriched = result.active
          ? await enrichMarketplaceSubscriptionUsage(c.roleArn, c.externalId, c.customerId || null, productId, result)
          : { ...result, agreements: [], availableAgreementCount: 0, inUseAgreementCount: 0 };
        const summary = enriched.active
          ? ("Active Marketplace agreement(s) found: " + enriched.availableAgreementCount + " available, " + enriched.inUseAgreementCount + " already assigned.")
          : "No active Marketplace agreement found.";
        return scopedSuccess({ ...enriched, changesMade: false }, { operation: "AWS_MARKETPLACE_CHECK_SUBSCRIPTION", readOnly: true }, summary);'''
if old not in s:
    raise SystemExit("PATCH ERROR: subscription check handler anchor missing")
s=s.replace(old,new,1)

# Hard backend guard: selected agreement must be AVAILABLE.
planner_anchor='''        input = { ...input, agreementId: selectedAgreement.agreementId };

        const client = ec2Client(input.roleArn, input.externalId, input.region);'''
planner_new='''        input = { ...input, agreementId: selectedAgreement.agreementId };

        const selectedUsage = await reconcileMarketplaceAgreementUsage(
          input.roleArn,
          input.externalId,
          input.customerId || null,
          input.productId,
          selectedAgreement.agreementId
        );
        if (selectedUsage.status !== "AVAILABLE") {
          throw new Error(
            "MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: agreement " + selectedAgreement.agreementId +
            " is " + selectedUsage.status +
            (selectedUsage.instanceId ? (" on instance " + selectedUsage.instanceId) : "") +
            (selectedUsage.pbxName ? (" (" + selectedUsage.pbxName + ")") : "") +
            ". Create or select another AVAILABLE Marketplace agreement."
          );
        }

        const client = ec2Client(input.roleArn, input.externalId, input.region);'''
if planner_anchor not in s:
    raise SystemExit("PATCH ERROR: planner agreement anchor missing")
s=s.replace(planner_anchor,planner_new,1)

# Record the deployment in the persistent ledger immediately after a verified EC2 launch.
launch_anchor='''          if (!instance?.InstanceId) throw new Error("EC2_LAUNCH_UNVERIFIED: RunInstances returned no instance ID.");

          deploymentPlans.delete(planId);'''
launch_new='''          if (!instance?.InstanceId) throw new Error("EC2_LAUNCH_UNVERIFIED: RunInstances returned no instance ID.");

          upsertMarketplaceDeployment({
            customerId: plan.customerId || null,
            productId: plan.productId,
            agreementId: plan.agreementId || null,
            instanceId: instance.InstanceId,
            name: plan.name,
            region: plan.region,
            instanceState: instance.State?.Name || "pending",
            publicIpAddress: instance.PublicIpAddress || null,
            publicDnsName: instance.PublicDnsName || null,
            launchTime: new Date().toISOString(),
            source: "mcp-launch"
          });

          deploymentPlans.delete(planId);'''
if launch_anchor not in s:
    raise SystemExit("PATCH ERROR: apply launch anchor missing")
s=s.replace(launch_anchor,launch_new,1)

p.write_text(s)
PY

echo "[2/8] Patch staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Replace the cumulative subscription renderer so used agreements remain visible but are not selectable.
start=s.find('  function renderMarketplaceSubscription(')
end=s.find('\n  async function checkMarketplaceSubscription(){',start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: renderMarketplaceSubscription boundaries missing")

render=r'''  function renderMarketplaceSubscription(active,message,subscription=null){
    currentMarketplaceSubscription=subscription||currentMarketplaceSubscription;
    const agreements=Array.isArray(currentMarketplaceSubscription?.agreements)
      ? currentMarketplaceSubscription.agreements : [];
    const availableAgreements=agreements.filter(a=>a?.deploymentUsage?.status==="AVAILABLE");
    marketplaceSubscriptionActive=Boolean(active && availableAgreements.length>0);

    const usedCount=agreements.length-availableAgreements.length;
    $("marketplaceBadge").textContent=!active?"Required":(availableAgreements.length?"Available":"In use");

    // Always allow another Marketplace purchase path when current agreements are already assigned.
    $("viewMarketplaceOffer").classList.remove("hidden");
    $("viewMarketplaceOffer").textContent=active?"Start another subscription":"View plans & subscribe";

    const pickerBox=$("marketplaceAgreementBox");
    const picker=$("marketplaceAgreementSelect");
    const previous=picker?.value||"";

    if(picker){
      picker.innerHTML="";
      agreements.forEach((agreement,index)=>{
        const op=document.createElement("option");
        const id=agreement?.agreementId||agreement?.id||"";
        const usage=agreement?.deploymentUsage||{status:"RECONCILIATION_NEEDED"};
        const available=usage.status==="AVAILABLE";
        op.value=id;
        op.disabled=!available;
        const awsStatus=agreement?.status||"ACTIVE";
        const usageText=usage.status||"UNKNOWN";
        const attached=[
          usage.pbxName||null,
          usage.instanceId||null,
          usage.region||null,
          usage.instanceState||null
        ].filter(Boolean).join(" · ");
        op.textContent="Subscription "+(index+1)+" · "+id+" · "+awsStatus+" · "+usageText+(attached?(" · "+attached):"");
        picker.appendChild(op);
      });

      if(previous && availableAgreements.some(a=>(a?.agreementId||a?.id)===previous)) picker.value=previous;
      else if(availableAgreements[0]) picker.value=availableAgreements[0].agreementId||availableAgreements[0].id||"";
      else picker.value="";
      picker.disabled=availableAgreements.length===0;
    }
    if(pickerBox) pickerBox.classList.toggle("hidden",!active||agreements.length===0);

    const summary=$("marketplaceSubscriptionSummary");
    if(active){
      $("marketplaceOfferBox").classList.add("hidden");
      $("marketplaceQuoteBox").classList.add("hidden");
      currentMarketplaceQuote=null;

      const selectedId=picker?.value||null;
      const lines=[
        "Vodia AWS Marketplace subscriptions",
        "AWS account: "+(currentAwsConnection?.account||"Unknown"),
        "Product: Vodia PBX",
        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "AWS status: ACTIVE",
        "Active agreement(s): "+agreements.length,
        "Available for deployment: "+availableAgreements.length,
        "Already assigned / used: "+usedCount,
        selectedId?("Selected AVAILABLE agreement: "+selectedId):"Selected agreement: none available"
      ];
      for(const agreement of agreements){
        const usage=agreement?.deploymentUsage||{};
        if(usage.status==="AVAILABLE") continue;
        lines.push("");
        lines.push("IN USE: "+(agreement.agreementId||agreement.id||"agreement"));
        if(usage.pbxName) lines.push("PBX: "+usage.pbxName);
        if(usage.instanceId) lines.push("Instance: "+usage.instanceId);
        if(usage.region) lines.push("Region: "+usage.region);
        if(usage.instanceState) lines.push("Instance state: "+usage.instanceState);
      }
      summary.textContent=lines.join("\n");
      summary.classList.remove("hidden");
    }else{
      summary.classList.add("hidden");
      if(pickerBox) pickerBox.classList.add("hidden");
    }

    setMsg("marketplaceMsg",message||(active
      ?(availableAgreements.length
        ?"Choose an AVAILABLE subscription for this deployment. Agreements already assigned to a PBX are locked."
        :"All active subscriptions are already assigned. Start another subscription before deploying another PBX.")
      :"No active Vodia agreement was found. Review the live AWS offer and subscribe before deployment."));

    if($("continueMarketplace")) $("continueMarketplace").disabled=!marketplaceSubscriptionActive;
    updatePlanButton();
    reportSize();
  }
'''
s=s[:start]+render+s[end:]

# Make the subscription checker pass its enriched response into the renderer.
# Scope this change to the checker and accept older/debugger builds with
# different whitespace, messages, or an already-present third argument.
check_start=s.find('  async function checkMarketplaceSubscription(){')
check_end=s.find('\n  async function ',check_start+5)
if check_start<0:
    raise SystemExit("PATCH ERROR: checkMarketplaceSubscription function missing")
if check_end<0:
    check_end=s.find('\n  function ',check_start+5)
if check_end<0:
    raise SystemExit("PATCH ERROR: checkMarketplaceSubscription boundary missing")
check=s[check_start:check_end]

call_pattern=re.compile(
    r'renderMarketplaceSubscription\(\s*Boolean\(r\.active\)(?:\s*,[^;]*)?\s*\);'
)
check,call_count=call_pattern.subn(
    'renderMarketplaceSubscription(Boolean(r.active),null,r);',check,count=1
)
if call_count!=1:
    raise SystemExit("PATCH ERROR: checkMarketplaceSubscription renderer call missing")

return_pattern=re.compile(r'return\s+Boolean\(r\.active(?:[^;]*)?\);')
check,return_count=return_pattern.subn(
    'return Boolean(r.active && (r.availableAgreementCount??0)>0);',check,count=1
)
if return_count==0:
    check=check.replace(
        'renderMarketplaceSubscription(Boolean(r.active),null,r);',
        'renderMarketplaceSubscription(Boolean(r.active),null,r);\n      return Boolean(r.active && (r.availableAgreementCount??0)>0);',
        1
    )
s=s[:check_start]+check+s[check_end:]

# Keep change listener on enriched current subscription.
if 'renderMarketplaceSubscription(marketplaceSubscriptionActive,null,currentMarketplaceSubscription);' in s:
    s=s.replace(
      'renderMarketplaceSubscription(marketplaceSubscriptionActive,null,currentMarketplaceSubscription);',
      'renderMarketplaceSubscription(Boolean(currentMarketplaceSubscription?.active),null,currentMarketplaceSubscription);'
    )

# Fix stale debug version markers and cache identity.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"', 'uiVersion:"0.14.9.67"', s)
if 'data-subscription-usage="v0.14.9.67"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-subscription-usage="v0.14.9.67"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.25.0"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.67/mcp-app.html',s,count=1)
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

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_MARKETPLACE_DEPLOYMENT_LEDGER' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "ledger path missing"
grep -Fq 'reconcileMarketplaceAgreementUsage' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement reconciliation missing"
grep -Fq 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend reuse guard missing"
grep -Fq 'VodiaMarketplaceAgreementId' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement EC2 tag regression"
grep -Fq 'upsertMarketplaceDeployment({' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment ledger write missing"
grep -Fq 'availableAgreementCount' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "subscription usage counts missing"
echo "PASS: persistent ledger + EC2 reconciliation + agreement reuse guard present"

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
grep -Fq 'Already assigned / used:' "$TMP/staged/msp-guided-app.html" || fail "usage summary missing"
grep -Fq 'op.disabled=!available' "$TMP/staged/msp-guided-app.html" || fail "used-agreement picker lock missing"
grep -Fq 'All active subscriptions are already assigned.' "$TMP/staged/msp-guided-app.html" || fail "all-used guidance missing"
grep -Fq 'uiVersion:"0.14.9.67"' "$TMP/staged/msp-guided-app.html" || fail "debug version marker missing"
echo "PASS: Marketplace UI shows AVAILABLE vs IN USE and locks used agreements"

echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f "$LEDGER" ]] && cp -a "$LEDGER" "$BACKUP_DIR/aws-marketplace-deployments.json" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring previous files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  if [[ -f "$BACKUP_DIR/aws-marketplace-deployments.json" ]]; then
    install -o root -g root -m 0600 "$BACKUP_DIR/aws-marketplace-deployments.json" "$LEDGER" || true
  fi
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/8] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
mkdir -p "$(dirname "$LEDGER")"
chmod 700 "$(dirname "$LEDGER")" 2>/dev/null || true
systemctl restart "$SERVICE"

echo "[7/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.67"' <<<"$HEALTH" || fail "health does not report v0.14.9.67"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.67 installed"
echo "PASS: Marketplace agreements are reconciled against a persistent Vodia deployment ledger and EC2 tags."
echo "PASS: Existing tagged deployments are discovered automatically, including deployments created before this version."
echo "PASS: ACTIVE + AVAILABLE agreements remain selectable."
echo "PASS: ACTIVE agreements already assigned to a PBX are shown as IN USE / STOPPED / TERMINATED and are not selectable."
echo "PASS: Backend blocks agreement reuse even if a client bypasses the UI."
echo "PASS: Successful new deployments are written to: $LEDGER"
echo "PASS: Debug trace version marker is now v0.14.9.67."
echo "Backup: $BACKUP_DIR"
echo
echo "NEXT TEST:"
echo "1. Open Vodia Setup in a fresh card."
echo "2. Choose Vodia Test Customer."
echo "3. Go to Marketplace."
echo "4. Click Check subscription."
echo "5. Any previously deployed agreement should show IN USE with its exact PBX name and EC2 instance ID."
echo "6. Continue to Configure EC2 should remain locked until another AVAILABLE agreement exists."
