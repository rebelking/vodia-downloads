#!/usr/bin/env bash
# Vodia MCP v0.14.9.79 — one-click AWS License Manager initialization
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.79"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-license-manager-init-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do
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

echo "=== Vodia MCP v$TO_VER — AWS License Manager one-click initialization ==="

echo "[0/8] Dependency preflight — NO LIVE CHANGES"
command -v npm >/dev/null 2>&1 || fail "npm is required"

if (cd "$APP" && node --input-type=module -e 'await import("@aws-sdk/client-license-manager"); console.log("PASS: @aws-sdk/client-license-manager import works")'); then
  :
else
  fail "@aws-sdk/client-license-manager cannot be imported by Node from $APP. No files were changed."
fi

LM_SDK_VERSION="$(cd "$APP" && node --input-type=module <<'NODE' 2>/dev/null || true
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
const resolved=import.meta.resolve("@aws-sdk/client-license-manager");
let dir=path.dirname(fileURLToPath(resolved));
for(let i=0;i<12;i++){
  const pkg=path.join(dir,"package.json");
  if(fs.existsSync(pkg)){
    const j=JSON.parse(fs.readFileSync(pkg,"utf8"));
    if(j.name==="@aws-sdk/client-license-manager"){
      process.stdout.write(String(j.version||""));
      process.exit(0);
    }
  }
  const parent=path.dirname(dir);
  if(parent===dir) break;
  dir=parent;
}
process.exit(2);
NODE
)"
if [[ -n "$LM_SDK_VERSION" ]]; then
  echo "PASS: detected @aws-sdk/client-license-manager@$LM_SDK_VERSION"
else
  echo "WARN: could not determine License Manager SDK version; exact version matching will not be required"
fi

if (cd "$APP" && node --input-type=module -e 'await import("@aws-sdk/client-iam")' >/dev/null 2>&1); then
  IAM_SDK_PRESENT=1
  IAM_INSTALL_SPEC=""
  echo "PASS: @aws-sdk/client-iam already installed"
else
  IAM_SDK_PRESENT=0
  if [[ -n "$LM_SDK_VERSION" ]] && npm view "@aws-sdk/client-iam@$LM_SDK_VERSION" version >/dev/null 2>&1; then
    IAM_INSTALL_SPEC="@aws-sdk/client-iam@$LM_SDK_VERSION"
    echo "INFO: @aws-sdk/client-iam is not installed"
    echo "PASS: matching $IAM_INSTALL_SPEC is available from npm"
  else
    IAM_LATEST_VERSION="$(npm view @aws-sdk/client-iam version 2>/dev/null || true)"
    [[ -n "$IAM_LATEST_VERSION" ]] || fail "@aws-sdk/client-iam could not be resolved from npm. No files were changed."
    IAM_INSTALL_SPEC="@aws-sdk/client-iam@$IAM_LATEST_VERSION"
    echo "INFO: @aws-sdk/client-iam is not installed"
    echo "PASS: $IAM_INSTALL_SPEC is available from npm"
  fi
  echo "INFO: live install will add $IAM_INSTALL_SPEC"
fi

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

if '@aws-sdk/client-iam' not in s:
    lm=re.search(r'import\s*\{(?P<body>.*?)\}\s*from\s*["\']@aws-sdk/client-license-manager["\'];?',s,re.S)
    if not lm:
        raise SystemExit("PATCH ERROR: License Manager import anchor missing")
    add='''\nimport {
  IAMClient,
  CreateServiceLinkedRoleCommand
} from "@aws-sdk/client-iam";'''
    s=s[:lm.end()]+add+s[lm.end():]

marker='const VODIA_LICENSE_EVIDENCE_V77 = true;'
if marker not in s:
    raise SystemExit("PATCH ERROR: v77 License Manager evidence marker missing")

