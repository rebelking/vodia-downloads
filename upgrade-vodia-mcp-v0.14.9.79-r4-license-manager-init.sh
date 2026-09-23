#!/usr/bin/env bash
# Vodia MCP v0.14.9.79-r4 — License Manager one-time initializer using marketplace-v76 helper architecture
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
MARKET="$APP/marketplace-v76"
LICENSE_READ="$MARKET/license-read.mjs"
LICENSE_INIT="$MARKET/license-init.mjs"
PKG="$MARKET/package.json"
LOCK="$MARKET/package-lock.json"
TO_VER="0.14.9.79"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-r4-license-manager-init-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
IAM_WAS_PRESENT=0
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node npm grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION" "$LICENSE_READ" "$PKG" "$LOCK"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.78) ;;
  0.14.9.79) echo "v0.14.9.79 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.78 or .79; found ${CURRENT:-unknown}. Refusing to patch an unknown version." ;;
esac

echo "=== Vodia MCP v$TO_VER-r4 — License Manager initializer ==="
echo "[0/9] Live-layout preflight — NO LIVE CHANGES"

grep -Fq 'VODIA_MARKETPLACE_BACKEND_V76' "$BACKEND" || fail "marketplace-v76 backend marker missing"
grep -Fq 'readLicenseEvidence' "$BACKEND" || fail "backend does not use marketplace-v76 readLicenseEvidence"
grep -Fq '@aws-sdk/client-license-manager' "$LICENSE_READ" || fail "license-read.mjs does not dynamically load client-license-manager"
grep -Fq 'ListReceivedLicensesCommand' "$LICENSE_READ" || fail "license-read.mjs ListReceivedLicenses path missing"
grep -Fq 'id="checkMarketplace"' "$UI" || fail "guided UI checkMarketplace button anchor missing"
grep -Fq 'renderMarketplaceSubscription(Boolean(r.active),null,r);' "$UI" || fail "guided UI subscription-render anchor missing"

LM_SDK_VERSION="$(python3 - "$PKG" <<'PY'
import json,sys
with open(sys.argv[1]) as f: j=json.load(f)
print((j.get("dependencies") or {}).get("@aws-sdk/client-license-manager",""),end="")
PY
)"
[[ -n "$LM_SDK_VERSION" ]] || fail "package.json does not declare @aws-sdk/client-license-manager"
echo "PASS: marketplace-v76 uses @aws-sdk/client-license-manager@$LM_SDK_VERSION"

(cd "$MARKET" && node --input-type=module -e 'await import("@aws-sdk/client-license-manager"); console.log("PASS: client-license-manager import works from marketplace-v76")')

if (cd "$MARKET" && node --input-type=module -e 'await import("@aws-sdk/client-iam")' >/dev/null 2>&1); then
  IAM_WAS_PRESENT=1
  echo "PASS: @aws-sdk/client-iam already available in marketplace-v76"
else
  IAM_WAS_PRESENT=0
  echo "INFO: @aws-sdk/client-iam is not installed in marketplace-v76"
  npm view "@aws-sdk/client-iam@$LM_SDK_VERSION" version >/dev/null 2>&1 \
    || fail "@aws-sdk/client-iam@$LM_SDK_VERSION is not available from npm"
  echo "PASS: matching @aws-sdk/client-iam@$LM_SDK_VERSION is available"
  echo "INFO: live install will add it under $MARKET"
fi

mkdir -p "$TMP/staged"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

cat >"$TMP/staged/license-init.mjs" <<'MJS'
// VODIA_LICENSE_MANAGER_INIT_HELPER_V79_R4
// Narrow one-time bootstrap for the AWS License Manager core service-linked role.
// Uses the customer credentials supplied by Vodia MCP. It does not purchase Marketplace
// products, launch EC2, modify agreements, or infer PBX deployment capacity.

const SERVICE_NAME = "license-manager.amazonaws.com";
const ROLE_NAME = "AWSServiceRoleForAWSLicenseManagerRole";

