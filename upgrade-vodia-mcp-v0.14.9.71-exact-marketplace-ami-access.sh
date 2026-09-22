#!/usr/bin/env bash
# Vodia MCP v0.14.9.71 — exact Marketplace AMI binding + access instructions
set -Eeuo pipefail
APP="\${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="\${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.71"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="\${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v\${TO_VER}-exact-marketplace-ami-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ \${EUID} -eq 0 ]] || fail "run as root"
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
  0.14.9.70) ;;
  0.14.9.71) echo "v0.14.9.71 already installed; verification mode." ;;
  *) fail "expected v0.14.9.70; found \${CURRENT:-unknown}. Install through v0.14.9.70 first." ;;
esac

echo "=== Vodia MCP v\${TO_VER} — exact Marketplace AMI binding + access instructions ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

if [[ "$CURRENT" != "$TO_VER" ]]; then
echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_EXACT_MARKETPLACE_AMI_V71' in s: raise SystemExit(0)

start=s.find('async function resolveMarketplaceAmi(')
end=s.find('\nfunction buildRunInstancesParams(',start)
if start<0 or end<0: raise SystemExit("PATCH ERROR: resolveMarketplaceAmi boundaries missing")
resolver=r'''const VODIA_EXACT_MARKETPLACE_AMI_V71 = true;

function expectedVodiaMarketplaceAmiName(productId) {
  const id=String(productId || "").trim();
  if (!id) throw new Error("MARKETPLACE_PRODUCT_ID_REQUIRED: Vodia Marketplace product ID is required.");
  return "Vodia-marketplace-"+id;
}
function marketplaceCodesForImage(image) {
  return (image?.ProductCodes || []).filter(p => p?.ProductCodeType === "marketplace" && p?.ProductCodeId);
}
function verifyExactVodiaMarketplaceImage(image, input) {
  if (!image?.ImageId) throw new Error("MARKETPLACE_AMI_UNVERIFIED: EC2 returned no image ID.");
  const expectedName=expectedVodiaMarketplaceAmiName(input.productId);
  if (image.Name !== expectedName) throw new Error("MARKETPLACE_AMI_NAME_MISMATCH: expected "+expectedName+", got "+(image.Name || "unnamed")+".");
  const codes=marketplaceCodesForImage(image);
  if (!codes.length) throw new Error("NOT_MARKETPLACE_AMI: "+image.ImageId+" has no Marketplace product code.");
  if (input.productCode && !codes.some(p => p.ProductCodeId === input.productCode)) throw new Error("PRODUCT_CODE_MISMATCH: "+image.ImageId+" is not associated with "+input.productCode+".");
  if (image.Architecture !== "x86_64") throw new Error("MARKETPLACE_AMI_ARCHITECTURE_MISMATCH: expected x86_64.");
  if (image.State !== "available") throw new Error("MARKETPLACE_AMI_NOT_AVAILABLE: "+image.ImageId+" is not available.");
  return image;
}
async function resolveMarketplaceAmi(client, input) {
  const expectedName=expectedVodiaMarketplaceAmiName(input.productId);
  const code=String(input.productCode || process.env.VODIA_AWS_MARKETPLACE_PRODUCT_CODE || "").trim();
  if (!code) throw new Error("MARKETPLACE_PRODUCT_CODE_REQUIRED: configure VODIA_AWS_MARKETPLACE_PRODUCT_CODE.");
  if (input.amiId) {
    const out=await client.send(new DescribeImagesCommand({ ImageIds:[input.amiId] }));
    const image=(out.Images || [])[0];
    if (!image) throw new Error("AMI_NOT_FOUND: "+input.amiId);
    return verifyExactVodiaMarketplaceImage(image,{productId:input.productId,productCode:code});
  }
  const out=await client.send(new DescribeImagesCommand({
    Owners:["aws-marketplace"],
    Filters:[
      { Name:"name", Values:[expectedName] },
      { Name:"product-code", Values:[code] },
      { Name:"state", Values:["available"] },
      { Name:"architecture", Values:["x86_64"] },
      { Name:"virtualization-type", Values:["hvm"] },
      { Name:"root-device-type", Values:["ebs"] }
    ]
  }));
  const images=[...(out.Images || [])].filter(x=>x?.Name===expectedName).sort((a,b)=>String(b.CreationDate||"").localeCompare(String(a.CreationDate||"")));
  if (!images.length) throw new Error("EXACT_VODIA_MARKETPLACE_AMI_NOT_FOUND: "+expectedName+" with product code "+code+" was not visible in the selected region.");
  return verifyExactVodiaMarketplaceImage(images[0],{productId:input.productId,productCode:code});
}
async function readVodiaMarketplaceAmiInstructions(roleArn, externalId, productId) {
  try {
    const client=discoveryClient(roleArn,externalId);
    const out=await client.send(new ListFulfillmentOptionsCommand({ productId, maxResults:50 }));
    const options=(out.fulfillmentOptions || []).map(row=>row?.amazonMachineImageFulfillmentOption).filter(Boolean);
    if (!options.length) return { available:false, reason:"No AMI fulfillment option returned by AWS Marketplace." };
    const option=options[0];
    return {
      available:true,
      fulfillmentOptionId:option.fulfillmentOptionId || null,
      fulfillmentOptionName:option.fulfillmentOptionName || null,
      fulfillmentOptionDisplayName:option.fulfillmentOptionDisplayName || null,
      fulfillmentOptionVersion:option.fulfillmentOptionVersion || null,
      usageInstructions:option.usageInstructions || null,
      releaseNotes:option.releaseNotes || null,
      recommendedInstanceType:option.recommendation?.instanceType || null,
      operatingSystems:option.operatingSystems || []
    };
  } catch (error) {
    return { available:false, reason:String(error?.message || error) };
  }
}
function imageDeploymentMetadata(image, productId, accessInfo=null) {
  return {
    verified:true,
    expectedName:expectedVodiaMarketplaceAmiName(productId),
    imageId:image?.ImageId || null,
    imageName:image?.Name || null,
    creationDate:image?.CreationDate || null,
    architecture:image?.Architecture || null,
    virtualizationType:image?.VirtualizationType || null,
    rootDeviceType:image?.RootDeviceType || null,
    rootDeviceName:image?.RootDeviceName || null,
    bootMode:image?.BootMode || null,
    enaSupport:Boolean(image?.EnaSupport),
    productCodes:marketplaceCodesForImage(image),
    sshUsername:process.env.VODIA_AWS_MARKETPLACE_SSH_USER || "root",
    usageInstructions:accessInfo?.usageInstructions || null,
    fulfillmentOptionVersion:accessInfo?.fulfillmentOptionVersion || null,
    recommendedInstanceType:accessInfo?.recommendedInstanceType || null,
    operatingSystems:accessInfo?.operatingSystems || []
  };
}
'''
s=s[:start]+resolver+s[end:]

