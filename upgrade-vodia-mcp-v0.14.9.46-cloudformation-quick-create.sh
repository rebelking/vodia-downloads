#!/usr/bin/env bash
# Vodia MCP v0.14.9.46 — AWS CloudFormation Quick Create onboarding
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.46-cloudformation-quick-create-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

NEW_URI='ui://vodia/msp-guided/v0.14.9.46/mcp-app.html'
TEMPLATE_REPO_PATH='aws/cloudformation/vodia-mcp-customer-access-v1.yaml'

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node curl systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/msp-customer-connections-v1.js" "$APP/ui/msp-guided-app.html"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.43|0.14.9.44|0.14.9.45) ;;
  0.14.9.46) echo "v0.14.9.46 already installed; verification mode." ;;
  *) fail "expected v0.14.9.43 through v0.14.9.46; found ${CURRENT:-unknown}" ;;
esac

echo "[1/9] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/msp-customer-connections-v1.js" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

cp -a "$APP/ui/msp-guided-app.html" "$TMP/msp-guided-app.html"
cp -a "$APP/msp-guided-app-v1.js" "$TMP/msp-guided-app-v1.js"
cp -a "$APP/msp-customer-connections-v1.js" "$TMP/msp-customer-connections-v1.js"
cp -a "$APP/version.js" "$TMP/version.js"

echo "[2/9] Download versioned CloudFormation template"
mkdir -p "$TMP/aws/cloudformation"
curl -fsSL   "https://raw.githubusercontent.com/rebelking/vodia-downloads/feature/aws-marketplace-ec2-deploy-v1/$TEMPLATE_REPO_PATH"   -o "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml"
grep -Fq 'VodiaMCPDeploymentRole' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "CloudFormation deployment role missing"
grep -Fq 'sts:ExternalId' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "CloudFormation ExternalId condition missing"
grep -Fq 'VodiaPBXMarketplaceEntitlementRole' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "CloudFormation entitlement role missing"
echo PASS

if [[ "$CURRENT" != "0.14.9.46" ]]; then
  echo "[3/9] Patch hosted AWS onboarding backend"
  python3 - "$TMP/msp-customer-connections-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

if 'function buildCustomerQuickCreateUrl(' in s:
    raise SystemExit('PATCH ERROR: CloudFormation Quick Create support already present unexpectedly')

anchor='''const DEPLOYMENT_ROLE_NAME = "VodiaMCPDeploymentRole";
'''
if s.count(anchor)!=1:
    raise SystemExit(f'PATCH ERROR: deployment role constant anchor count={s.count(anchor)}')

addition=anchor+'''const ONBOARDING_CF_TEMPLATE_URL = String(process.env.VODIA_MCP_AWS_ONBOARDING_TEMPLATE_URL || "").trim();
const ONBOARDING_CF_REGION = String(process.env.VODIA_MCP_AWS_ONBOARDING_REGION || REGION || "us-east-1").trim();
const ONBOARDING_CF_STACK_NAME = String(process.env.VODIA_MCP_AWS_ONBOARDING_STACK_NAME || "Vodia-MCP-Connection").trim();

function validateCustomerQuickCreateTemplateUrl(value) {
  const raw=String(value||"").trim();
  if (!raw) return null;
  let u;
  try { u=new URL(raw); } catch { throw new Error("AWS_ONBOARDING_TEMPLATE_URL_INVALID: expected an HTTPS Amazon S3 template URL."); }
  if (u.protocol !== "https:") throw new Error("AWS_ONBOARDING_TEMPLATE_URL_INVALID: template URL must use HTTPS.");
  const h=u.hostname.toLowerCase();
  const documentedS3Host = h.startsWith("s3.") || h.startsWith("s3-") || h.includes(".s3.") || h.includes(".s3-");
  if (!documentedS3Host || !h.endsWith("amazonaws.com")) {
    throw new Error("AWS_ONBOARDING_TEMPLATE_URL_INVALID: AWS Quick Create requires a template URL hosted in Amazon S3.");
  }
  return u.toString();
}

function buildCustomerQuickCreateUrl(externalId) {
  const templateUrl=validateCustomerQuickCreateTemplateUrl(ONBOARDING_CF_TEMPLATE_URL);
  if (!templateUrl) return null;
  const region=ONBOARDING_CF_REGION || "us-east-1";
  const stackName=ONBOARDING_CF_STACK_NAME || "Vodia-MCP-Connection";
  if (!/^[A-Za-z][A-Za-z0-9-]{0,127}$/.test(stackName)) {
    throw new Error("AWS_ONBOARDING_STACK_NAME_INVALID: CloudFormation stack name must start with a letter and contain only letters, numbers, and hyphens.");
  }
  const q=new URLSearchParams();
  q.set("templateURL",templateUrl);
  q.set("stackName",stackName);
  q.set("param_ProviderRoleArn",PROVIDER_ROLE_ARN);
  q.set("param_ExternalId",externalId);
  return "https://" + region + ".console.aws.amazon.com/cloudformation/home?region=" + encodeURIComponent(region) + "#/stacks/create/review?" + q.toString();
}
'''
s=s.replace(anchor,addition,1)

