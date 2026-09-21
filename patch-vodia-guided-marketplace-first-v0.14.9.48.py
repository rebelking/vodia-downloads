#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-vodia-guided-marketplace-first-v0.14.9.48.py UI_FILE")

p = Path(sys.argv[1])
s = p.read_text()
if 'data-marketplace-first="v0.14.9.48"' in s:
    raise SystemExit(0)

def once(old, new, label):
    global s
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"PATCH ERROR: {label} anchor count={count}")
    s = s.replace(old, new, 1)

once('<div class="card">', '<div class="card" data-marketplace-first="v0.14.9.48">', 'release marker')
s = s.replace('appInfo:{name:"vodia-setup",version:"1.9.0"}', 'appInfo:{name:"vodia-setup",version:"1.10.0"}', 1)
s = s.replace('appInfo:{name:"vodia-setup",version:"1.9.1"}', 'appInfo:{name:"vodia-setup",version:"1.10.0"}', 1)
once('.steps{display:grid;grid-template-columns:repeat(3,1fr);', '.steps{display:grid;grid-template-columns:repeat(5,1fr);', 'five-column steps')
once('''      <div class="steps" aria-label="Setup steps">
        <div class="step active">1 · Customer</div>
        <div class="step">2 · AWS</div>
        <div class="step">3 · Deploy</div>
      </div>''', '''      <div class="steps" aria-label="Setup steps">
        <div class="step active">1 · Customer</div>
        <div class="step">2 · Connect AWS</div>
        <div class="step">3 · Marketplace</div>
        <div class="step">4 · Configure EC2</div>
        <div class="step">5 · Review &amp; Deploy</div>
      </div>''', 'step labels')

once('''      </div>

      <div id="awsSection">''', '''        <div class="nav-actions">
          <span></span>
          <button id="continueCustomer" class="primary" type="button" disabled>Next: Connect AWS →</button>
        </div>
      </div>

      <div id="awsSection" class="panel step-panel hidden">''', 'customer-to-aws boundary')

once('''        <div id="awsContinueRow" class="actions hidden">
          <button id="continueAws" class="primary" type="button">Next: Choose AWS Region →</button>
        </div>''', '''        <div id="awsContinueRow" class="nav-actions hidden">
          <button id="backToCustomerFromConnect" class="secondary" type="button">Back</button>
          <button id="continueAws" class="primary" type="button">Next: Vodia Marketplace →</button>
        </div>''', 'AWS connection navigation')

market_start = s.find('        <div id="marketplaceBox" class="guided-box">')
market_end = s.find('        <div id="deployMsg" class="msg"></div>', market_start)
if market_start < 0 or market_end < 0:
    raise SystemExit('PATCH ERROR: Marketplace block boundaries not found')
marketplace = s[market_start:market_end]
s = s[:market_start] + s[market_end:]

market_panel = '''      <div id="marketplaceStepPanel" class="panel step-panel hidden">
        <h2>3 · Vodia AWS Marketplace</h2>
        <p>Choose and activate the Vodia subscription before configuring an EC2 machine. No EC2 instance is created in this step.</p>
''' + marketplace + '''        <div class="nav-actions">
          <button id="backToAwsConnect" class="secondary" type="button">Back</button>
          <button id="continueMarketplace" class="primary" type="button" disabled>Next: Configure EC2 →</button>
        </div>
      </div>

'''
once('      <div id="awsStepPanel" class="panel step-panel hidden">', market_panel + '      <div id="awsStepPanel" class="panel step-panel hidden">', 'Marketplace panel insertion')

deploy_start = s.find('      <div id="deployStepPanel" class="panel step-panel hidden">')
config_start = s.find('        <div class="twocol">', deploy_start)
config_end = s.find('        <div id="deployMsg" class="msg"></div>', config_start)
if deploy_start < 0 or config_start < 0 or config_end < 0:
    raise SystemExit('PATCH ERROR: EC2 configuration boundaries not found')
configuration = s[config_start:config_end]
configuration = configuration.replace(
    '        <button id="loadNetwork" class="secondary" type="button">Load AWS network</button>\n',
    '        <button id="loadNetwork" class="secondary" type="button">Load AWS network</button>\n        <div id="configureMsg" class="msg"></div>\n',
    1
)
s = s[:config_start] + s[config_end:]

