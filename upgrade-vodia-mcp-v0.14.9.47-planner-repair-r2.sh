#!/usr/bin/env bash
# Vodia MCP v0.14.9.47 — deployment planner repair
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
SOURCE_COMMIT="5d44215c23c426dfa97a2f5fc32a646e2994809c"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
NEW_URI="ui://vodia/msp-guided/v0.14.9.47/mcp-app.html"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.47-planner-repair-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/msp-guided-app-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js" "$APP/ui/msp-guided-app.html"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(); m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else '',end='')
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.43|0.14.9.44|0.14.9.45|0.14.9.46) ;;
  0.14.9.47) echo "v0.14.9.47 already installed; verification mode." ;;
  *) fail "expected v0.14.9.43 through v0.14.9.47; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$APP/msp-guided-app-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js" "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

echo "[2/7] Stage planner repair"
cp -a "$APP/ui/msp-guided-app.html" "$TMP/msp-guided-app.html"
cp -a "$APP/msp-guided-app-v1.js" "$TMP/msp-guided-app-v1.js"
cp -a "$APP/aws-marketplace-ec2-deploy-v1.js" "$TMP/aws-marketplace-ec2-deploy-v1.js"
cp -a "$APP/version.js" "$TMP/version.js"

if [[ "$CURRENT" != "0.14.9.47" ]]; then
python3 - "$TMP/msp-guided-app.html" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
s=s.replace('appInfo:{name:"vodia-setup",version:"1.9.0"}','appInfo:{name:"vodia-setup",version:"1.9.1"}',1)
if 'function toolFailureMessage(' not in s:
 old='''  async function callTool(name,args={}){
    if(window.openai?.callTool) return window.openai.callTool(name,args);
    if(!initialized) await initBridge();
    return request("tools/call",{name,arguments:args});
  }
'''
 new='''  function toolFailureMessage(result,name){
    const sc=result?.structuredContent;
    const data=sc?.data||sc?.result||sc;
    const text=(result?.content||[]).find(x=>x?.type==="text")?.text;
    let parsedText=null;
    if(text){try{parsedText=JSON.parse(text)}catch{}}
    const candidates=[data?.error?.message,data?.error,data?.message,sc?.error?.message,sc?.error,sc?.message,parsedText?.error?.message,parsedText?.error,parsedText?.message,text];
    const failed=result?.isError===true||data?.ok===false||data?.success===false||Boolean(data?.error);
    if(!failed) return null;
    return candidates.find(x=>typeof x==="string"&&x.trim())?.trim()||`${name} failed.`;
  }

  async function callTool(name,args={}){
    let result;
    if(window.openai?.callTool) result=await window.openai.callTool(name,args);
    else {
      if(!initialized) await initBridge();
      result=await request("tools/call",{name,arguments:args});
    }
    const failure=toolFailureMessage(result,name);
    if(failure) throw new Error(failure);
    return result;
  }
'''
 if s.count(old)!=1: raise SystemExit('PATCH ERROR: callTool anchor not found')
 s=s.replace(old,new,1)
p.write_text(s)
PY