if 'VODIA_LICENSE_MANAGER_INIT_V79' not in s:
    helpers=r'''
const VODIA_LICENSE_MANAGER_INIT_V79 = true;
const LICENSE_MANAGER_SERVICE_NAME_V79 = "license-manager.amazonaws.com";
const LICENSE_MANAGER_CONFIRM_V79 = "INITIALIZE AWS LICENSE MANAGER";

function isLicenseManagerServiceRoleMissingV79(error) {
  const message=String(error?.message || error || "");
  return /service role not found/i.test(message);
}

function isLicenseManagerServiceLinkedRoleAlreadyExistsV79(error) {
  const name=String(error?.name || "");
  const message=String(error?.message || error || "");
  return name==="EntityAlreadyExistsException" ||
    /already exists|has been taken/i.test(message);
}

async function initializeLicenseManagerServiceRoleV79(roleArn,externalId) {
  const client=new IAMClient({
    region:"us-east-1",
    credentials:customerCredentials(roleArn,externalId)
  });
  try {
    const out=await client.send(new CreateServiceLinkedRoleCommand({
      AWSServiceName:LICENSE_MANAGER_SERVICE_NAME_V79,
      Description:"Required AWS License Manager service-linked role for Vodia Marketplace license inspection."
    }));
    return {
      created:true,
      alreadyExisted:false,
      roleName:out?.Role?.RoleName || "AWSServiceRoleForAWSLicenseManagerRole",
      roleArn:out?.Role?.Arn || null
    };
  } catch(error) {
    if (isLicenseManagerServiceLinkedRoleAlreadyExistsV79(error)) {
      return {
        created:false,
        alreadyExisted:true,
        roleName:"AWSServiceRoleForAWSLicenseManagerRole",
        roleArn:null
      };
    }
    throw error;
  }
}

function licenseManagerInitializationRequiredEvidenceV79(error,region) {
  return {
    status:"INITIALIZATION_REQUIRED",
    checkedAt:new Date().toISOString(),
    region,
    receivedLicenseCount:0,
    vodiaCandidateCount:0,
    licenses:[],
    vodiaCandidates:[],
    detailErrors:[],
    directMappingEvidence:[],
    agreementToLicenseMappingVerified:false,
    deploymentCapacityVerified:false,
    initialization:{
      required:true,
      serviceName:LICENSE_MANAGER_SERVICE_NAME_V79,
      roleName:"AWSServiceRoleForAWSLicenseManagerRole",
      exactConfirmation:LICENSE_MANAGER_CONFIRM_V79
    },
    errors:[String(error?.message || error)],
    explanation:"AWS License Manager requires a one-time service-linked role initialization. This does not determine deployable PBX capacity."
  };
}

async function inspectVodiaLicenseEvidenceWithRetryV79(roleArn,externalId,productId=null) {
  let last=null;
  for (let attempt=0; attempt<5; attempt++) {
    if (attempt>0) await new Promise(resolve=>setTimeout(resolve,1000*(attempt+1)));
    last=await inspectVodiaLicenseEvidenceV77(roleArn,externalId,productId);
    if (last?.status!=="INITIALIZATION_REQUIRED") return last;
  }
  return last;
}
'''
    s=s.replace(marker,marker+helpers,1)

old=r'''  const summaries=[];
  let nextToken;
  do {
    const out=await client.send(new ListReceivedLicensesCommand({
      NextToken:nextToken,
      MaxResults:100
    }));
    summaries.push(...(out.Licenses || []));
    nextToken=out.NextToken;
  } while(nextToken && summaries.length<500);
'''
new=r'''  const summaries=[];
  let nextToken;
  try {
    do {
      const out=await client.send(new ListReceivedLicensesCommand({
        NextToken:nextToken,
        MaxResults:100
      }));
      summaries.push(...(out.Licenses || []));
      nextToken=out.NextToken;
    } while(nextToken && summaries.length<500);
  } catch(error) {
    if (isLicenseManagerServiceRoleMissingV79(error)) {
      return licenseManagerInitializationRequiredEvidenceV79(error,region);
    }
    throw error;
  }
'''
if old in s:
    s=s.replace(old,new,1)
elif 'licenseManagerInitializationRequiredEvidenceV79(error,region)' not in s:
    raise SystemExit("PATCH ERROR: ListReceivedLicenses loop anchor missing")

tool_anchor='''  server.registerTool(
    "aws_marketplace_inspect_vodia_license_evidence",'''
