#!/usr/bin/env bash
# Vodia MCP v0.14.9.77 — License Manager entitlement inspection + Marketplace evidence UI
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.77"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-license-evidence-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.76) ;;
  0.14.9.77) echo "v0.14.9.77 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.76 or .77; found ${CURRENT:-unknown}. Refusing to patch an unknown version." ;;
esac

echo "=== Vodia MCP v$TO_VER — License Manager entitlement inspection ==="
mkdir -p "$TMP/staged"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Ensure License Manager client import contains GetLicenseCommand.
if '@aws-sdk/client-license-manager' in s:
    # Handles either one-line or multiline named import.
    m=re.search(r'import\s*\{(?P<body>.*?)\}\s*from\s*["\']@aws-sdk/client-license-manager["\'];?',s,re.S)
    if not m:
        raise SystemExit("PATCH ERROR: could not parse existing License Manager import")
    body=m.group('body')
    required=['LicenseManagerClient','ListReceivedLicensesCommand','GetLicenseCommand']
    names=[x.strip() for x in body.replace('\n',' ').split(',') if x.strip()]
    for name in required:
        if name not in names: names.append(name)
    new='import {\n  '+',\n  '.join(names)+'\n} from "@aws-sdk/client-license-manager";'
    s=s[:m.start()]+new+s[m.end():]
else:
    # Insert after EC2 SDK import block.
    m=re.search(r'import\s*\{.*?\}\s*from\s*["\']@aws-sdk/client-ec2["\'];?',s,re.S)
    if not m:
        raise SystemExit("PATCH ERROR: EC2 import anchor missing")
    add='''\nimport {
  LicenseManagerClient,
  ListReceivedLicensesCommand,
  GetLicenseCommand
} from "@aws-sdk/client-license-manager";'''
    s=s[:m.end()]+add+s[m.end():]

