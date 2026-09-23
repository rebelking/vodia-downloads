#!/usr/bin/env python3
"""Guarded source transformation; operate on a staging directory, never live files."""
from pathlib import Path
import re
import subprocess
import sys

ASSETS = Path(__file__).resolve().parent

def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f"Expected exactly one anchor: {old[:100]!r}; found {text.count(old)}")
    return text.replace(old, new, 1)

def patch_backend(s):
    if '// VODIA_MARKETPLACE_BACKEND_V76' in s:
        return s
    s = '// VODIA_MARKETPLACE_BACKEND_V76\nimport { purchaseError, readLicenseEvidence } from "./marketplace-v76/license-read.mjs";\n' + s
    s = once(s, '  const quote = await client.send(new CreateAgreementRequestCommand({',
             '  let quote;\n  try {\n    quote = await client.send(new CreateAgreementRequestCommand({')
    s = once(s, '    taxConfiguration: { taxEstimation: "ENABLED" }\n  }));',
             '    taxConfiguration: { taxEstimation: "ENABLED" }\n  }));\n  } catch (error) { throw purchaseError(error); }')
    # Preserve agreement filters and page through all results.
    start = s.index('async function checkSubscription(')
    end = s.index('\nasync function ', start + 1)
    part = s[start:end]
    part = once(part, '  const out = await client.send(new SearchAgreementsCommand({',
                '  const agreements = [];\n  let nextToken;\n  const seen = new Set();\n  do {\n  const out = await client.send(new SearchAgreementsCommand({\n    nextToken,')
    part = once(part, '  const agreements = out.agreementViewSummaries || [];',
                '  agreements.push(...(out.agreementViewSummaries || []));\n  nextToken = out.nextToken;\n  if (nextToken && seen.has(nextToken)) throw new Error("Repeated agreement pagination token");\n  seen.add(nextToken);\n  } while (nextToken);')
    s = s[:start] + part + s[end:]
    s = once(s, '  const availableAgreementCount = agreements.filter(a => a.deploymentUsage?.status === "AVAILABLE").length;',
             '''  // An incomplete inventory must never advertise an unassigned agreement as available.
  if ((inventory.regionErrors || []).length || !inventory.regionsScanned) {
    for (const agreement of agreements) {
      if (agreement.deploymentUsage?.status === "AVAILABLE") {
        agreement.deploymentUsage = {...agreement.deploymentUsage, status:"RECONCILIATION_NEEDED"};
      }
    }
  }
  const licenseEvidence = await readLicenseEvidence({
    credentials:customerCredentials(roleArn, externalId), productId,
    productCode:configuredMarketplaceProductCode(), region:AWS_DISCOVERY_REGION
  });
  const availableAgreementCount = agreements.filter(a => a.deploymentUsage?.status === "AVAILABLE").length;''')
    s = once(s, 'return { ...subscription, agreements, availableAgreementCount, inUseAgreementCount, inventory };',
             'return { ...subscription, agreements, availableAgreementCount, inUseAgreementCount, inventory, licenseEvidence };')
    # Existing assignment guard remains; do not treat quantity as number of PBXs.
    s = s.replace('Terminate the unwanted instance(s) and wait for AWS confirmation before reusing this subscription.',
                  'Existing allocation is preserved. Review license capacity and Vodia licensing rules or select a separately available agreement; do not terminate a working PBX just to unlock deployment.')
    s = s.replace('Create or select another AVAILABLE Marketplace agreement.',
                  'Refresh subscriptions and licenses. Reuse requires verified Vodia license allocation; otherwise select an AVAILABLE agreement.')
    # Enforce the same inventory completeness at both plan and apply, not only in the UI.
    for variable, anchor in [('planningInventory', '        const planningMatches='), ('launchInventory', '          const launchMatches=')]:
        if s.count(anchor) != 1:
            raise ValueError('Cannot locate inventory gate: ' + anchor)
        s = once(s, anchor, f'''        if (({variable}.regionErrors || []).length || !{variable}.regionsScanned) {{
          throw new Error("MARKETPLACE_INVENTORY_INCOMPLETE: refresh after resolving regional AWS read errors. No launch was attempted.");
        }}
''' + anchor)
    return s