if 'aws_license_manager_initialize' not in s:
    if tool_anchor not in s:
        raise SystemExit("PATCH ERROR: license evidence tool anchor missing")
    init_tool=r'''  server.registerTool(
    "aws_license_manager_initialize",
    {
      title: "Initialize AWS License Manager",
      description: "Creates the AWS License Manager service-linked role in the connected customer AWS account, then retries the read-only Vodia license evidence check. Requires exact confirmation.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3).optional(),
        confirm: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:false, destructiveHint:false, openWorldHint:true }
    },
    async (input, extra) => {
      scopedAudit("aws_license_manager_initialize",{
        customerId:input.customerId||null,
        productId:input.productId||null
      });
      try {
        if (input.confirm!==LICENSE_MANAGER_CONFIRM_V79) {
          throw new Error("CONFIRMATION_REQUIRED: use exact phrase "+LICENSE_MANAGER_CONFIRM_V79);
        }
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN"]);
        const init=await initializeLicenseManagerServiceRoleV79(c.roleArn,c.externalId);
        const evidence=await inspectVodiaLicenseEvidenceWithRetryV79(
          c.roleArn,c.externalId,input.productId||null
        );
        if (evidence?.status==="INITIALIZATION_REQUIRED") {
          throw new Error("LICENSE_MANAGER_INITIALIZATION_PENDING: AWS accepted the service-linked role request but License Manager is not ready yet. Retry the license check shortly.");
        }
        return scopedSuccess({
          initialized:true,
          initialization:init,
          evidence,
          customerId:c.customerId||null,
          changesMade:Boolean(init?.created)
        }, {
          operation:"AWS_LICENSE_MANAGER_INITIALIZE",
          readOnly:false
        }, init?.created
          ? "AWS License Manager service-linked role created and license evidence check retried."
          : "AWS License Manager service-linked role already existed; license evidence check retried.");
      } catch(error) {
        return failure(error,"AWS License Manager initialization");
      }
    }
  );

'''
    s=s.replace(tool_anchor,init_tool+tool_anchor,1)

p.write_text(s)
PY

