#!/usr/bin/env bash
# Vodia MCP v0.14.9.61 — consolidated 4-step guided setup UI
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.61"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-consolidated-ui-$STAMP"
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
  0.14.9.60) ;;
  0.14.9.61) echo "v0.14.9.61 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.60; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — consolidated guided UI ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Consolidate staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Four clear product steps. Customer includes AWS connection because the connection
# belongs to the selected customer.
steps=re.compile(r'<div class="steps" aria-label="Setup steps">.*?</div>\s*\n',re.S)
new_steps='''<div class="steps" aria-label="Setup steps">
        <div class="step active">1 · Customer</div>
        <div class="step">2 · Marketplace</div>
        <div class="step">3 · Configure EC2</div>
        <div class="step">4 · Review &amp; Deploy</div>
      </div>
'''
s,n=steps.subn(new_steps,s,count=1)
if n!=1: raise SystemExit("PATCH ERROR: setup steps block missing")
s=s.replace('grid-template-columns:repeat(3,1fr)','grid-template-columns:repeat(4,1fr)',1)

# Add dedicated Marketplace and Review panels. Existing live controls are moved
# into these mounts at runtime, preserving all existing event listeners/tool calls.
if 'id="marketplaceStepPanel"' not in s:
    anchor='<div id="awsStepPanel" class="panel step-panel hidden">'
    if anchor not in s: raise SystemExit("PATCH ERROR: awsStepPanel anchor missing")
    panel='''<div id="marketplaceStepPanel" class="panel step-panel hidden">
        <h2>2 · Marketplace</h2>
        <p>Choose an active Vodia AWS Marketplace subscription or start another subscription.</p>
        <div id="marketplaceMount"></div>
        <div class="nav-actions">
          <button id="backMarketplaceToCustomer" class="secondary" type="button">Back</button>
          <button id="continueMarketplace" class="primary" type="button" disabled>Continue to Configure EC2</button>
        </div>
      </div>

      '''
    s=s.replace(anchor,panel+anchor,1)

if 'id="reviewStepPanel"' not in s:
    anchor='''      <div class="actions">
        <button id="refresh" class="secondary" type="button">Refresh</button>
      </div>'''
    if anchor not in s: raise SystemExit("PATCH ERROR: refresh actions anchor missing")
    panel='''      <div id="reviewStepPanel" class="panel step-panel hidden">
        <h2>4 · Review &amp; Deploy</h2>
        <p>Review the validated deployment plan, enter the exact approval, then launch.</p>
        <div id="reviewMount"></div>
        <div class="nav-actions">
          <button id="backToConfigure" class="secondary" type="button">Back to Configure EC2</button>
        </div>
      </div>

'''
    s=s.replace(anchor,panel+anchor,1)

# Add a tiny bit of consolidated-layout styling.
if '.ec2-config-grid{' not in s:
    css='''.ec2-config-grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin-top:10px}
.ec2-config-grid>.field{margin-bottom:0}
.review-mount .guided-box{margin-top:10px}
@media(max-width:600px){.ec2-config-grid{grid-template-columns:1fr}}
'''
    s=s.replace('</style>',css+'</style>',1)

# Add runtime DOM consolidation helper before setStep.
setstep_idx=s.find('  function setStep(step){')
if setstep_idx<0: raise SystemExit("PATCH ERROR: setStep function missing")
if 'function consolidateGuidedLayout(){' not in s:
    helper=r'''  function consolidateGuidedLayout(){
    const marketMount=$("marketplaceMount");
    const market=$("marketplaceBox");
    if(marketMount && market && market.parentElement!==marketMount){
      marketMount.appendChild(market);
    }

    const configure=$("awsStepPanel");
    if(configure){
      const h=configure.querySelector("h2");
      if(h) h.textContent="3 · Configure EC2";
      if($("awsStepSummary")) $("awsStepSummary").textContent=
        "Choose the AWS region, then name the PBX and configure its EC2 settings.";

      let grid=$("ec2ConfigGrid");
      if(!grid){
        grid=document.createElement("div");
        grid.id="ec2ConfigGrid";
        grid.className="ec2-config-grid";
        const regionMsg=$("regionMsg");
        regionMsg?.insertAdjacentElement("afterend",grid);
      }
      ["pbxName","instanceType","vpcSelect","subnetSelect","securityGroupSelect","keyPairSelect","storageGiB"].forEach(id=>{
        const el=$(id);
        const field=el?.closest(".field");
        if(field && field.parentElement!==grid) grid.appendChild(field);
      });
      const load=$("loadNetwork");
      if(load && load.parentElement!==configure) configure.appendChild(load);
      const plan=$("planDeployment");
      if(plan && plan.parentElement!==configure){
        const actions=document.createElement("div");
        actions.className="nav-actions";
        actions.id="configurePlanActions";
        const back=document.createElement("button");
        back.id="configureBackToMarketplace";
        back.className="secondary";
        back.type="button";
        back.textContent="Back";
        back.addEventListener("click",()=>setStep(2));
        actions.appendChild(back);
        actions.appendChild(plan);
        configure.appendChild(actions);
      }
      const oldBack=$("backToCustomer");
      if(oldBack) oldBack.textContent="Back to Marketplace";
      const cont=$("continueDeploy");
      if(cont) cont.textContent="Load EC2 options";
    }

    const review=$("reviewMount");
    if(review){
      review.classList.add("review-mount");
      ["deployMsg","planSummary","approvalBox"].forEach(id=>{
        const el=$(id);
        if(el && el.parentElement!==review) review.appendChild(el);
      });
    }

    const old=$("deployStepPanel");
    if(old){
      old.hidden=true;
      old.classList.add("hidden");
      old.setAttribute("aria-hidden","true");
    }
    reportSize();
  }

'''
    s=s[:setstep_idx]+helper+s[setstep_idx:]