old='''  return {
    providerRoleArn: PROVIDER_ROLE_ARN,
    roleName: DEPLOYMENT_ROLE_NAME,
    externalId,
    generatedAt: customer.awsOnboarding.generatedAt,
    cloudShellScript: buildCustomerCloudShellScript(externalId)
  };'''
new='''  const quickCreateUrl=buildCustomerQuickCreateUrl(externalId);
  return {
    providerRoleArn: PROVIDER_ROLE_ARN,
    roleName: DEPLOYMENT_ROLE_NAME,
    externalId,
    generatedAt: customer.awsOnboarding.generatedAt,
    onboardingMode: quickCreateUrl ? "cloudformation-quick-create" : "cloudshell-fallback",
    quickCreateUrl,
    cloudFormation: {
      configured: Boolean(quickCreateUrl),
      region: ONBOARDING_CF_REGION,
      stackName: ONBOARDING_CF_STACK_NAME,
      templateUrl: quickCreateUrl ? ONBOARDING_CF_TEMPLATE_URL : null,
      requiresNamedIamAcknowledgement: true,
      expectedOutputs: ["AwsAccountId","DeploymentRoleArn","EntitlementRoleName","ExternalId"]
    },
    cloudShellScript: buildCustomerCloudShellScript(externalId)
  };'''
if s.count(old)!=1:
    raise SystemExit(f'PATCH ERROR: onboarding return anchor count={s.count(old)}')
s=s.replace(old,new,1)

old_desc='description: "Generates a customer-specific External ID and a one-command AWS CloudShell setup script. The generated values are scoped to exactly one customer.",'
new_desc='description: "Generates a customer-specific External ID and AWS CloudFormation Quick Create setup when the Vodia-hosted S3 template URL is configured. CloudShell remains an advanced fallback. The generated values are scoped to exactly one customer.",'
if old_desc in s:
    s=s.replace(old_desc,new_desc,1)

p.write_text(s)
PY
  node --check "$TMP/msp-customer-connections-v1.js" >/dev/null || fail "patched customer connections module invalid"
  grep -Fq 'buildCustomerQuickCreateUrl' "$TMP/msp-customer-connections-v1.js" || fail "Quick Create builder missing"
  grep -Fq 'param_ExternalId' "$TMP/msp-customer-connections-v1.js" || fail "ExternalId Quick Create parameter missing"
  grep -Fq 'param_ProviderRoleArn' "$TMP/msp-customer-connections-v1.js" || fail "ProviderRoleArn Quick Create parameter missing"
  grep -Fq 'requiresNamedIamAcknowledgement: true' "$TMP/msp-customer-connections-v1.js" || fail "IAM acknowledgement metadata missing"
  echo PASS

  echo "[4/9] Patch guided UI for one-click CloudFormation setup"
  python3 - "$TMP/msp-guided-app.html" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

old='''        <div id="awsHostedSetup" class="guided-box hidden">
          <div class="guided-title">Connect AWS automatically <span class="badge">Recommended</span></div>
          <div class="guided-copy">Vodia generates the customer-specific External ID and a ready-to-run AWS CloudShell setup. The customer only returns the 12-digit AWS account ID printed by the command.</div>
          <button id="prepareHostedAws" class="primary" type="button">Generate AWS setup</button>
          <div id="awsHostedInstructions" class="hidden" style="margin-top:10px">
            <label for="awsCloudShellScript">AWS CloudShell command</label>
            <textarea id="awsCloudShellScript" class="codebox" readonly spellcheck="false"></textarea>
            <div class="aws-connect-actions">
              <button id="copyAwsScript" class="secondary" type="button">Copy command</button>
            </div>
            <div class="field">
              <label for="awsAccountId">AWS account ID after running the command <span class="required">*</span></label>
              <input id="awsAccountId" inputmode="numeric" maxlength="12" placeholder="123456789012" autocomplete="off">
            </div>
            <button id="verifyHostedAws" class="primary" type="button">Verify &amp; Connect</button>
          </div>
          <div id="awsHostedMsg" class="msg"></div>
        </div>'''