python3 - "$TMP/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'async function discoverVodiaMarketplaceAmi(' not in s:
 start=s.find('async function resolveMarketplaceAmi(')
 end=s.find('\nfunction buildRunInstancesParams(',start)
 if start<0 or end<0: raise SystemExit('PATCH ERROR: resolveMarketplaceAmi anchors not found')
 new=r'''function newestMarketplaceImage(images) {
  return [...images].sort((a, b) => String(b.CreationDate || "").localeCompare(String(a.CreationDate || "")))[0] || null;
}

async function describeImagesForProductCode(client, code) {
  const out = await client.send(new DescribeImagesCommand({
    Owners: ["aws-marketplace"],
    Filters: [
      { Name: "product-code", Values: [code] },
      { Name: "state", Values: ["available"] },
      { Name: "architecture", Values: ["x86_64"] }
    ]
  }));
  return out.Images || [];
}

async function discoverVodiaMarketplaceAmi(client) {
  const searches = await Promise.all(["name", "description"].map(field => client.send(new DescribeImagesCommand({
    Owners: ["aws-marketplace"],
    Filters: [
      { Name: field, Values: ["*Vodia*", "*vodia*"] },
      { Name: "state", Values: ["available"] },
      { Name: "architecture", Values: ["x86_64"] }
    ]
  }))));
  const unique = new Map();
  for (const out of searches) for (const image of out.Images || []) {
    if ((image.ProductCodes || []).some(p => p.ProductCodeType === "marketplace")) unique.set(image.ImageId, image);
  }
  return newestMarketplaceImage(unique.values());
}

async function resolveMarketplaceAmi(client, { amiId, productCode, productId, roleArn, externalId }) {
  if (amiId) {
    const out = await client.send(new DescribeImagesCommand({ ImageIds: [amiId] }));
    const image = (out.Images || [])[0];
    if (!image) throw new Error(`AMI_NOT_FOUND: ${amiId}`);
    const marketplaceCodes = (image.ProductCodes || []).filter(p => p.ProductCodeType === "marketplace");
    if (!marketplaceCodes.length) throw new Error(`NOT_MARKETPLACE_AMI: ${amiId} has no Marketplace product code.`);
    if (productCode && !marketplaceCodes.some(p => p.ProductCodeId === productCode)) throw new Error(`PRODUCT_CODE_MISMATCH: ${amiId} is not associated with ${productCode}.`);
    return image;
  }
  const codes = new Set();
  const configuredCode = String(productCode || process.env.VODIA_AWS_MARKETPLACE_PRODUCT_CODE || "").trim();
  if (configuredCode) codes.add(configuredCode);
  if (productId && roleArn && externalId) {
    const fulfillment = await discoveryClient(roleArn, externalId).send(new ListFulfillmentOptionsCommand({ productId, maxResults: 50 }));
    for (const option of fulfillment.fulfillmentOptions || []) {
      const id = String(option?.amazonMachineImageFulfillmentOption?.fulfillmentOptionId || "").trim();
      if (id) codes.add(id);
    }
  }
  for (const code of codes) {
    try {
      const image = newestMarketplaceImage(await describeImagesForProductCode(client, code));
      if (image) return image;
    } catch (error) {
      if (configuredCode && code === configuredCode) throw error;
    }
  }
  const discovered = await discoverVodiaMarketplaceAmi(client);
  if (discovered) return discovered;
  const tried = codes.size ? ` Tried fulfillment/product code(s): ${[...codes].join(", ")}.` : "";
  throw new Error(`VODIA_MARKETPLACE_AMI_NOT_FOUND: the subscription is active, but no entitled x86_64 Vodia Marketplace AMI is visible in this Region.${tried} Try another Region or confirm the offer includes an AMI fulfillment option.`);
}
'''
 s=s[:start]+new+s[end:]
p.write_text(s)
PY

python3 - "$TMP/msp-guided-app-v1.js" "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
module=Path(sys.argv[1]); s=module.read_text()
s,n=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.47/mcp-app.html',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: UI URI anchor not found')
module.write_text(s)
version=Path(sys.argv[2]); s=version.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.\d+(["\'])',r'\g<1>0.14.9.47\2',s,count=1)
if n!=1: raise SystemExit('PATCH ERROR: connector version anchor not found')
version.write_text(s)
PY
fi

echo "[3/7] Verify staged files"
curl -fsSL "$RAW_BASE/verify-vodia-guided-aws-deploy-v0.14.9.47-r2.sh" -o "$TMP/verify.sh"
chmod +x "$TMP/verify.sh"
mkdir -p "$TMP/staged/ui"
cp "$TMP/msp-guided-app.html" "$TMP/staged/ui/msp-guided-app.html"
cp "$TMP/msp-guided-app-v1.js" "$TMP/aws-marketplace-ec2-deploy-v1.js" "$TMP/staged/"
VODIA_MCP_APP_DIR="$TMP/staged" "$TMP/verify.sh"

if [[ "$CURRENT" != "0.14.9.47" ]]; then
  echo "[4/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
  install -o root -g root -m 0644 "$TMP/aws-marketplace-ec2-deploy-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"
  echo "[5/7] Restart"
  systemctl restart "$SERVICE"
else
  echo "[4/7]-[5/7] Install skipped"
fi

echo "[6/7] Verify live service"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.47"' <<<"$HEALTH" || fail "health does not report v0.14.9.47"
VODIA_MCP_APP_DIR="$APP" "$TMP/verify.sh"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.47 installed and verified."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client, reopen Vodia setup, and create the deployment plan again."