# Replace the old 3-step router with the consolidated 4-step router.
start=s.find('  function setStep(step){')
end=s.find('\n  function renderAwsConnection(',start)
if start<0 or end<0: raise SystemExit("PATCH ERROR: setStep boundaries missing")
new_set=r'''  function setStep(step){
    currentStep=step;
    document.querySelectorAll(".step").forEach((el,index)=>{
      el.classList.toggle("active",index===step-1);
    });
    const views={
      customerPanel:step===1,
      awsSection:step===1,
      marketplaceStepPanel:step===2,
      awsStepPanel:step===3,
      reviewStepPanel:step===4
    };
    Object.entries(views).forEach(([id,visible])=>{
      const el=$(id);
      if(!el) throw new Error("Setup view is missing: "+id);
      el.hidden=!visible;
      el.classList.toggle("hidden",!visible);
      el.setAttribute("aria-hidden",visible?"false":"true");
    });
    const old=$("deployStepPanel");
    if(old){old.hidden=true;old.classList.add("hidden");old.setAttribute("aria-hidden","true");}
    requestAnimationFrame(()=>{
      const target=step===1?$("customerPanel")
        :step===2?$("marketplaceStepPanel")
        :step===3?$("awsStepPanel")
        :$("reviewStepPanel");
      $("setupScroll").scrollTo({top:0,left:0,behavior:"auto"});
      target?.scrollIntoView({block:"nearest",behavior:"auto"});
      reportSize();
    });
  }
'''
s=s[:start]+new_set+s[end:]

# Customer/AWS connection now advances to Marketplace, not straight to region.
start=s.find('  async function advanceToAwsStep(){')
end=s.find('\n  async function loadDeploymentRegions(){',start)
if start<0 or end<0: raise SystemExit("PATCH ERROR: advanceToAwsStep boundaries missing")
advance=r'''  async function advanceToAwsStep(){
    if(!currentAwsConnection?.configured) return;
    setStep(2);
    await checkMarketplaceSubscription();
  }
'''
s=s[:start]+advance+s[end:]

# Existing configure "Back" returns to Marketplace.
s=s.replace(
  '$("backToCustomer").addEventListener("click",()=>setStep(1));',
  '$("backToCustomer").addEventListener("click",()=>setStep(2));'
)

# Region continue now loads EC2 options in-place instead of navigating to the old Deploy panel.
old=r'''  $("continueDeploy").addEventListener("click",()=>{
    selectedRegion=$("regionSelect").value;
    if(!selectedRegion) return;
    $("deployStepSummary").textContent="AWS account "+(currentAwsConnection?.account||"")+" · "+selectedRegion+". Load the network, review the settings, then create a no-change deployment plan.";
    setStep(3);
    $("loadNetwork").click();
    checkMarketplaceSubscription();
  });'''
new=r'''  $("continueDeploy").addEventListener("click",()=>{
    selectedRegion=$("regionSelect").value;
    if(!selectedRegion) return;
    setStep(3);
    $("loadNetwork").click();
  });'''
if old in s:
    s=s.replace(old,new,1)
elif '$("loadNetwork").click();' not in s:
    raise SystemExit("PATCH ERROR: continueDeploy handler anchor missing")

# Add Marketplace navigation listeners.
anchor='''  $("continueAws").addEventListener("click",advanceToAwsStep);'''
extra=r'''  $("backMarketplaceToCustomer").addEventListener("click",()=>setStep(1));
  $("continueMarketplace").addEventListener("click",async()=>{
    if(!marketplaceSubscriptionActive) return;
    setStep(3);
    await loadDeploymentRegions();
  });
  $("backToConfigure").addEventListener("click",()=>setStep(3));
'''
if extra.strip() not in s:
    if anchor not in s: raise SystemExit("PATCH ERROR: continueAws listener anchor missing")
    s=s.replace(anchor,anchor+'\n'+extra,1)

# After a newly accepted subscription, go to Configure EC2 and ask for the PBX name.
needle='''  function promptForPbxDeploymentName(agreementId){'''
if needle in s and 'promptForPbxDeploymentName(agreementId){\n    setStep(3);' not in s:
    s=s.replace(needle,needle+'\n    setStep(3);\n    loadDeploymentRegions().catch(e=>setMsg("regionMsg",e.message));',1)