old='''        const image = await resolveMarketplaceAmi(client, input);
        const params = buildRunInstancesParams(input, image);
        await dryRunLaunch(client, params);

        const planId = randomUUID();'''
new='''        const image = await resolveMarketplaceAmi(client, input);
        const marketplaceAmiAccess = await readVodiaMarketplaceAmiInstructions(input.roleArn,input.externalId,input.productId);
        const marketplaceAmi = imageDeploymentMetadata(image,input.productId,marketplaceAmiAccess);
        const params = buildRunInstancesParams(input, image);
        await dryRunLaunch(client, params);

        const planId = randomUUID();'''
if old not in s: raise SystemExit("PATCH ERROR: planner image anchor missing")
s=s.replace(old,new,1)

old='''          imageId: image.ImageId,
          imageName: image.Name || null,
          productCodes: image.ProductCodes || [],
          params,''';
new='''          imageId: image.ImageId,
          imageName: image.Name || null,
          productCodes: image.ProductCodes || [],
          marketplaceAmi,
          params,''';
if old not in s: raise SystemExit("PATCH ERROR: plan persistence anchor missing")
s=s.replace(old,new,1)

old='''            imageId: image.ImageId,
            imageName: image.Name || null,
            instanceType: input.instanceType,''';
new='''            imageId: image.ImageId,
            imageName: image.Name || null,
            marketplaceAmi,
            instanceType: input.instanceType,''';
if old not in s: raise SystemExit("PATCH ERROR: plan response anchor missing")
s=s.replace(old,new,1)

old='''            imageId: plan.imageId,
            region: plan.region,
            name: plan.name,''';
new='''            imageId: plan.imageId,
            imageName: plan.imageName || null,
            marketplaceAmi: plan.marketplaceAmi || null,
            region: plan.region,
            name: plan.name,''';
if old not in s: raise SystemExit("PATCH ERROR: apply response anchor missing")
s=s.replace(old,new,1)

old='''        const marketplaceProductId = requiredInstanceTag(instance, "VodiaMarketplaceProductId") || ledgerRecord?.productId || null;

        let otherAgreementInstances=[];'''
new='''        const marketplaceProductId = requiredInstanceTag(instance, "VodiaMarketplaceProductId") || ledgerRecord?.productId || null;

        let marketplaceAmi=null;
        let marketplaceAmiVerificationError=null;
        if (marketplaceProductId && instance.ImageId) {
          try {
            const imageOut=await client.send(new DescribeImagesCommand({ ImageIds:[instance.ImageId] }));
            const deployedImage=(imageOut.Images || [])[0];
            const verifiedImage=verifyExactVodiaMarketplaceImage(deployedImage,{
              productId:marketplaceProductId,
              productCode:configuredMarketplaceProductCode()
            });
            const access=await readVodiaMarketplaceAmiInstructions(c.roleArn,c.externalId,marketplaceProductId);
            marketplaceAmi=imageDeploymentMetadata(verifiedImage,marketplaceProductId,access);
          } catch (error) {
            marketplaceAmiVerificationError=String(error?.message || error);
          }
        }

        let otherAgreementInstances=[];'''
if old not in s: raise SystemExit("PATCH ERROR: status identity anchor missing")
s=s.replace(old,new,1)