def patch_ui(s):
    if '// VODIA_MARKETPLACE_FEEDBACK_V76' in s:
        return s
    panel = (ASSETS / 'purchase-panel.html').read_text()
    s = once(s, '          <div id="marketplaceSubscriptionSummary"', panel + '\n          <div id="marketplaceSubscriptionSummary"')
    s = once(s, '              <button id="prepareMarketplaceQuote"',
             '              <div id="marketplaceErrorV76" role="alert" class="summarybox hidden" style="white-space:pre-wrap;overflow-wrap:anywhere"></div>\n              <button id="prepareMarketplaceQuote"')
    helper_anchor = '  $("checkMarketplace").addEventListener("click",checkMarketplaceSubscription);'
    s = once(s, helper_anchor, (ASSETS / 'ui-helpers.js').read_text() + '\n' + helper_anchor)
    s = once(s, '      return result;\n    }catch(error){', '''      if(marketplaceToolsV76.has(name)) {
        const failure = marketplaceResultErrorV76(result);
        if(failure) throw new Error(failure);
      }
      return result;
    }catch(error){''')
    s = once(s, '      renderMarketplaceSubscription(Boolean(r.active),null,r);',
             '      renderMarketplaceSubscription(Boolean(r.active),null,r);\n      renderLicenseEvidenceV76(r);')
    # Reject stale status and plans while refresh is pending, on failures, and across customers.
    start = s.index('  async function checkMarketplaceSubscription(){')
    end = s.index('\n  function ', start + 1)
    part = s[start:end]
    part = once(part, '    try{', '''    if($("checkMarketplace").disabled) return false;
    marketplaceSubscriptionActive=false;
    currentMarketplaceSubscription=null;
    currentDeploymentPlan=null;
    $("applyDeployment").disabled=true;
    $("deploymentApproval").value="";
    $("approvalBox").dataset.planId="";
    $("approvalBox").dataset.confirmation="";
    $("approvalBox").classList.add("hidden");
    try{sessionStorage.removeItem("vodiaDeploymentPlan");}catch(_e){}
    $("continueMarketplace").disabled=true;
    $("refreshMarketplaceLicensesV76").disabled=true;
    renderLicenseEvidenceV76(null);
    updatePlanButton();
    try{''')
    part = once(part, '      renderMarketplaceSubscription(Boolean(r.active),null,r);',
                '      if(customerId()!==id) return false;\n      renderMarketplaceSubscription(Boolean(r.active),null,r);')
    part = once(part, '      $("checkMarketplace").disabled=false;',
                '      $("checkMarketplace").disabled=false;\n      $("refreshMarketplaceLicensesV76").disabled=false;')
    s = s[:start] + part + s[end:]
    # Guard manual handler duplication and clear any previously approved quote before attempting another.
    start = s.index('  $("prepareMarketplaceQuote").addEventListener("click",async()=>{')
    end = s.index('\n  $("marketplaceApproval")', start + 1)
    part = s[start:end]
    part = once(part, '    const id=customerId();', '''    if($("prepareMarketplaceQuote").disabled) return;
    clearMarketplaceQuoteV76();
    $("marketplaceErrorV76").classList.add("hidden");
    const id=customerId();''')
    part = once(part, '    try{', '''    const selectionAtRequest=JSON.stringify([currentMarketplaceOffer?.offerId,
      $("marketplacePlanSelect").value,$("marketplaceQuantity").value,$("marketplaceAutoRenew").checked]);
    try{''')
    part = once(part, '      currentMarketplaceQuote=r;', '''      if(customerId()!==id) throw new Error("Customer changed. Prepare a fresh quote for the selected customer.");
      if(selectionAtRequest!==JSON.stringify([currentMarketplaceOffer?.offerId,
        $("marketplacePlanSelect").value,$("marketplaceQuantity").value,$("marketplaceAutoRenew").checked])) {
        throw new Error("Purchase selection changed. Prepare a fresh quote before accepting.");
      }
      currentMarketplaceQuote=r;''')
    part = once(part, '      setMsg("marketplaceMsg",e.message);',
                '      clearMarketplaceQuoteV76();\n      setMsg("marketplaceMsg",e.message);')
    s = s[:start] + part + s[end:]
    # All Marketplace errors, including load/accept/refresh, must be visible.
    s = s.replace('setMsg("marketplaceMsg",e.message);',
                  'showMarketplaceFailureV76(e.message); setMsg("marketplaceMsg",e.message);')
    s = s.replace('All active subscriptions are already assigned. Start another subscription before deploying another PBX.',
                  'All active agreements have recorded deployments. Review license capacity in AWS, then refresh. Reusing an assigned agreement needs verified Vodia license allocation.')
    s = s.replace('Start another subscription', 'Review additional licenses')
    # Add subscription gating to every UI variant's existing readiness calculation.
    s = once(s, '  function updatePlanButton(){', '  function updatePlanButton(){\n    if(!marketplaceSubscriptionActive){$("planDeployment").disabled=true;return;}')
    return re.sub(r'uiVersion\s*:\s*["\']0\.14\.9\.\d+["\']', 'uiVersion:"0.14.9.76"', s)

def main(root):
    files = {name:(root/name).read_text() for name in
             ['aws-marketplace-ec2-deploy-v1.js','ui/msp-guided-app.html','msp-guided-app-v1.js','version.js']}
    current = re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)', files['version.js'])
    if not current or current[1] not in ['0.14.9.73','0.14.9.74','0.14.9.75','0.14.9.76']:
        raise ValueError('Supported installed versions: .73, .74, .75, .76')
    files['aws-marketplace-ec2-deploy-v1.js'] = patch_backend(files['aws-marketplace-ec2-deploy-v1.js'])
    files['ui/msp-guided-app.html'] = patch_ui(files['ui/msp-guided-app.html'])
    for name, pattern, replacement in [
        ('version.js',r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.76\2'),
        ('msp-guided-app-v1.js',r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.76/mcp-app.html')]:
        files[name], count = re.subn(pattern, replacement, files[name], count=1)
        if count != 1: raise ValueError('Version anchor missing: ' + name)
    for name, content in files.items(): (root/name).write_text(content)
    inline = '\n'.join(re.findall(r'<script[^>]*>(.*?)</script>',files['ui/msp-guided-app.html'],re.S))
    if not inline: raise ValueError('No UI script found')
    subprocess.run(['node','--check','--input-type=commonjs'],input=inline,text=True,check=True)
    for name in ['aws-marketplace-ec2-deploy-v1.js','msp-guided-app-v1.js','version.js']:
        subprocess.run(['node','--check','--input-type=module'],input=files[name],text=True,check=True)

if __name__ == '__main__': main(Path(sys.argv[1]))
