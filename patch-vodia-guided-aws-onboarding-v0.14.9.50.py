#!/usr/bin/env python3
from pathlib import Path
import re, sys

if len(sys.argv) != 3:
    raise SystemExit("usage: patch-vodia-guided-aws-onboarding-v0.14.9.50.py BACKEND UI")

backend = Path(sys.argv[1])
ui = Path(sys.argv[2])
b = backend.read_text()
s = ui.read_text()

if 'VODIA_AWS_ONBOARDING_V50' in b or 'data-aws-onboarding="v0.14.9.50"' in s:
    raise SystemExit(0)

# Keep a pending customer External ID stable across retries. Regenerating it on
# every click invalidates a stack or CloudShell command that is already running.
old = '''export function prepareScopedAwsOnboarding(customerId) {
  const externalId = `vodia-${randomBytes(16).toString("hex")}`;
  const data = readAll();
  const customer = customerRecord(data, customerId);
  customer.awsOnboarding = {
    externalId,
    providerRoleArn: PROVIDER_ROLE_ARN,
    generatedAt: new Date().toISOString()
  };
  writeAll(data);'''
new = '''export function prepareScopedAwsOnboarding(customerId) {
  // VODIA_AWS_ONBOARDING_V50: retries reuse the same pending External ID.
  const data = readAll();
  const customer = customerRecord(data, customerId);
  const pending = customer.awsOnboarding;
  const reusable = Boolean(pending?.externalId && pending?.providerRoleArn === PROVIDER_ROLE_ARN);
  const externalId = reusable ? pending.externalId : `vodia-${randomBytes(16).toString("hex")}`;
  if (!reusable) {
    customer.awsOnboarding = {
      externalId,
      providerRoleArn: PROVIDER_ROLE_ARN,
      generatedAt: new Date().toISOString()
    };
    writeAll(data);
  }'''
if b.count(old) != 1:
    raise SystemExit(f"PATCH ERROR: onboarding preparation anchor count={b.count(old)}")
b = b.replace(old, new, 1)

old_return = '''    externalId,
    generatedAt: customer.awsOnboarding.generatedAt,'''
new_return = '''    externalId,
    generatedAt: customer.awsOnboarding.generatedAt,
    reused: reusable,'''
if b.count(old_return) != 1:
    raise SystemExit(f"PATCH ERROR: onboarding return anchor count={b.count(old_return)}")
b = b.replace(old_return, new_return, 1)

# Copy a verified connection without ever returning or displaying its External ID.
anchor = '''export function prepareScopedAwsOnboarding(customerId) {'''
reuse_fn = '''export async function reuseScopedAwsConnection(sourceCustomerId, targetCustomerId) {
  if (sourceCustomerId === targetCustomerId) throw new Error("AWS_CONNECTION_REUSE_SOURCE_REQUIRED");
  const data = readAll();
  const source = data.customers?.[sourceCustomerId]?.aws;
  if (!source?.roleArn || !source?.externalId) throw new Error("SOURCE_CUSTOMER_AWS_CONNECTION_REQUIRED");
  const identity = await testAws(source.roleArn, source.externalId);
  const target = customerRecord(data, targetCustomerId);
  target.aws = {
    roleArn: source.roleArn,
    externalId: source.externalId,
    account: identity.account,
    assumedRoleArn: identity.arn,
    reusedFromCustomerId: sourceCustomerId,
    savedAt: new Date().toISOString()
  };
  delete target.awsOnboarding;
  writeAll(data);
  return { connection: sanitizeScopedAwsConnection(target.aws), identity };
}

'''
if b.count(anchor) != 1:
    raise SystemExit(f"PATCH ERROR: reuse function anchor count={b.count(anchor)}")
b = b.replace(anchor, reuse_fn + anchor, 1)