new='''        <div id="awsHostedSetup" class="guided-box hidden">
          <div class="guided-title">Connect AWS with CloudFormation <span class="badge">Recommended</span></div>
          <div class="guided-copy">Vodia generates a customer-specific External ID and opens AWS CloudFormation Quick Create. AWS creates the required roles after the customer reviews the template and acknowledges the named IAM resources.</div>
          <button id="prepareHostedAws" class="primary" type="button">Prepare AWS setup</button>
          <div id="awsHostedInstructions" class="hidden" style="margin-top:10px">
            <div id="awsQuickCreateBox" class="hidden">
              <div class="summarybox">1. Open AWS Setup.\n2. Review the CloudFormation template and parameters.\n3. Check the AWS acknowledgement for named IAM resources.\n4. Choose Create stack.\n5. When CREATE_COMPLETE, open Outputs and copy AwsAccountId below.</div>
              <div class="aws-connect-actions">
                <a id="openAwsQuickCreate" href="#" target="_blank" rel="noopener noreferrer"
                  style="display:inline-flex;align-items:center;padding:9px 11px;border:1px solid #111;border-radius:9px;background:#111;color:#fff;text-decoration:none;font-weight:650">Open AWS Setup</a>
              </div>
            </div>
            <div class="field" style="margin-top:10px">
              <label for="awsAccountId">AWS account ID from CloudFormation Outputs <span class="required">*</span></label>
              <input id="awsAccountId" inputmode="numeric" maxlength="12" placeholder="123456789012" autocomplete="off">
              <div class="secret-note">Use the AwsAccountId output after the stack reaches CREATE_COMPLETE. Vodia then verifies the generated role with AWS STS.</div>
            </div>
            <button id="verifyHostedAws" class="primary" type="button">Verify &amp; Connect</button>
            <div class="actions" style="justify-content:flex-start">
              <button id="toggleCloudShellFallback" class="linkbtn" type="button">Advanced fallback: use AWS CloudShell</button>
            </div>
            <div id="awsCloudShellFallback" class="hidden">
              <label for="awsCloudShellScript">AWS CloudShell command</label>
              <textarea id="awsCloudShellScript" class="codebox" readonly spellcheck="false"></textarea>
              <div class="aws-connect-actions">
                <button id="copyAwsScript" class="secondary" type="button">Copy command</button>
              </div>
            </div>
          </div>
          <div id="awsHostedMsg" class="msg"></div>
        </div>'''
if s.count(old)!=1:
    raise SystemExit(f'PATCH ERROR: hosted AWS HTML anchor count={s.count(old)}')
s=s.replace(old,new,1)

state_anchor='''  let currentMarketplaceQuote = null;
'''
if s.count(state_anchor)!=1:
    raise SystemExit(f'PATCH ERROR: marketplace quote state anchor count={s.count(state_anchor)}')
s=s.replace(state_anchor,state_anchor+'  let currentAwsQuickCreateUrl = "";\n',1)

old_handler='''  $("prepareHostedAws").addEventListener("click",async()=>{
    const id=customerId();
    if(!id) return;
    try{
      $("prepareHostedAws").disabled=true;
      $("prepareHostedAws").textContent="Generating…";
      setMsg("awsHostedMsg","Generating a customer-specific AWS setup…");
      const r=dataFrom(await callTool("msp_prepare_customer_aws_onboarding",{customerId:id}));
      const onboarding=r.onboarding||{};
      if(!onboarding.cloudShellScript) throw new Error("AWS setup command was not returned.");
      $("awsCloudShellScript").value=onboarding.cloudShellScript;
      $("awsHostedInstructions").classList.remove("hidden");
      setMsg("awsHostedMsg","Open AWS CloudShell as an administrator, run the command, then enter the printed 12-digit AWS account ID.");
    }catch(e){
      setMsg("awsHostedMsg",e.message);
    }finally{
      $("prepareHostedAws").disabled=false;
      $("prepareHostedAws").textContent="Generate AWS setup";
      reportSize();
    }
  });'''