once('''      <div id="awsStepPanel" class="panel step-panel hidden">
        <h2>2 · AWS</h2>
        <p id="awsStepSummary">AWS connection verified. Choose the deployment region.</p>''', '''      <div id="awsStepPanel" class="panel step-panel hidden">
        <h2>4 · Configure EC2</h2>
        <p id="awsStepSummary">The Vodia Marketplace subscription is active. Choose the EC2 region and machine settings.</p>''', 'EC2 heading')

old_region_nav = '''        <div class="nav-actions">
          <button id="backToCustomer" class="secondary" type="button">Back</button>
          <button id="continueDeploy" class="primary" type="button" disabled>Continue to Deploy</button>
        </div>
      </div>'''
new_region_nav = configuration + '''        <div class="nav-actions">
          <button id="backToCustomer" class="secondary" type="button">Back</button>
          <button id="continueDeploy" class="primary" type="button" disabled>Next: Review &amp; Deploy →</button>
        </div>
      </div>'''
once(old_region_nav, new_region_nav, 'EC2 navigation and fields')

once('''      <div id="deployStepPanel" class="panel step-panel hidden">
        <h2>3 · Deploy</h2>
        <p id="deployStepSummary">Choose the PBX and AWS network settings, validate the Marketplace subscription, and create a no-change deployment plan.</p>''', '''      <div id="deployStepPanel" class="panel step-panel hidden">
        <h2>5 · Review &amp; Deploy</h2>
        <p id="deployStepSummary">Review the subscribed Vodia deployment, validate it with AWS DryRun, and approve the launch.</p>''', 'review heading')

set_start = s.find('  function setStep(step){')
set_end = s.find('\n  function renderAwsConnection(', set_start)
if set_start < 0 or set_end < 0:
    raise SystemExit('PATCH ERROR: setStep boundaries not found')
new_set = '''  function setStep(step){
    currentStep=step;
    document.querySelectorAll(".step").forEach((el,index)=>{
      el.classList.toggle("active",index===step-1);
    });
    const views={
      customerPanel:step===1,
      awsSection:step===2,
      marketplaceStepPanel:step===3,
      awsStepPanel:step===4,
      deployStepPanel:step===5
    };
    Object.entries(views).forEach(([id,visible])=>{
      const el=$(id);
      if(!el) throw new Error("Setup view is missing: "+id);
      el.hidden=!visible;
      el.classList.toggle("hidden",!visible);
      el.setAttribute("aria-hidden",visible?"false":"true");
    });
    requestAnimationFrame(()=>{
      const targets=[$("customerPanel"),$("awsSection"),$("marketplaceStepPanel"),$("awsStepPanel"),$("deployStepPanel")];
      const target=targets[step-1];
      $("setupScroll").scrollTo({top:0,left:0,behavior:"auto"});
      target?.scrollIntoView({block:"nearest",behavior:"auto"});
      reportSize();
    });
  }
'''
s = s[:set_start] + new_set + s[set_end:]

once('  function onCustomerChanged(){ resetAws(); }', '  function onCustomerChanged(){ resetAws(); $("continueCustomer").disabled=!customerId(); }', 'customer navigation state')
once('''  function renderMarketplaceSubscription(active,message){
    marketplaceSubscriptionActive=Boolean(active);''', '''  function renderMarketplaceSubscription(active,message){
    marketplaceSubscriptionActive=Boolean(active);
    $("continueMarketplace").disabled=!marketplaceSubscriptionActive;''', 'Marketplace navigation state')

advance_anchor = '  async function advanceToAwsStep(){\n'
if s.count(advance_anchor) != 1:
    raise SystemExit('PATCH ERROR: advanceToAwsStep anchor missing')
