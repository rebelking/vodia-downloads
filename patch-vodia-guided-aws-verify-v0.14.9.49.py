#!/usr/bin/env python3
from pathlib import Path
import re,sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-vodia-guided-aws-verify-v0.14.9.49.py UI_FILE")
p=Path(sys.argv[1]); s=p.read_text()
if 'data-aws-verify-feedback="v0.14.9.49"' in s:
    raise SystemExit(0)

marker='<div class="card" data-marketplace-first="v0.14.9.48">'
if marker not in s:
    raise SystemExit('PATCH ERROR: v0.14.9.48 Marketplace-first UI marker missing')
s=s.replace(marker,'<div class="card" data-marketplace-first="v0.14.9.48" data-aws-verify-feedback="v0.14.9.49">',1)
s,n=re.subn(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.13.0"}',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: UI app version anchor missing')

button='''            <button id="verifyHostedAws" class="primary" type="button">Verify &amp; Connect</button>'''
replacement='''            <div id="awsVerifyStatus" class="msg" role="status" aria-live="polite"></div>
            <button id="verifyHostedAws" class="primary" type="button">Verify &amp; Connect</button>'''
if s.count(button)!=1: raise SystemExit(f'PATCH ERROR: verify button anchor count={s.count(button)}')
s=s.replace(button,replacement,1)

start=s.find('  $("verifyHostedAws").addEventListener("click",async()=>{')
end=s.find('\n  $("cancelAws").addEventListener("click",()=>{',start)
if start<0 or end<0: raise SystemExit('PATCH ERROR: verify handler boundaries missing')
handler='''  function setAwsVerifyStatus(text,state="working"){
    const el=$("awsVerifyStatus");
    el.textContent=text||"";
    el.dataset.state=state;
    setMsg("awsHostedMsg",text||"");
    reportSize();
  }

  $("verifyHostedAws").addEventListener("click",async()=>{
    const id=customerId();
    const accountId=$("awsAccountId").value.trim();
    if(!id){
      setAwsVerifyStatus("Select the customer again before verifying AWS.","error");
      return;
    }
    if(!/^\\d{12}$/.test(accountId)){
      setAwsVerifyStatus("Enter the 12-digit AwsAccountId from the CloudFormation stack Outputs.","error");
      return;
    }
    try{
      $("verifyHostedAws").disabled=true;
      $("verifyHostedAws").textContent="Verifying…";
      setAwsVerifyStatus("Step 1 of 2: testing STS AssumeRole for AWS account "+accountId+"…");
      await callTool("msp_complete_customer_aws_onboarding",{customerId:id,accountId});
      setAwsVerifyStatus("Step 2 of 2: confirming the saved customer AWS connection…");
      const verified=dataFrom(await callTool("msp_get_customer_aws_connection",{customerId:id}));
      const connection=verified.connection||null;
      if(!connection?.configured) throw new Error("AWS connection did not verify after setup.");
      if(connection.account && String(connection.account)!==accountId){
        throw new Error("AWS account mismatch: expected "+accountId+" but STS returned "+connection.account+".");
      }
      setAwsVerifyStatus("Connected successfully to AWS account "+(connection.account||accountId)+".","success");
      renderAwsConnection(connection);
      setMsg("awsMsg","AWS account "+(connection.account||accountId)+" is connected and verified with STS.");
      await advanceToMarketplaceStep();
    }catch(e){
      const message=e?.message||String(e);
      setAwsVerifyStatus("AWS connection failed: "+message,"error");
      setMsg("awsMsg","AWS connection was not verified. See the result below.");
      $("awsHostedSetup").classList.remove("hidden");
    }finally{
      $("verifyHostedAws").disabled=false;
      $("verifyHostedAws").textContent="Verify & Connect";
      $("awsVerifyStatus")?.scrollIntoView({block:"nearest",behavior:"smooth"});
      reportSize();
    }
  });
'''
s=s[:start]+handler+s[end:]
p.write_text(s)