new_handler='''  $("prepareHostedAws").addEventListener("click",async()=>{
    const id=customerId();
    if(!id) return;
    try{
      $("prepareHostedAws").disabled=true;
      $("prepareHostedAws").textContent="Preparing…";
      setMsg("awsHostedMsg","Generating a customer-specific External ID and AWS setup…");
      const r=dataFrom(await callTool("msp_prepare_customer_aws_onboarding",{customerId:id}));
      const onboarding=r.onboarding||{};
      currentAwsQuickCreateUrl=String(onboarding.quickCreateUrl||"");
      $("awsCloudShellScript").value=onboarding.cloudShellScript||"";
      $("awsHostedInstructions").classList.remove("hidden");
      if(currentAwsQuickCreateUrl){
        $("openAwsQuickCreate").href=currentAwsQuickCreateUrl;
        $("awsQuickCreateBox").classList.remove("hidden");
        setMsg("awsHostedMsg","AWS Quick Create is ready. Open AWS Setup, review the named IAM resources, create the stack, then return with the AwsAccountId output.");
      }else{
        $("awsQuickCreateBox").classList.add("hidden");
        $("awsCloudShellFallback").classList.remove("hidden");
        setMsg("awsHostedMsg","The Vodia-hosted CloudFormation template URL is not configured yet. Use the CloudShell fallback or configure VODIA_MCP_AWS_ONBOARDING_TEMPLATE_URL.");
      }
    }catch(e){
      setMsg("awsHostedMsg",e.message);
    }finally{
      $("prepareHostedAws").disabled=false;
      $("prepareHostedAws").textContent="Prepare AWS setup";
      reportSize();
    }
  });'''
if s.count(old_handler)!=1:
    raise SystemExit(f'PATCH ERROR: prepareHostedAws handler count={s.count(old_handler)}')
s=s.replace(old_handler,new_handler,1)

copy_anchor='''  $("copyAwsScript").addEventListener("click",async()=>{'''
if s.count(copy_anchor)!=1:
    raise SystemExit(f'PATCH ERROR: copyAwsScript anchor count={s.count(copy_anchor)}')
toggle='''  $("toggleCloudShellFallback").addEventListener("click",()=>{
    const opening=$("awsCloudShellFallback").classList.contains("hidden");
    $("awsCloudShellFallback").classList.toggle("hidden",!opening);
    $("toggleCloudShellFallback").textContent=opening
      ?"Hide AWS CloudShell fallback"
      :"Advanced fallback: use AWS CloudShell";
    reportSize();
  });

'''
s=s.replace(copy_anchor,toggle+copy_anchor,1)

s=s.replace(
  'setMsg("awsHostedMsg","Enter the 12-digit AWS account ID printed by CloudShell.");',
  'setMsg("awsHostedMsg","Enter the 12-digit AwsAccountId from the CloudFormation stack Outputs.");',
  1
)

s=s.replace('appInfo:{name:"vodia-setup",version:"1.9.0"}','appInfo:{name:"vodia-setup",version:"1.11.0"}')
s=s.replace('appInfo:{name:"vodia-setup",version:"1.10.0"}','appInfo:{name:"vodia-setup",version:"1.11.0"}')

p.write_text(s)
PY
  grep -Fq 'Connect AWS with CloudFormation' "$TMP/msp-guided-app.html" || fail "CloudFormation UI missing"
  grep -Fq 'id="openAwsQuickCreate"' "$TMP/msp-guided-app.html" || fail "Open AWS Setup link missing"
  grep -Fq 'Advanced fallback: use AWS CloudShell' "$TMP/msp-guided-app.html" || fail "CloudShell fallback missing"
  grep -Fq 'AwsAccountId from the CloudFormation stack Outputs' "$TMP/msp-guided-app.html" || fail "CloudFormation output guidance missing"
  echo PASS

  echo "[5/9] Patch MCP App URI"
  python3 - "$TMP/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
olds=[
 'ui://vodia/msp-guided/v0.14.9.43/mcp-app.html',
 'ui://vodia/msp-guided/v0.14.9.45/mcp-app.html'
]
new='ui://vodia/msp-guided/v0.14.9.46/mcp-app.html'
if new not in s:
    hits=[x for x in olds if x in s]
    if len(hits)!=1: raise SystemExit(f'PATCH ERROR: expected one known guided UI URI; found {hits}')
    s=s.replace(hits[0],new,1)