echo "[2/8] Patch staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_LICENSE_MANAGER_INIT_UI_V79' not in s:
    marker='const VODIA_LICENSE_EVIDENCE_UI_V77 = true;'
    if marker not in s:
        raise SystemExit("PATCH ERROR: v77 License Manager UI marker missing")
    s=s.replace(marker,marker+'\n  const VODIA_LICENSE_MANAGER_INIT_UI_V79 = true;',1)

    button='<button id="refreshMarketplaceLicenseEvidence" class="secondary" type="button">Inspect license evidence</button>'
    if button not in s:
        raise SystemExit("PATCH ERROR: license refresh button anchor missing")
    s=s.replace(button,button+'''
              <button id="initializeMarketplaceLicenseManager" class="secondary hidden" type="button">Initialize License Manager</button>''',1)

    anchor='''    const status=evidence.status||((errors.length)?"UNKNOWN":"READABLE");
    badge.textContent=status;
'''
    if anchor not in s:
        raise SystemExit("PATCH ERROR: license renderer status anchor missing")
    s=s.replace(anchor,'''    const status=evidence.status||((errors.length)?"UNKNOWN":"READABLE");
    badge.textContent=status;
    const initButton=$("initializeMarketplaceLicenseManager");
    if(initButton) initButton.classList.toggle("hidden",status!=="INITIALIZATION_REQUIRED");
''',1)

    lines_anchor='''      evidence.agreementToLicenseMappingVerified!==undefined
        ?("Agreement-to-license mapping: "+(evidence.agreementToLicenseMappingVerified?"DIRECT EVIDENCE FOUND":"NOT VERIFIED")):null,
      "Deployable PBX capacity: "+(evidence.deploymentCapacityVerified?"VERIFIED":"NOT VERIFIED")
'''
    if lines_anchor not in s:
        raise SystemExit("PATCH ERROR: license renderer lines anchor missing")
    s=s.replace(lines_anchor,'''      evidence.agreementToLicenseMappingVerified!==undefined
        ?("Agreement-to-license mapping: "+(evidence.agreementToLicenseMappingVerified?"DIRECT EVIDENCE FOUND":"NOT VERIFIED")):null,
      status==="INITIALIZATION_REQUIRED"?"AWS License Manager requires one-time initialization.":null,
      status==="INITIALIZATION_REQUIRED"?"Role: AWSServiceRoleForAWSLicenseManagerRole":null,
      "Deployable PBX capacity: "+(evidence.deploymentCapacityVerified?"VERIFIED":"NOT VERIFIED")
''',1)

    fn_anchor='''  async function inspectMarketplaceLicenseEvidenceV77(manual=false){'''
    if fn_anchor not in s:
        raise SystemExit("PATCH ERROR: license inspection function anchor missing")
    funcs=r'''  async function initializeMarketplaceLicenseManagerV79(){
    const id=customerId();
    if(!id) return null;
    const button=$("initializeMarketplaceLicenseManager");
    const ok=window.confirm(
      "Initialize AWS License Manager for this customer account?\n\n"+
      "This creates AWSServiceRoleForAWSLicenseManagerRole using the connected VodiaMCPDeploymentRole. "+
      "It does not purchase anything, launch EC2, or change the Marketplace agreement."
    );
    if(!ok) return null;
    try{
      if(button){button.disabled=true;button.textContent="Initializing…";}
      setMsg("marketplaceMsg","Initializing AWS License Manager…");
      const raw=await callTool("aws_license_manager_initialize",{
        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID,
        confirm:"INITIALIZE AWS LICENSE MANAGER"
      });
      if(raw?.isError) throw new Error(toolErrorText(raw)||"License Manager initialization failed.");
      const data=dataFrom(raw);
      const evidence=data?.evidence||null;
      if(evidence) renderMarketplaceLicenseEvidenceV77(evidence);
      setMsg("marketplaceMsg","AWS License Manager initialized. License evidence check completed.");
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
    s=s.replace(fn_anchor,funcs+fn_anchor,1)

    bind='''  $("refreshMarketplaceLicenseEvidence").addEventListener("click",()=>inspectMarketplaceLicenseEvidenceV77(true));'''
    if bind not in s:
        raise SystemExit("PATCH ERROR: license evidence listener anchor missing")
    s=s.replace(bind,bind+'\n  $("initializeMarketplaceLicenseManager").addEventListener("click",initializeMarketplaceLicenseManagerV79);',1)

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

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null || fail "backend JavaScript invalid"
for marker in \
  'VODIA_LICENSE_MANAGER_INIT_V79' \
  'CreateServiceLinkedRoleCommand' \
  'aws_license_manager_initialize' \
  'INITIALIZATION_REQUIRED' \
  'INITIALIZE AWS LICENSE MANAGER'; do
  grep -Fq "$marker" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend marker missing: $marker"
done
echo "PASS: License Manager initializer staged"

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
for marker in \
  'VODIA_LICENSE_MANAGER_INIT_UI_V79' \
  'initializeMarketplaceLicenseManager' \
  'Initialize License Manager' \
  'INITIALIZATION_REQUIRED'; do
  grep -Fq "$marker" "$TMP/staged/msp-guided-app.html" || fail "UI marker missing: $marker"
done
echo "PASS: License Manager initialization UI staged"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.79 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  if [[ "$IAM_SDK_PRESENT" == "1" ]]; then
    echo "DRY RUN: @aws-sdk/client-iam is already installed."
  else
    echo "DRY RUN: live install will add $IAM_INSTALL_SPEC; no dependency was installed during dry run."
  fi
  exit 0
fi

echo "[5/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f "$APP/package.json" ]] && cp -a "$APP/package.json" "$BACKUP_DIR/package.json"
[[ -f "$APP/package-lock.json" ]] && cp -a "$APP/package-lock.json" "$BACKUP_DIR/package-lock.json"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v79 files"
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  [[ -f "$BACKUP_DIR/package.json" ]] && cp -a "$BACKUP_DIR/package.json" "$APP/package.json" || true
  [[ -f "$BACKUP_DIR/package-lock.json" ]] && cp -a "$BACKUP_DIR/package-lock.json" "$APP/package-lock.json" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[6/8] Install dependency + files + restart"
if [[ "$IAM_SDK_PRESENT" != "1" ]]; then
  echo "Installing $IAM_INSTALL_SPEC"
  (cd "$APP" && npm install --save-exact "$IAM_INSTALL_SPEC")
fi
(cd "$APP" && node --input-type=module -e 'await import("@aws-sdk/client-iam"); console.log("PASS: @aws-sdk/client-iam import works")')
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
grep -q '"version":"0.14.9.79"' <<<"$HEALTH" || fail "health does not report v0.14.9.79"
echo "$HEALTH"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_V79' "$BACKEND" || fail "live v79 backend marker missing"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_UI_V79' "$UI" || fail "live v79 UI marker missing"
echo "PASS: live v79 markers present"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.79 installed."
echo "PASS: missing AWS License Manager service-linked role is reported as INITIALIZATION_REQUIRED."
echo "PASS: initialization uses the connected customer VodiaMCPDeploymentRole, not the MCP host role."
echo "PASS: initialization requires explicit UI confirmation and only creates the License Manager service-linked role."
echo "PASS: after initialization, the MCP retries the read-only license evidence check."
echo "Backup: $BACKUP_DIR"