tool_anchor = '''  server.registerTool("msp_prepare_customer_aws_onboarding", {'''
reuse_tool = '''  server.registerTool("msp_reuse_customer_aws_connection", {
    title: "Reuse verified customer AWS connection",
    description: "Explicitly links a target customer to another accessible customer's verified AWS connection after retesting STS. The External ID is never returned.",
    inputSchema: {
      sourceCustomerId: z.string().uuid(),
      targetCustomerId: z.string().uuid()
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
  }, async ({ sourceCustomerId, targetCustomerId }, extra) => {
    try {
      const sourceAccess = requireCustomerAccess(extra, sourceCustomerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      requireCustomerAccess(extra, targetCustomerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      const result = await reuseScopedAwsConnection(sourceCustomerId, targetCustomerId);
      scopedAudit("msp_reuse_customer_aws_connection", {
        sourceCustomerId, targetCustomerId, subject: sourceAccess.identity.subject, account: result.identity.account
      });
      return scopedSuccess({ targetCustomerId, connection: result.connection, identity: result.identity, changesMade: true },
        { operation: "MSP_CUSTOMER_AWS_CONNECTION_REUSE", readOnly: false },
        "Verified AWS connection reused for the selected customer.");
    } catch (error) { return failure(error, "MSP customer AWS connection reuse"); }
  });

'''
if b.count(tool_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: reuse tool anchor count={b.count(tool_anchor)}")
b = b.replace(tool_anchor, reuse_tool + tool_anchor, 1)

# UI marker and app version.
marker = '<div class="card" data-marketplace-first="v0.14.9.48" data-aws-verify-feedback="v0.14.9.49">'
if s.count(marker) != 1:
    raise SystemExit(f"PATCH ERROR: v0.14.9.49 UI marker count={s.count(marker)}")
s = s.replace(marker, '<div class="card" data-marketplace-first="v0.14.9.48" data-aws-verify-feedback="v0.14.9.49" data-aws-onboarding="v0.14.9.50">', 1)
s, n = re.subn(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}', 'appInfo:{name:"vodia-setup",version:"1.14.0"}', s, count=1)
if n != 1:
    raise SystemExit("PATCH ERROR: UI app version anchor missing")

# Make the prerequisite explicit and keep Verify disabled until confirmed.
input_anchor = '''              <input id="awsAccountId" inputmode="numeric" maxlength="12" placeholder="123456789012" autocomplete="off">
              <div class="secret-note">Use the AwsAccountId output after the stack reaches CREATE_COMPLETE. Vodia then verifies the generated role with AWS STS.</div>'''
input_new = input_anchor + '''
              <label style="display:flex;gap:8px;align-items:flex-start;margin-top:10px;font-weight:600">
                <input id="awsSetupComplete" type="checkbox" style="width:auto;margin-top:2px">
                <span>I completed AWS Setup and the CloudFormation stack shows CREATE_COMPLETE.</span>
              </label>'''
if s.count(input_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: CloudFormation completion gate anchor count={s.count(input_anchor)}")
s = s.replace(input_anchor, input_new, 1)
s = s.replace('<button id="verifyHostedAws" class="primary" type="button">Verify &amp; Connect</button>',
              '<button id="verifyHostedAws" class="primary" type="button" disabled>Verify &amp; Connect</button>', 1)

# Explicit reuse option for MSP-owned/shared AWS accounts.
reuse_html_anchor = '''        <div id="manualAwsToggleRow" class="actions hidden">'''
reuse_html = '''        <div id="reuseAwsBox" class="guided-box hidden">
          <div class="guided-title">Already connected this AWS account?</div>
          <div class="guided-copy">For an MSP-owned or shared AWS account, reuse another customer’s verified connection without showing or re-entering its External ID.</div>
          <div class="field">
            <label for="reuseAwsSource">Existing connected customer</label>
            <select id="reuseAwsSource"><option value="">Select existing customer…</option></select>
          </div>
          <button id="reuseAwsConnection" class="secondary" type="button">Verify &amp; Reuse Connection</button>
          <div id="reuseAwsMsg" class="msg" role="status" aria-live="polite"></div>
        </div>

'''
if s.count(reuse_html_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: reuse UI anchor count={s.count(reuse_html_anchor)}")
s = s.replace(reuse_html_anchor, reuse_html + reuse_html_anchor, 1)

# Show/hide reuse box with the rest of the connection UI.
hide_anchor = '''    $("manualAwsToggleRow").classList.add("hidden");'''
if s.count(hide_anchor) < 1:
    raise SystemExit("PATCH ERROR: render connection hide anchor missing")
s = s.replace(hide_anchor, hide_anchor + '\n    $("reuseAwsBox").classList.add("hidden");', 1)
show_anchor = '''      $("manualAwsToggleRow").classList.remove("hidden");'''
if s.count(show_anchor) < 1:
    raise SystemExit("PATCH ERROR: render connection show anchor missing")
s = s.replace(show_anchor, show_anchor + '''
      $("reuseAwsBox").classList.remove("hidden");
      refreshReuseAwsOptions();''', 1)

s = s.replace(
    'setMsg("awsMsg",selected?"Enter the AWS role ARN and External ID below to connect this customer.":"Select a customer to connect AWS.");',
    'setMsg("awsMsg",selected?"Complete the recommended AWS Setup below, or reuse an existing verified connection.":"Select a customer to connect AWS.");',
    1
)

# UI behavior for stable preparation, completion gate, and explicit reuse.
prepare_anchor = '''  $("prepareHostedAws").addEventListener("click",async()=>{'''
listeners = '''  function refreshReuseAwsOptions(){
    const target=customerId();
    const select=$("reuseAwsSource");
    select.innerHTML='<option value="">Select existing customer…</option>';
    (allCustomers||[]).filter(c=>c.id!==target).forEach(c=>{
      const option=document.createElement("option");
      option.value=c.id;
      option.textContent=c.name;
      select.appendChild(option);
    });
  }

  $("awsSetupComplete").addEventListener("change",()=>{
    $("verifyHostedAws").disabled=!$("awsSetupComplete").checked;
    if($("awsSetupComplete").checked){
      setAwsVerifyStatus("AWS setup completion confirmed. Enter AwsAccountId and verify.");
    }
  });

  $("reuseAwsConnection").addEventListener("click",async()=>{
    const targetCustomerId=customerId();
    const sourceCustomerId=$("reuseAwsSource").value;
    if(!targetCustomerId){setMsg("reuseAwsMsg","Select the target customer first.");return}
    if(!sourceCustomerId){setMsg("reuseAwsMsg","Select an existing connected customer.");return}
    try{
      $("reuseAwsConnection").disabled=true;
      $("reuseAwsConnection").textContent="Verifying…";
      setMsg("reuseAwsMsg","Retesting the existing AWS connection with STS…");
      await callTool("msp_reuse_customer_aws_connection",{sourceCustomerId,targetCustomerId});
      const verified=dataFrom(await callTool("msp_get_customer_aws_connection",{customerId:targetCustomerId}));
      if(!verified.connection?.configured) throw new Error("Reused AWS connection did not verify.");
      renderAwsConnection(verified.connection);
      setMsg("awsMsg","AWS account "+(verified.connection.account||"")+" was verified and connected securely.");
      await advanceToMarketplaceStep();
    }catch(e){
      setMsg("reuseAwsMsg",e?.message||String(e));
    }finally{
      $("reuseAwsConnection").disabled=false;
      $("reuseAwsConnection").textContent="Verify & Reuse Connection";
      reportSize();
    }
  });

'''
if s.count(prepare_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: prepare handler anchor count={s.count(prepare_anchor)}")
s = s.replace(prepare_anchor, listeners + prepare_anchor, 1)

prepared_anchor = '''      $("awsHostedInstructions").classList.remove("hidden");'''
if s.count(prepared_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: prepared UI anchor count={s.count(prepared_anchor)}")
s = s.replace(prepared_anchor, prepared_anchor + '''
      $("awsSetupComplete").checked=false;
      $("verifyHostedAws").disabled=true;''', 1)

# Refresh reuse choices whenever Connect is opened.
connect_anchor = '''    $("awsExternalId").value="";
    $("awsConnectForm").classList.remove("hidden");'''
if s.count(connect_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: connect handler anchor count={s.count(connect_anchor)}")
s = s.replace(connect_anchor, '''    $("awsExternalId").value="";
    refreshReuseAwsOptions();
    $("reuseAwsBox").classList.remove("hidden");
    $("awsConnectForm").classList.remove("hidden");''', 1)

# Refuse verification when the customer has not confirmed the AWS operation.
verify_anchor = '''    const accountId=$("awsAccountId").value.trim();
    if(!id){'''
verify_new = '''    const accountId=$("awsAccountId").value.trim();
    const setupComplete=Boolean($("awsSetupComplete")?.checked);
    if(!id){'''
if s.count(verify_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: verify prerequisite anchor count={s.count(verify_anchor)}")
s = s.replace(verify_anchor, verify_new, 1)
customer_check = '''      return;
    }
    if(!/^\\d{12}$/.test(accountId)){'''
gate = '''      return;
    }
    if(!setupComplete){
      setAwsVerifyStatus("Complete AWS Setup and confirm CREATE_COMPLETE before verifying.","error");
      return;
    }
    if(!/^\\d{12}$/.test(accountId)){'''
if s.count(customer_check) != 1:
    raise SystemExit(f"PATCH ERROR: verify gate insertion count={s.count(customer_check)}")
s = s.replace(customer_check, gate, 1)

finally_anchor = '''      $("verifyHostedAws").disabled=false;
      $("verifyHostedAws").textContent="Verify & Connect";'''
finally_new = '''      $("verifyHostedAws").disabled=!$("awsSetupComplete")?.checked;
      $("verifyHostedAws").textContent="Verify & Connect";'''
if s.count(finally_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: verify final state anchor count={s.count(finally_anchor)}")
s = s.replace(finally_anchor, finally_new, 1)

backend.write_text(b)
ui.write_text(s)