if 'VODIA_LICENSE_EVIDENCE_V77' not in s:
    # Helper insertion immediately before tool registration function or first server.registerTool.
    anchor='  server.registerTool(\n    "aws_marketplace_check_subscription"'
    ti=s.find(anchor)
    if ti<0:
        raise SystemExit("PATCH ERROR: subscription tool registration anchor missing")

    helpers=r'''
const VODIA_LICENSE_EVIDENCE_V77 = true;

function normalizeLicenseEntitlementV77(item) {
  if (!item || typeof item!=="object") return null;
  return {
    name:item.Name || item.name || null,
    value:item.Value ?? item.value ?? null,
    maxCount:item.MaxCount ?? item.maxCount ?? null,
    unit:item.Unit || item.unit || null,
    allowCheckIn:item.AllowCheckIn ?? item.allowCheckIn ?? null,
    overage:item.Overage ?? item.overage ?? null
  };
}

function normalizeReceivedLicenseV77(license, detail=null) {
  const source=detail || license || {};
  const issuer=source.Issuer || license?.Issuer || {};
  const metadata=source.Metadata || license?.Metadata || [];
  const entitlements=(source.Entitlements || license?.Entitlements || [])
    .map(normalizeLicenseEntitlementV77).filter(Boolean);
  return {
    licenseArn:source.LicenseArn || license?.LicenseArn || null,
    licenseName:source.LicenseName || license?.LicenseName || null,
    productName:source.ProductName || license?.ProductName || null,
    productSKU:source.ProductSKU || license?.ProductSKU || null,
    issuer:{
      name:issuer?.Name || null,
      signKey:issuer?.SignKey || null
    },
    homeRegion:source.HomeRegion || license?.HomeRegion || null,
    status:source.Status || license?.Status || null,
    version:source.Version || license?.Version || null,
    beneficiary:source.Beneficiary || license?.Beneficiary || null,
    validity:source.Validity || license?.Validity || null,
    entitlements,
    metadata:(metadata || []).map(x=>({name:x?.Name || null,value:x?.Value || null})),
    consumptionConfiguration:source.ConsumptionConfiguration || license?.ConsumptionConfiguration || null
  };
}

function licenseSearchTextV77(license) {
  try {
    return JSON.stringify({
      licenseName:license?.licenseName,
      productName:license?.productName,
      productSKU:license?.productSKU,
      issuer:license?.issuer,
      metadata:license?.metadata,
      entitlements:license?.entitlements
    }).toLowerCase();
  } catch {
    return "";
  }
}

async function inspectVodiaLicenseEvidenceV77(roleArn, externalId, productId=null) {
  const region=AWS_DISCOVERY_REGION || "us-east-1";
  const client=new LicenseManagerClient({region,credentials:customerCredentials(roleArn,externalId)});
  const summaries=[];
  let nextToken;
  do {
    const out=await client.send(new ListReceivedLicensesCommand({
      NextToken:nextToken,
      MaxResults:100
    }));
    summaries.push(...(out.Licenses || []));
    nextToken=out.NextToken;
  } while(nextToken && summaries.length<500);

  const details=[];
  const detailErrors=[];
  for (const summary of summaries.slice(0,100)) {
    let detail=null;
    if (summary?.LicenseArn && summary?.Version) {
      try {
        const out=await client.send(new GetLicenseCommand({
          LicenseArn:summary.LicenseArn,
          Version:summary.Version
        }));
        detail=out.License || null;
      } catch(error) {
        detailErrors.push({
          licenseArn:summary?.LicenseArn || null,
          error:String(error?.message || error)
        });
      }
    }
    details.push(normalizeReceivedLicenseV77(summary,detail));
  }

  const configuredProductCode=typeof configuredMarketplaceProductCode==="function"
    ? configuredMarketplaceProductCode() : null;
  const needleTokens=[
    "vodia",
    String(productId || "").toLowerCase(),
    String(configuredProductCode || "").toLowerCase()
  ].filter(Boolean);

  const vodiaCandidates=details.filter(license=>{
    const text=licenseSearchTextV77(license);
    return needleTokens.some(token=>token && text.includes(token));
  });

  const directMappingEvidence=[];
  for (const license of details) {
    const text=licenseSearchTextV77(license);
    if (productId && text.includes(String(productId).toLowerCase())) {
      directMappingEvidence.push({licenseArn:license.licenseArn,matched:"productId",value:productId});
    }
    if (configuredProductCode && text.includes(String(configuredProductCode).toLowerCase())) {
      directMappingEvidence.push({licenseArn:license.licenseArn,matched:"marketplaceProductCode",value:configuredProductCode});
    }
  }

  return {
    status:"READABLE",
    checkedAt:new Date().toISOString(),
    region,
    receivedLicenseCount:details.length,
    vodiaCandidateCount:vodiaCandidates.length,
    licenses:details,
    vodiaCandidates,
    detailErrors,
    directMappingEvidence,
    agreementToLicenseMappingVerified:directMappingEvidence.length>0,
    deploymentCapacityVerified:false,
    explanation:"License Manager evidence is read-only. Vodia MCP does not infer deployable PBX count from license quantity or entitlement values until the agreement-to-license mapping and Vodia consumption rule are explicitly verified."
  };
}

'''
    s=s[:ti]+helpers+s[ti:]

    tool=r'''  server.registerTool(
    "aws_marketplace_inspect_vodia_license_evidence",
    {
      title: "Inspect Vodia AWS License Manager evidence",
      description: "Read-only. Lists received AWS License Manager licenses and retrieves license details so Vodia Marketplace contract evidence can be reviewed. It does not infer deployment capacity or modify subscriptions.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:true, destructiveHint:false, openWorldHint:true }
    },
    async (input, extra) => {
      scopedAudit("aws_marketplace_inspect_vodia_license_evidence",{
        customerId:input.customerId||null,
        productId:input.productId||null
      });
      try {
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"]);
        const evidence=await inspectVodiaLicenseEvidenceV77(
          c.roleArn,c.externalId,input.productId||null
        );
        return scopedSuccess({
          ...evidence,
          customerId:c.customerId||null,
          changesMade:false
        }, {operation:"AWS_MARKETPLACE_INSPECT_VODIA_LICENSE_EVIDENCE",readOnly:true},
        "AWS License Manager evidence loaded: "+evidence.receivedLicenseCount+" received license(s), "+evidence.vodiaCandidateCount+" Vodia candidate(s). Deployment capacity was not inferred.");
      } catch(error) {
        return failure(error,"AWS Marketplace Vodia License Manager evidence inspection");
      }
    }
  );

'''
    s=s[:ti]+tool+s[ti:]

# Correct Marketplace SSH username when AWS usage instructions explicitly name ubuntu.
old='sshUsername:process.env.VODIA_AWS_MARKETPLACE_SSH_USER || "root",'
if old in s:
    s=s.replace(old,
      'sshUsername:process.env.VODIA_AWS_MARKETPLACE_SSH_USER || (/username\\s+ubuntu/i.test(String(accessInfo?.usageInstructions||"")) ? "ubuntu" : "root"),',
      1
    )

p.write_text(s)
PY