function normalizeAwsError(error) {
  return {
    name:String(error?.name || error?.code || "AWS_ERROR"),
    message:String(error?.message || error),
    requestId:error?.$metadata?.requestId || null,
    httpStatusCode:error?.$metadata?.httpStatusCode || null
  };
}

function alreadyExists(error) {
  const e=normalizeAwsError(error);
  return e.name==="EntityAlreadyExists" ||
    e.name==="EntityAlreadyExistsException" ||
    /already exists|has been taken/i.test(e.message);
}

export async function initializeLicenseManagerServiceRole({credentials, sdk}) {
  sdk ||= await import("@aws-sdk/client-iam");
  const client=new sdk.IAMClient({region:"us-east-1",credentials});
  try {
    const out=await client.send(new sdk.CreateServiceLinkedRoleCommand({
      AWSServiceName:SERVICE_NAME,
      Description:"AWS License Manager core service-linked role initialized by Vodia MCP."
    }));
    return {
      ok:true,
      created:true,
      alreadyExisted:false,
      serviceName:SERVICE_NAME,
      roleName:out?.Role?.RoleName || ROLE_NAME,
      roleArn:out?.Role?.Arn || null
    };
  } catch(error) {
    if (alreadyExists(error)) {
      return {
        ok:true,
        created:false,
        alreadyExisted:true,
        serviceName:SERVICE_NAME,
        roleName:ROLE_NAME,
        roleArn:null
      };
    }
    const e=normalizeAwsError(error);
    const err=new Error(e.message);
    err.name=e.name;
    err.requestId=e.requestId;
    err.httpStatusCode=e.httpStatusCode;
    throw err;
  }
}
MJS

echo "[1/9] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_LICENSE_MANAGER_INIT_BACKEND_V79_R4' not in s:
    anchor='import { purchaseError, readLicenseEvidence } from "./marketplace-v76/license-read.mjs";'
    if anchor not in s:
        raise SystemExit("PATCH ERROR: marketplace-v76 license-read import anchor missing")
    s=s.replace(anchor,anchor+'\nimport { initializeLicenseManagerServiceRole } from "./marketplace-v76/license-init.mjs";\n// VODIA_LICENSE_MANAGER_INIT_BACKEND_V79_R4',1)

tool_anchor='''  server.registerTool(
    "aws_marketplace_check_subscription",'''
if 'aws_license_manager_initialize' not in s:
    if tool_anchor not in s:
        raise SystemExit("PATCH ERROR: subscription tool registration anchor missing")
    tool=r'''  server.registerTool(
    "aws_license_manager_initialize",
    {
      title: "Initialize AWS License Manager",
      description: "One-time AWS setup. Creates only the License Manager core service-linked role in the connected customer account, then retries the existing read-only Vodia license evidence check. Requires exact confirmation.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        confirmation: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, productId, confirmation }, extra) => {
      scopedAudit("aws_license_manager_initialize", { customerId: customerId || null, roleArn, productId });
      try {
        const required="INITIALIZE AWS LICENSE MANAGER";
        if (confirmation!==required) {
          throw new Error("CONFIRMATION_REQUIRED: use exact phrase "+required);
        }
        const c=resolveToolConnection(
          { customerId, roleArn, externalId },
          extra,
          ["MSP_ADMIN","CUSTOMER_ADMIN"]
        );
        const credentials=customerCredentials(c.roleArn,c.externalId);
        const initialization=await initializeLicenseManagerServiceRole({credentials});

        let evidence=null;
        for (let attempt=0; attempt<5; attempt++) {
          if (attempt>0) await new Promise(resolve=>setTimeout(resolve,1000*(attempt+1)));
          evidence=await readLicenseEvidence({
            credentials,
            productId,
            productCode:configuredMarketplaceProductCode(),
            region:AWS_DISCOVERY_REGION
          });
          const missing=(evidence?.errors || []).some(x=>/service role not found/i.test(String(x)));
          if (!missing) break;
        }

        const stillPending=(evidence?.errors || []).some(x=>/service role not found/i.test(String(x)));
        return scopedSuccess({
          initialized:true,
          initialization,
          licenseManagerReady:!stillPending,
          evidence,
          customerId:c.customerId || null,
          changesMade:Boolean(initialization?.created)
        }, {
          operation:"AWS_LICENSE_MANAGER_INITIALIZE",
          readOnly:false
        }, stillPending
          ? "AWS License Manager service-linked role request completed, but AWS is still propagating the role. Retry the subscription check shortly."
          : "AWS License Manager initialized and license evidence check retried.");
      } catch(error) {
        return failure(error,"AWS License Manager initialization");
      }
    }
  );

'''
    s=s.replace(tool_anchor,tool+tool_anchor,1)

