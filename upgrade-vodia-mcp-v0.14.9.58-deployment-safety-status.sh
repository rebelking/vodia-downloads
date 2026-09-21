#!/usr/bin/env bash
# Vodia MCP v0.14.9.58 — duplicate EC2 protection + automatic deployment status polling
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.58"
SOURCE_COMMIT="55ba6de43693b39e3664d8d662b1bc4f5169d347"
RAW="https://raw.githubusercontent.com/rebelking/vodia-downloads/$SOURCE_COMMIT"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-deployment-safety-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl wget; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
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
  0.14.9.57) ;;
  0.14.9.58) echo "v0.14.9.58 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.57; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — deployment safety/status ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"
wget -qO "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$RAW/aws-marketplace-ec2-deploy-v1.js"

echo "[1/7] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

listener='$("applyDeployment").addEventListener("click",async()=>{'
if listener not in s:
    raise SystemExit("PATCH ERROR: applyDeployment listener anchor missing")

helper=r'''
  const deploymentPollDelay=(ms)=>new Promise(resolve=>setTimeout(resolve,ms));

  function renderDeploymentStatus(status){
    const state=status?.state||"pending";
    $("planSummary").textContent=[
      state==="running" ? "Vodia PBX is running" : "Deployment status",
      "Instance ID: "+(status?.instanceId||"pending"),
      "State: "+state,
      "Region: "+(status?.region||selectedRegion||""),
      "Public IP: "+(status?.publicIpAddress||"pending"),
      "Public DNS: "+(status?.publicDnsName||"pending"),
      "Instance type: "+(status?.instanceType||"pending"),
      "AMI: "+(status?.imageId||"pending")
    ].join("\n");
    $("planSummary").classList.remove("hidden");
  }

  async function pollDeploymentStatus(launchResult){
    const instanceId=launchResult?.instanceId;
    const region=launchResult?.region||selectedRegion;
    const id=customerId();
    if(!instanceId||!region||!id) return;

    renderDeploymentStatus(launchResult);
    for(let attempt=0;attempt<24;attempt++){
      if(attempt>0) await deploymentPollDelay(5000);
      try{
        const status=dataFrom(await callTool("aws_get_vodia_pbx_deployment_status",{
          customerId:id,
          region,
          instanceId
        }));
        renderDeploymentStatus({...launchResult,...status,region});
        const state=String(status?.state||"").toLowerCase();
        if(state==="running"){
          setMsg("deployMsg","Vodia PBX is running. Public network details are shown above.");
          return;
        }
        if(["stopped","shutting-down","terminated"].includes(state)){
          setMsg("deployMsg","Vodia PBX deployment reached state: "+state+".");
          return;
        }
        setMsg("deployMsg","Deployment is "+(state||"pending")+" — waiting for AWS network details…");
      }catch(e){
        setMsg("deployMsg","Instance launched, but automatic status refresh failed: "+e.message);
        return;
      }finally{
        reportSize();
      }
    }
    setMsg("deployMsg","Instance launched. AWS is still starting it; use Refresh or deployment status to check again.");
  }

'''
if 'function pollDeploymentStatus(launchResult)' not in s:
    s=s.replace(listener,helper+listener,1)

success='setMsg("deployMsg","Vodia PBX deployment started successfully.");'
if success not in s:
    raise SystemExit("PATCH ERROR: deployment success message anchor missing")
if 'await pollDeploymentStatus(result);' not in s:
    s=s.replace(success,success+'\n      await pollDeploymentStatus(result);',1)

if 'data-deployment-safety="v0.14.9.58"' not in s:
    s=s.replace('data-inline-js-repair="v0.14.9.57"',
                'data-inline-js-repair="v0.14.9.57" data-deployment-safety="v0.14.9.58"',1)

s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.18.2"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.58/mcp-app.html',s,count=1)
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

echo "[2/7] Validate backend duplicate protection"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'const deploymentLocks = new Set();' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "deployment lock missing"
grep -Fq 'DUPLICATE_DEPLOYMENT_BLOCKED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "duplicate-instance guard missing"
grep -Fq 'ClientToken: clientToken' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "EC2 idempotency token missing"
grep -Fq 'findExistingManagedInstance' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "existing-instance check missing"
echo "PASS: duplicate-launch protection present"

echo "[3/7] Validate guided UI JavaScript"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline-app.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
print("Extracted inline script for syntax validation.")
PY
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided app inline JavaScript invalid"
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling missing"
grep -Fq 'aws_get_vodia_pbx_deployment_status' "$TMP/staged/msp-guided-app.html" || fail "status tool call missing"
grep -Fq 'data-deployment-safety="v0.14.9.58"' "$TMP/staged/msp-guided-app.html" || fail "UI marker missing"
echo "PASS: automatic deployment status polling present"

echo "[4/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.key ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.key "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.57 files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[5/7] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[6/7] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.58"' <<<"$HEALTH" || fail "health does not report v0.14.9.58"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.58 installed"
echo "PASS: Duplicate VodiaMCP PBX names are blocked before planning and again before launch."
echo "PASS: Concurrent/repeated apply calls are guarded and RunInstances uses an EC2 ClientToken."
echo "PASS: Setup automatically polls AWS after launch and displays running state, public IP, and DNS."
echo "NOTE: Existing instances are NOT changed or terminated by this installer."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.58 UI resource."