echo "[2/8] Patch staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_LICENSE_EVIDENCE_UI_V77' not in s:
    # Add marker after product constant.
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0: raise SystemExit("PATCH ERROR: product constant anchor missing")
    le=s.find('\n',i)
    s=s[:le+1]+'  const VODIA_LICENSE_EVIDENCE_UI_V77 = true;\n'+s[le+1:]

    # Insert UI panel after the existing subscription summary.
    html_anchor='<div id="marketplaceSubscriptionSummary" class="summarybox hidden"></div>'
    if html_anchor not in s:
        raise SystemExit("PATCH ERROR: marketplace subscription summary anchor missing")
    panel='''<div id="marketplaceSubscriptionSummary" class="summarybox hidden"></div>
          <div id="marketplaceLicenseEvidenceBox" class="guided-box hidden" style="margin-top:10px">
            <div class="guided-title">AWS License Manager evidence <span id="marketplaceLicenseBadge" class="badge">Not checked</span></div>
            <div id="marketplaceLicenseEvidenceSummary" class="summarybox"></div>
            <div class="marketplace-actions">
              <button id="refreshMarketplaceLicenseEvidence" class="secondary" type="button">Inspect license evidence</button>
            </div>
            <div class="secret-note">Read-only evidence. License quantity is not treated as deployable PBX capacity until Vodia consumption rules are verified.</div>
          </div>'''
    s=s.replace(html_anchor,panel,1)

    # Insert renderer immediately before subscription renderer.
    fn_anchor='  function renderMarketplaceSubscription(active,message,subscription=null){'
    if fn_anchor not in s:
        raise SystemExit("PATCH ERROR: renderMarketplaceSubscription anchor missing")
    funcs=r'''  function renderMarketplaceLicenseEvidenceV77(evidence){
    const box=$("marketplaceLicenseEvidenceBox");
    const badge=$("marketplaceLicenseBadge");
    const summary=$("marketplaceLicenseEvidenceSummary");
    if(!box||!badge||!summary) return;
    box.classList.remove("hidden");
    if(!evidence){
      badge.textContent="Not checked";
      summary.textContent="License evidence has not been inspected yet.";
      return;
    }
    const errors=Array.isArray(evidence.errors)?evidence.errors:[];
    const licenses=Array.isArray(evidence.vodiaCandidates)&&evidence.vodiaCandidates.length
      ?evidence.vodiaCandidates:(Array.isArray(evidence.licenses)?evidence.licenses:[]);
    const status=evidence.status||((errors.length)?"UNKNOWN":"READABLE");
    badge.textContent=status;
    const lines=[
      "License check: "+status,
      evidence.checkedAt?("Checked: "+evidence.checkedAt):null,
      evidence.region?("License Manager region: "+evidence.region):null,
      evidence.receivedLicenseCount!==undefined?("Received licenses: "+evidence.receivedLicenseCount):null,
      evidence.vodiaCandidateCount!==undefined?("Vodia candidates: "+evidence.vodiaCandidateCount):null,
      evidence.agreementToLicenseMappingVerified!==undefined
        ?("Agreement-to-license mapping: "+(evidence.agreementToLicenseMappingVerified?"DIRECT EVIDENCE FOUND":"NOT VERIFIED")):null,
      "Deployable PBX capacity: "+(evidence.deploymentCapacityVerified?"VERIFIED":"NOT VERIFIED")
    ].filter(Boolean);
    licenses.slice(0,20).forEach((license,index)=>{
      lines.push("");
      lines.push("License "+(index+1)+": "+(license.licenseName||license.productName||license.licenseArn||"Unnamed"));
      if(license.productSKU) lines.push("SKU: "+license.productSKU);
      if(license.status) lines.push("Status: "+license.status);
      if(license.version) lines.push("Version: "+license.version);
      if(license.homeRegion) lines.push("Home region: "+license.homeRegion);
      const ents=Array.isArray(license.entitlements)?license.entitlements:[];
      ents.forEach(ent=>{
        const value=ent.value??ent.maxCount??"";
        lines.push("Entitlement: "+(ent.name||"unnamed")+(value!==""?(" = "+value):"")+(ent.unit?(" "+ent.unit):""));
      });
    });
    if(errors.length){
      lines.push("");
      errors.slice(0,5).forEach(err=>lines.push("Read error: "+(err.error||err)));
    }
    if(evidence.explanation){
      lines.push("");
      lines.push(evidence.explanation);
    }
    summary.textContent=lines.join("\n");
    reportSize();
  }

  async function inspectMarketplaceLicenseEvidenceV77(manual=false){
    const id=customerId();
    if(!id) return null;
    const button=$("refreshMarketplaceLicenseEvidence");
    try{
      if(button){button.disabled=true;button.textContent="Inspecting…";}
      $("marketplaceLicenseEvidenceBox")?.classList.remove("hidden");
      $("marketplaceLicenseBadge").textContent="Checking…";
      if(manual) setMsg("marketplaceMsg","Reading AWS License Manager evidence…");
      const raw=await callTool("aws_marketplace_inspect_vodia_license_evidence",{
        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID
      });
      if(raw?.isError) throw new Error(toolErrorText(raw)||"License evidence inspection failed.");
      const data=dataFrom(raw);
      renderMarketplaceLicenseEvidenceV77(data);
      return data;
    }catch(e){
      renderMarketplaceLicenseEvidenceV77({
        status:"UNKNOWN",
        errors:[e?.message||String(e)],
        deploymentCapacityVerified:false,
        explanation:"License Manager evidence could not be read. Deployment capacity remains unverified."
      });
      if(manual) setMsg("marketplaceMsg",e?.message||String(e));
      return null;
    }finally{
      if(button){button.disabled=false;button.textContent="Inspect license evidence";}
      reportSize();
    }
  }

'''
    s=s.replace(fn_anchor,funcs+fn_anchor,1)

    # Existing subscription response may already include licenseEvidence (.76).
    # Render it immediately, then request detailed GetLicense evidence in the background.
    call_anchor='''      renderMarketplaceSubscription(Boolean(r.active),null,r);
      return Boolean(r.active && (r.availableAgreementCount??0)>0);'''
    if call_anchor not in s:
        raise SystemExit("PATCH ERROR: subscription check response anchor missing")
    s=s.replace(call_anchor,'''      renderMarketplaceSubscription(Boolean(r.active),null,r);
      if(r.licenseEvidence) renderMarketplaceLicenseEvidenceV77(r.licenseEvidence);
      queueMicrotask(()=>inspectMarketplaceLicenseEvidenceV77(false));
      return Boolean(r.active && (r.availableAgreementCount??0)>0);''',1)

    # Button binding.
    bind_anchor='  $("checkMarketplace").addEventListener("click",checkMarketplaceSubscription);'
    if bind_anchor not in s:
        raise SystemExit("PATCH ERROR: checkMarketplace listener anchor missing")
    s=s.replace(bind_anchor,bind_anchor+'\n  $("refreshMarketplaceLicenseEvidence").addEventListener("click",()=>inspectMarketplaceLicenseEvidenceV77(true));',1)