market_advance = '''  async function advanceToMarketplaceStep(){
    if(!currentAwsConnection?.configured) return;
    setStep(3);
    const active=await checkMarketplaceSubscription();
    if(!active && !currentMarketplaceOffer) await loadMarketplaceOffer();
  }

'''
s = s.replace(advance_anchor, market_advance + advance_anchor, 1)
s = s.replace('    setStep(2);\n    $("awsStepSummary").textContent="AWS account "+(currentAwsConnection.account||"")+" is connected. Choose the deployment region.";', '    setStep(4);\n    $("awsStepSummary").textContent="Vodia Marketplace subscription active for AWS account "+(currentAwsConnection.account||"")+". Choose the EC2 region and machine settings.";', 1)

once('''  $("continueAws").addEventListener("click",advanceToAwsStep);
  $("loadRegions").addEventListener("click",loadDeploymentRegions);''', '''  $("continueCustomer").addEventListener("click",()=>{ if(customerId()) setStep(2); });
  $("backToCustomerFromConnect").addEventListener("click",()=>setStep(1));
  $("continueAws").addEventListener("click",advanceToMarketplaceStep);
  $("backToAwsConnect").addEventListener("click",()=>setStep(2));
  $("continueMarketplace").addEventListener("click",advanceToAwsStep);
  $("loadRegions").addEventListener("click",loadDeploymentRegions);''', 'step navigation handlers')

once('''  $("regionSelect").addEventListener("change",()=>{
    selectedRegion=$("regionSelect").value;
    $("continueDeploy").disabled=!selectedRegion;
    currentNetwork=null;
    currentDeploymentPlan=null;
    reportSize();
  });

  $("backToCustomer").addEventListener("click",()=>setStep(1));

  $("continueDeploy").addEventListener("click",()=>{
    selectedRegion=$("regionSelect").value;
    if(!selectedRegion) return;
    $("deployStepSummary").textContent="AWS account "+(currentAwsConnection?.account||"")+" · "+selectedRegion+". Load the network, review the settings, then create a no-change deployment plan.";
    setStep(3);
    $("loadNetwork").click();
    checkMarketplaceSubscription();
  });

  $("backToAws").addEventListener("click",()=>setStep(2));''', '''  $("regionSelect").addEventListener("change",()=>{
    selectedRegion=$("regionSelect").value;
    $("continueDeploy").disabled=true;
    currentNetwork=null;
    currentDeploymentPlan=null;
    reportSize();
  });

  $("backToCustomer").addEventListener("click",()=>setStep(3));

  $("continueDeploy").addEventListener("click",()=>{
    selectedRegion=$("regionSelect").value;
    if(!selectedRegion || !currentNetwork || !marketplaceSubscriptionActive) return;
    $("deployStepSummary").textContent="Vodia subscription active · AWS account "+(currentAwsConnection?.account||"")+" · "+selectedRegion+" · "+$("instanceType").value+". Validate the no-change plan before approving launch.";
    setStep(5);
  });

  $("backToAws").addEventListener("click",()=>setStep(4));''', 'EC2 and review navigation handlers')

once('''      currentNetwork=r;
      updatePlanButton();''', '''      currentNetwork=r;
      $("continueDeploy").disabled=false;
      updatePlanButton();''', 'network unlock')
once('''    }catch(e){
      currentNetwork=null;
      updatePlanButton();
      setMsg("deployMsg",e.message);
    }finally{
      $("loadNetwork").disabled=false;''', '''    }catch(e){
      currentNetwork=null;
      updatePlanButton();
      $("continueDeploy").disabled=true;
      setMsg("deployMsg",e.message);
    }finally{
      $("loadNetwork").disabled=false;''', 'network error lock')

load_start = s.find('  $("loadNetwork").addEventListener("click",async()=>{')
load_end = s.find('\n  $("planDeployment").addEventListener("click",async()=>{', load_start)
if load_start < 0 or load_end < 0:
    raise SystemExit('PATCH ERROR: loadNetwork handler boundaries not found')
load_handler = s[load_start:load_end].replace('setMsg("deployMsg"', 'setMsg("configureMsg"')
s = s[:load_start] + load_handler + s[load_end:]
s = s.replace(
    '        renderMarketplaceSubscription(false);\n        $("viewMarketplaceOffer").focus();',
    '        renderMarketplaceSubscription(false);\n        setStep(3);\n        $("viewMarketplaceOffer").focus();',
    1
)

p.write_text(s)