p.write_text(s)
PY
  node --check "$TMP/msp-guided-app-v1.js" >/dev/null || fail "guided app module syntax invalid"
  grep -Fq "$NEW_URI" "$TMP/msp-guided-app-v1.js" || fail "new UI URI missing"
  echo PASS

  echo "[6/9] Stage version"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.(?:43|44|45)(["\'])',r'\g<1>0.14.9.46\2',s,count=1)
if n != 1: raise SystemExit("PATCH ERROR: version anchor not found")
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.46' "$TMP/version.js" || fail "version staging failed"

  echo "[7/9] Static safety validation"
  node --check "$TMP/msp-customer-connections-v1.js" >/dev/null
  node --check "$TMP/msp-guided-app-v1.js" >/dev/null
  grep -Fq 'sts:ExternalId' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "ExternalId trust condition missing"
  grep -Fq 'RoleName: VodiaMCPDeploymentRole' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "named deployment role missing"
  grep -Fq 'InstanceProfileName: VodiaPBXMarketplaceEntitlementRole' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "named instance profile missing"
  grep -Fq 'AWSMarketplaceGetEntitlements' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "Marketplace entitlement policy missing"
  grep -Fq 'aws-marketplace:ProductId' "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" || fail "Vodia product condition missing"
  grep -Fq 'quickCreateUrl' "$TMP/msp-customer-connections-v1.js" || fail "Quick Create response missing"
  grep -Fq 'cloudShellScript: buildCustomerCloudShellScript' "$TMP/msp-customer-connections-v1.js" || fail "CloudShell fallback removed"
  grep -Fq 'completeScopedAwsOnboarding' "$TMP/msp-customer-connections-v1.js" || fail "STS verification flow removed"
  grep -Fq 'View plans &amp; subscribe' "$TMP/msp-guided-app.html" || fail "Marketplace subscription workflow removed"
  if grep -Fq 'finishDeploymentStatus' "$APP/ui/msp-guided-app.html"; then
    grep -Fq 'finishDeploymentStatus' "$TMP/msp-guided-app.html" || fail "v0.14.9.45 post-deploy status workflow was lost"
  fi
  echo "PASS: AWS-documented Quick Create URL format implemented"
  echo "PASS: customer-specific ExternalId remains in the trust policy"
  echo "PASS: named IAM acknowledgement is required by the template flow"
  echo "PASS: STS AssumeRole verification remains authoritative"
  echo "PASS: CloudShell remains an advanced fallback"
  echo "PASS: Marketplace and post-deployment workflows preserved"

  echo "[8/9] Install + restart"
  install -d -o root -g root -m 0755 "$APP/aws/cloudformation"
  install -o root -g root -m 0644 "$TMP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml" "$APP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml"
  install -o root -g root -m 0644 "$TMP/msp-customer-connections-v1.js" "$APP/msp-customer-connections-v1.js"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  systemctl restart "$SERVICE"
else
  echo "[3/9]-[8/9] Install skipped"
fi

HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.46"' <<<"$HEALTH" || fail "health does not report v0.14.9.46"
grep -Fq "$NEW_URI" "$APP/msp-guided-app-v1.js" || fail "live UI URI missing"
grep -Fq 'buildCustomerQuickCreateUrl' "$APP/msp-customer-connections-v1.js" || fail "live Quick Create builder missing"
grep -Fq 'id="openAwsQuickCreate"' "$APP/ui/msp-guided-app.html" || fail "live Open AWS Setup control missing"

echo "[9/9] Complete"
echo "PASS: Vodia MCP v0.14.9.46 installed and verified."
echo "PASS: customer AWS role creation now supports AWS CloudFormation Quick Create."
echo "PASS: Vodia generates the customer-specific External ID; AWS creates the named roles after customer review/acknowledgement."
echo "PASS: customer returns only AwsAccountId from stack Outputs; MCP verifies the role with STS AssumeRole."
echo "PASS: CloudShell and manual role entry remain fallback options."
echo "CloudFormation source installed at: $APP/aws/cloudformation/vodia-mcp-customer-access-v1.yaml"

if grep -q '^VODIA_MCP_AWS_ONBOARDING_TEMPLATE_URL=' "$ENV_FILE" 2>/dev/null; then
  echo "PASS: VODIA_MCP_AWS_ONBOARDING_TEMPLATE_URL is configured."
else
  echo "NOTICE: publish the template to a Vodia-controlled Amazon S3 object, then set VODIA_MCP_AWS_ONBOARDING_TEMPLATE_URL in $ENV_FILE."
  echo "Until that is configured, the UI safely falls back to AWS CloudShell."
fi

echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and open Vodia setup in a new message."