# Update UI/runtime version markers.
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.77"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.35.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                 'ui://vodia/msp-guided/v0.14.9.77/mcp-app.html',s,count=1)
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
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null || fail "backend JavaScript invalid"
for marker in   'VODIA_LICENSE_EVIDENCE_V77'   'aws_marketplace_inspect_vodia_license_evidence'   'ListReceivedLicensesCommand'   'GetLicenseCommand'   'deploymentCapacityVerified:false'; do
  grep -Fq "$marker" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend marker missing: $marker"
done
echo "PASS: read-only License Manager evidence inspector staged"

echo "[4/8] Validate staged UI"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline.js" >/dev/null || fail "guided UI JavaScript invalid"
for marker in   'VODIA_LICENSE_EVIDENCE_UI_V77'   'AWS License Manager evidence'   'inspectMarketplaceLicenseEvidenceV77'   'aws_marketplace_inspect_vodia_license_evidence'; do
  grep -Fq "$marker" "$TMP/staged/msp-guided-app.html" || fail "UI marker missing: $marker"
done
echo "PASS: License Manager evidence UI staged"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.77 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v77 files"
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/8] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[7/8] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.77"' <<<"$HEALTH" || fail "health does not report v0.14.9.77"
echo "$HEALTH"
grep -Fq 'VODIA_LICENSE_EVIDENCE_V77' "$BACKEND" || fail "live license backend marker missing"
grep -Fq 'VODIA_LICENSE_EVIDENCE_UI_V77' "$UI" || fail "live license UI marker missing"
echo "PASS: live v77 markers present"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.77 installed."
echo "PASS: received licenses can be listed and detailed with GetLicense without changing AWS resources."
echo "PASS: Marketplace UI now displays License Manager evidence separately from deployment-capacity decisions."
echo "PASS: license quantities are not automatically treated as additional PBX deployment slots."
echo "PASS: Marketplace usage instructions can select ubuntu as the SSH username when explicitly stated."
echo "Backup: $BACKUP_DIR"