old='''          marketplaceProductCode:configuredMarketplaceProductCode()||null,
          marketplaceProductCodeVerified,
          statusChecksAvailable: Boolean(instanceStatus),'''
new='''          marketplaceProductCode:configuredMarketplaceProductCode()||null,
          marketplaceProductCodeVerified,
          marketplaceAmi,
          marketplaceAmiVerified:Boolean(marketplaceAmi?.verified),
          marketplaceAmiVerificationError,
          pbxAccessUrl:instance.PublicDnsName ? "https://"+instance.PublicDnsName : (instance.PublicIpAddress ? "https://"+instance.PublicIpAddress : null),
          sshUsername:marketplaceAmi?.sshUsername || "root",
          marketplaceUsageInstructions:marketplaceAmi?.usageInstructions || null,
          statusChecksAvailable: Boolean(instanceStatus),'''
if old not in s: raise SystemExit("PATCH ERROR: status result anchor missing")
s=s.replace(old,new,1)
p.write_text(s)
PY

echo "[2/8] Patch staged UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'data-exact-marketplace-ami="v0.14.9.71"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-exact-marketplace-ami="v0.14.9.71"',1)

old='''        "PBX: "+name,
        "Region: "+selectedRegion,''';
new='''        "PBX: "+name,
        "Region: "+selectedRegion,
        "Marketplace AMI: "+(plan.deployment?.marketplaceAmi?.imageName||plan.deployment?.imageName||"unverified"),
        "AMI ID (this region): "+(plan.deployment?.marketplaceAmi?.imageId||plan.deployment?.imageId||"unverified"),
        "AMI verification: "+(plan.deployment?.marketplaceAmi?.verified?"EXACT VODIA MARKETPLACE AMI":"NOT VERIFIED"),
        "AMI created: "+(plan.deployment?.marketplaceAmi?.creationDate||"unknown"),
        "Boot mode: "+(plan.deployment?.marketplaceAmi?.bootMode||"unknown"),''';
if old not in s: raise SystemExit("PATCH ERROR: review summary anchor missing")
s=s.replace(old,new,1)

old='''      "AMI: "+(status?.imageId||launchResult?.imageId||"")
    ].filter(Boolean).join("\\n");'''
new='''      "AMI: "+(status?.imageId||launchResult?.imageId||""),
      "AMI name: "+(status?.marketplaceAmi?.imageName||launchResult?.marketplaceAmi?.imageName||""),
      "Marketplace AMI verified: "+((status?.marketplaceAmiVerified||launchResult?.marketplaceAmi?.verified)?"YES":"NO"),
      "PBX access URL: "+(status?.pbxAccessUrl||"waiting for public DNS/IP"),
      "SSH username: "+(status?.sshUsername||launchResult?.marketplaceAmi?.sshUsername||"root"),
      (status?.marketplaceUsageInstructions||launchResult?.marketplaceAmi?.usageInstructions)
        ?("Marketplace access instructions: "+(status?.marketplaceUsageInstructions||launchResult?.marketplaceAmi?.usageInstructions))
        :null
    ].filter(Boolean).join("\\n");'''
if old not in s: raise SystemExit("PATCH ERROR: running summary anchor missing")
s=s.replace(old,new,1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.71"',s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}','appInfo:{name:"vodia-setup",version:"1.29.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.71/mcp-app.html',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY
fi

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_EXACT_MARKETPLACE_AMI_V71' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend marker missing"
grep -Fq 'expectedVodiaMarketplaceAmiName' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "exact AMI resolver missing"
grep -Fq 'readVodiaMarketplaceAmiInstructions' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "Marketplace access reader missing"
grep -Fq 'MARKETPLACE_AMI_NAME_MISMATCH' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "AMI guard missing"
echo "PASS: exact Marketplace AMI + access metadata backend present"

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
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided UI JavaScript invalid"
grep -Fq 'Marketplace AMI:' "$TMP/staged/msp-guided-app.html" || fail "review AMI evidence missing"
grep -Fq 'PBX access URL:' "$TMP/staged/msp-guided-app.html" || fail "PBX access display missing"
grep -Fq 'uiVersion:"0.14.9.71"' "$TMP/staged/msp-guided-app.html" || fail "debug version marker missing"
echo "PASS: exact AMI and access information visible"

if [[ "$CURRENT" != "$TO_VER" ]]; then
echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.70 files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/8] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"
else
  echo "[5/8]-[6/8] already v0.14.9.71"
fi

echo "[7/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.71"' <<<"$HEALTH" || fail "health does not report v0.14.9.71"
echo "$HEALTH"

echo "[8/8] Complete"
echo "PASS: v0.14.9.71 installed."
echo "PASS: subscription is the entitlement gate; exact Vodia Marketplace AMI is the deployment source."
echo "PASS: AMI name Vodia-marketplace-<productId> is required in the selected region."
echo "PASS: Review shows exact regional AMI ID before deployment."
echo "PASS: Marketplace usage instructions and access hints are surfaced after deployment."
echo "Backup: $BACKUP_DIR"