# When planning succeeds, show the dedicated Review & Deploy step.
success='''      setMsg("deployMsg","DryRun passed. Review the plan and enter the exact approval to launch EC2.");'''
if success in s and 'setStep(4);' not in s[s.find(success)-200:s.find(success)+300]:
    s=s.replace(success,success+'\n      setStep(4);',1)

# Surface MCP tool errors before dataFrom masks them.
if 'function toolErrorText(result){' not in s:
    anchor='''  function dataFrom(result){'''
    helper=r'''  function toolErrorText(result){
    if(!result) return "";
    const text=(result.content||[]).filter(x=>x?.type==="text"&&x?.text).map(x=>x.text).join("\n").trim();
    if(text) return text;
    const sc=result.structuredContent;
    const candidate=sc?.error?.message||sc?.error||sc?.message||sc?.data?.error||sc?.result?.error;
    if(candidate) return typeof candidate==="string"?candidate:JSON.stringify(candidate);
    return "";
  }

'''
    if anchor not in s: raise SystemExit("PATCH ERROR: dataFrom anchor missing")
    s=s.replace(anchor,helper+anchor,1)

old='''      const plan=dataFrom(await callTool("aws_marketplace_plan_vodia_pbx_deployment",{'''
new='''      const rawPlanResult=await callTool("aws_marketplace_plan_vodia_pbx_deployment",{'''
if old in s:
    s=s.replace(old,new,1)
    # close the tool call: locate first occurrence after raw call of '}));\n      if(!plan.planId'
    marker='''        name
      }));
      if(!plan.planId||!plan.confirmation){'''
    repl='''        name
      });
      if(rawPlanResult?.isError){
        throw new Error(toolErrorText(rawPlanResult)||"Deployment planner failed.");
      }
      const plan=dataFrom(rawPlanResult);
      if(!plan.planId||!plan.confirmation){'''
    if marker not in s: raise SystemExit("PATCH ERROR: planner call close anchor missing")
    s=s.replace(marker,repl,1)

# Start with consolidated DOM before initial refresh can auto-advance.
init='''  (async()=>{
    try{'''
if init not in s: raise SystemExit("PATCH ERROR: initial async anchor missing")
s=s.replace(init,'''  consolidateGuidedLayout();

  (async()=>{
    try{''',1)

# Product copy + marker/version.
s=s.replace('Only required information is shown. IDs stay in the background.',
            'Choose the customer, Marketplace subscription, EC2 configuration, then review and deploy.')
if 'data-consolidated-ui="v0.14.9.61"' not in s:
    s=s.replace('data-subscription-first-name="v0.14.9.60"',
                'data-subscription-first-name="v0.14.9.60" data-consolidated-ui="v0.14.9.61"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.21.0"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.61/mcp-app.html',s,count=1)
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

echo "[2/7] Validate consolidated inline JavaScript"
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

echo "[3/7] Validate consolidated workflow markers"
grep -Fq '2 · Marketplace' "$TMP/staged/msp-guided-app.html" || fail "Marketplace step missing"
grep -Fq '3 · Configure EC2' "$TMP/staged/msp-guided-app.html" || fail "Configure EC2 step missing"
grep -Fq '4 · Review &amp; Deploy' "$TMP/staged/msp-guided-app.html" || fail "Review step missing"
grep -Fq 'function consolidateGuidedLayout(){' "$TMP/staged/msp-guided-app.html" || fail "layout consolidator missing"
grep -Fq 'marketplaceStepPanel:step===2' "$TMP/staged/msp-guided-app.html" || fail "4-step router missing"
grep -Fq 'reviewStepPanel:step===4' "$TMP/staged/msp-guided-app.html" || fail "review router missing"
grep -Fq 'function toolErrorText(result){' "$TMP/staged/msp-guided-app.html" || fail "backend error surfacing missing"
grep -Fq 'rawPlanResult?.isError' "$TMP/staged/msp-guided-app.html" || fail "planner error propagation missing"
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling regression"
grep -Fq 'id="marketplaceAgreementSelect"' "$TMP/staged/msp-guided-app.html" || fail "subscription picker regression"
grep -Fq 'placeholder="Enter a unique PBX deployment name"' "$TMP/staged/msp-guided-app.html" || fail "PBX naming regression"
echo "PASS: consolidated four-step workflow present"

echo "[4/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f "$APP/aws-marketplace-ec2-deploy-v1.js" ]] && cp -a "$APP/aws-marketplace-ec2-deploy-v1.js" "$BACKUP_DIR/" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.key ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.key "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.60 UI files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[5/7] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[6/7] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.61"' <<<"$HEALTH" || fail "health does not report v0.14.9.61"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.61 installed"
echo "PASS: Live Vodia Setup now uses Customer -> Marketplace -> Configure EC2 -> Review & Deploy."
echo "PASS: Existing Marketplace, AWS, deployment, duplicate guard, and status polling controls are preserved."
echo "PASS: PBX naming remains separate from Marketplace subscriptions."
echo "PASS: MCP planner errors are surfaced instead of being hidden behind the generic approval message."
echo "NOTE: No AWS infrastructure or Marketplace agreement is changed by this installer."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.61 UI resource."