p.write_text(s)
PY

echo "[2/9] Patch staged UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_LICENSE_MANAGER_INIT_UI_V79_R4' not in s:
    # Add a hidden one-time initialization button next to the existing Marketplace check button.
    m=re.search(r'(<button\s+id="checkMarketplace"[^>]*>.*?</button>)',s,re.S)
    if not m:
        raise SystemExit("PATCH ERROR: checkMarketplace button HTML missing")
    button='''\n              <button id="initializeMarketplaceLicenseManager" class="secondary hidden" type="button" title="One-time AWS License Manager setup">Initialize License Manager</button>'''
    s=s[:m.end()]+button+s[m.end():]

    fn_anchor='  async function checkMarketplaceSubscription'
    if fn_anchor not in s:
        raise SystemExit("PATCH ERROR: checkMarketplaceSubscription function anchor missing")
    init_fn=r'''  const VODIA_LICENSE_MANAGER_INIT_UI_V79_R4 = true;

  async function initializeMarketplaceLicenseManagerV79R4(){
    const id=customerId();
    if(!id) return null;
    const button=$("initializeMarketplaceLicenseManager");
    const approved=window.confirm(
      "Initialize AWS License Manager for this customer account?\n\n"+
      "This creates only AWSServiceRoleForAWSLicenseManagerRole using the connected customer deployment role. "+
      "It does not purchase anything, launch EC2, or change the Marketplace agreement."
    );
    if(!approved) return null;
    try{
      if(button){button.disabled=true;button.textContent="Initializing…";}
      setMsg("marketplaceMsg","Initializing AWS License Manager…");
      const raw=await callTool("aws_license_manager_initialize",{
        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID,
        confirmation:"INITIALIZE AWS LICENSE MANAGER"
      });
      if(raw?.isError) throw new Error(toolErrorText(raw)||"License Manager initialization failed.");
      const data=dataFrom(raw);
      if(data?.licenseManagerReady){
        setMsg("marketplaceMsg","AWS License Manager initialized. Refreshing subscription and license evidence…");
      }else{
        setMsg("marketplaceMsg","AWS accepted the License Manager initialization. The service-linked role may still be propagating.");
      }
      await checkMarketplaceSubscription();
      return data;
    }catch(e){
      setMsg("marketplaceMsg",e?.message||String(e));
      return null;
    }finally{
      if(button){button.disabled=false;button.textContent="Initialize License Manager";}
      reportSize();
    }
  }

'''
    s=s.replace(fn_anchor,init_fn+fn_anchor,1)

    render_anchor='      renderMarketplaceSubscription(Boolean(r.active),null,r);'
    if render_anchor not in s:
        raise SystemExit("PATCH ERROR: subscription render call anchor missing")
    s=s.replace(render_anchor,render_anchor+'''
      const lmInitNeeded=Array.isArray(r?.licenseEvidence?.errors)
        && r.licenseEvidence.errors.some(e=>/service role not found/i.test(String(e)));
      $("initializeMarketplaceLicenseManager")?.classList.toggle("hidden",!lmInitNeeded);''',1)

    bind_anchor='  $("checkMarketplace").addEventListener("click",checkMarketplaceSubscription);'
    if bind_anchor not in s:
        raise SystemExit("PATCH ERROR: checkMarketplace listener anchor missing")
    s=s.replace(bind_anchor,bind_anchor+'\n  $("initializeMarketplaceLicenseManager").addEventListener("click",initializeMarketplaceLicenseManagerV79R4);',1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.79"',s)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                 'ui://vodia/msp-guided/v0.14.9.79/mcp-app.html',s,count=1)
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

echo "[3/9] Validate staged JavaScript"
node --check "$TMP/staged/license-init.mjs" >/dev/null || fail "license-init helper JavaScript invalid"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null || fail "backend JavaScript invalid"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null || fail "guided resource JavaScript invalid"
node --check "$TMP/staged/version.js" >/dev/null || fail "version JavaScript invalid"

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline.js" >/dev/null || fail "guided UI inline JavaScript invalid"

for marker in \
  'VODIA_LICENSE_MANAGER_INIT_BACKEND_V79_R4' \
  'aws_license_manager_initialize' \
  'initializeLicenseManagerServiceRole' \
  'INITIALIZE AWS LICENSE MANAGER'; do
  grep -Fq "$marker" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend marker missing: $marker"
done
for marker in \
  'VODIA_LICENSE_MANAGER_INIT_UI_V79_R4' \
  'initializeMarketplaceLicenseManager' \
  'Initialize License Manager' \
  'service role not found'; do
  grep -Fiq "$marker" "$TMP/staged/msp-guided-app.html" || fail "UI marker missing: $marker"
done
echo "PASS: r4 backend/helper/UI staged successfully"

echo "[4/9] Dry-run dependency report"
echo "Marketplace helper package: $MARKET"
echo "Existing License Manager SDK: @aws-sdk/client-license-manager@$LM_SDK_VERSION"
if [[ "$IAM_WAS_PRESENT" == "1" ]]; then
  echo "IAM SDK: already installed"
else
  echo "IAM SDK: live install will add @aws-sdk/client-iam@$LM_SDK_VERSION"
fi

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.79-r4 staged patch validated successfully."
  echo "DRY RUN: no npm package installed, no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/9] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$PKG" "$BACKUP_DIR/package.json"
cp -a "$LOCK" "$BACKUP_DIR/package-lock.json"
[[ -f "$LICENSE_INIT" ]] && cp -a "$LICENSE_INIT" "$BACKUP_DIR/license-init.mjs.preexisting"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-r4 state"
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/package.json" "$PKG" || true
  cp -a "$BACKUP_DIR/package-lock.json" "$LOCK" || true
  if [[ -f "$BACKUP_DIR/license-init.mjs.preexisting" ]]; then
    cp -a "$BACKUP_DIR/license-init.mjs.preexisting" "$LICENSE_INIT" || true
  else
    rm -f "$LICENSE_INIT" || true
  fi
  if [[ "$IAM_WAS_PRESENT" != "1" ]]; then
    rm -rf "$MARKET/node_modules/@aws-sdk/client-iam" || true
  fi
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/9] Install IAM SDK in marketplace-v76"
if [[ "$IAM_WAS_PRESENT" != "1" ]]; then
  (cd "$MARKET" && npm install --save-exact --ignore-scripts --no-audit --no-fund "@aws-sdk/client-iam@$LM_SDK_VERSION")
fi
(cd "$MARKET" && node --input-type=module -e 'await import("@aws-sdk/client-iam"); console.log("PASS: @aws-sdk/client-iam import works from marketplace-v76")')

echo "[7/9] Install staged MCP files + restart"
install -o root -g root -m 0644 "$TMP/staged/license-init.mjs" "$LICENSE_INIT"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[8/9] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.79"' <<<"$HEALTH" || fail "health does not report v0.14.9.79"
echo "$HEALTH"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_BACKEND_V79_R4' "$BACKEND" || fail "live backend marker missing"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_UI_V79_R4' "$UI" || fail "live UI marker missing"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_HELPER_V79_R4' "$LICENSE_INIT" || fail "live helper marker missing"
echo "PASS: live r4 markers present"

echo "[9/9] Complete"
echo "PASS: Vodia MCP v0.14.9.79-r4 installed."
echo "PASS: License Manager initialization is a separate, explicitly confirmed write action."
echo "PASS: initialization uses the connected customer deployment role credentials."
echo "PASS: existing aws_marketplace_check_subscription remains read-only."
echo "PASS: Initialize License Manager button is shown only when the exact service-role-missing error is returned."
echo "Backup: $BACKUP_DIR"
