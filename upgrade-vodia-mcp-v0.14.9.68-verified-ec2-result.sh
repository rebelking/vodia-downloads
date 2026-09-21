#!/usr/bin/env bash
# Vodia MCP v0.14.9.68 — verify the exact EC2 launch result before reporting success
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.68"
V67_COMMIT="234cf5462b7e0927bc653aa6d1e4155325dbbf25"
V67_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${V67_COMMIT}/upgrade-vodia-mcp-v0.14.9.67-marketplace-subscription-usage-r2.sh"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-verified-ec2-result-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

read_version(){
  python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
}

CURRENT="$(read_version)"
case "$CURRENT" in
  0.14.9.64|0.14.9.65|0.14.9.66)
    echo "[prerequisite] Installing cumulative Marketplace/deployment safety v0.14.9.67"
    curl -fsSL "$V67_URL" -o "$TMP/v67.sh"
    bash -n "$TMP/v67.sh"
    chmod +x "$TMP/v67.sh"
    "$TMP/v67.sh"
    CURRENT="$(read_version)"
    ;;
  0.14.9.67) ;;
  0.14.9.68) echo "v0.14.9.68 already installed; verification mode." ;;
  *) fail "expected v0.14.9.64 through .68; found ${CURRENT:-unknown}" ;;
esac
[[ "$CURRENT" == "0.14.9.67" || "$CURRENT" == "0.14.9.68" ]] || fail "v0.14.9.67 prerequisite did not complete"

echo "=== Vodia MCP v${TO_VER} — verified EC2 launch result ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

if [[ "$CURRENT" != "0.14.9.68" ]]; then
  echo "[1/8] Patch staged backend — NO LIVE CHANGES"
  python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_EC2_LAUNCH_VERIFY_V68' in s:
    raise SystemExit(0)

# Add a customer tag to new instance and volume resources. This lets a shared
# MSP AWS account distinguish identical PBX names owned by different customers.
agreement_block='''  if (input.agreementId) {
    tags.push({ Key: "VodiaMarketplaceAgreementId", Value: String(input.agreementId).slice(0, 255) });
  }
'''
if agreement_block not in s:
    raise SystemExit("PATCH ERROR: agreement tag anchor missing")
customer_tag=agreement_block+'''  if (input.customerId) {
    tags.push({ Key: "VodiaMspCustomerId", Value: String(input.customerId).slice(0, 255) });
  }
'''
s=s.replace(agreement_block,customer_tag,1)

# Replace the duplicate lookup. Prefer the exact customer tag, retain legacy
# untagged instances as blockers, and ignore instances tagged to other customers.
start=s.find('async function findExistingManagedInstance(')
end=s.find('\nfunction duplicateDeploymentError(',start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: duplicate lookup boundaries missing")
duplicate_lookup=r'''async function findExistingManagedInstance(client, name, productId, customerId=null) {
  const out = await client.send(new DescribeInstancesCommand({
    Filters: [
      { Name: "tag:ManagedBy", Values: ["VodiaMCP"] },
      { Name: "tag:Name", Values: [name] },
      { Name: "tag:VodiaMarketplaceProductId", Values: [productId] },
      { Name: "instance-state-name", Values: ["pending","running","stopping","stopped"] }
    ]
  }));
  let instances = (out.Reservations || []).flatMap(r => r.Instances || []);
  if (customerId) {
    const exact=[];
    const legacy=[];
    for (const instance of instances) {
      const owner=(instance.Tags || []).find(t => t?.Key === "VodiaMspCustomerId")?.Value || null;
      if (owner === customerId) exact.push(instance);
      else if (!owner) legacy.push(instance);
    }
    instances=[...exact,...legacy];
  }
  instances.sort((a,b) => new Date(b.LaunchTime || 0) - new Date(a.LaunchTime || 0));
  return instances[0] || null;
}
'''
s=s[:start]+duplicate_lookup+s[end:]
s=s.replace('findExistingManagedInstance(client, input.name, input.productId)',
            'findExistingManagedInstance(client, input.name, input.productId, input.customerId || null)')
s=s.replace('findExistingManagedInstance(client, plan.name, plan.productId)',
            'findExistingManagedInstance(client, plan.name, plan.productId, plan.customerId || null)')

# Add strict instance-ID and post-launch AWS verification helpers.
verify_anchor='''async function dryRunLaunch(client, params) {'''
if verify_anchor not in s:
    raise SystemExit("PATCH ERROR: dry-run helper anchor missing")
helpers=r'''const VODIA_EC2_LAUNCH_VERIFY_V68 = true;
const EC2_INSTANCE_ID_PATTERN = /^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/;

const waitForEc2Visibility = (ms) => new Promise(resolve => setTimeout(resolve, ms));

function requiredInstanceTag(instance, key) {
  return (instance?.Tags || []).find(t => t?.Key === key)?.Value || null;
}

async function verifyLaunchedInstance(client, instanceId, expected) {
  if (!EC2_INSTANCE_ID_PATTERN.test(String(instanceId || ""))) {
    throw new Error("EC2_INSTANCE_ID_INVALID: AWS returned an invalid instance ID; deployment result was not accepted.");
  }

  let lastError=null;
  for (let attempt=0;attempt<8;attempt++) {
    if (attempt>0) await waitForEc2Visibility(1000);
    try {
      const out=await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
      const instance=(out.Reservations || []).flatMap(r => r.Instances || [])[0];
      if (!instance) throw new Error("EC2_LAUNCH_NOT_VISIBLE: DescribeInstances returned no instance.");
      if (instance.InstanceId !== instanceId) {
        throw new Error("EC2_INSTANCE_ID_MISMATCH: RunInstances and DescribeInstances returned different IDs.");
      }
      const managedBy=requiredInstanceTag(instance,"ManagedBy");
      const name=requiredInstanceTag(instance,"Name");
      const productId=requiredInstanceTag(instance,"VodiaMarketplaceProductId");
      const agreementId=requiredInstanceTag(instance,"VodiaMarketplaceAgreementId");
      const customerId=requiredInstanceTag(instance,"VodiaMspCustomerId");
      if (managedBy !== "VodiaMCP") throw new Error("EC2_TAG_VERIFICATION_FAILED: ManagedBy tag mismatch.");
      if (name !== expected.name) throw new Error("EC2_TAG_VERIFICATION_FAILED: PBX Name tag mismatch.");
      if (productId !== expected.productId) throw new Error("EC2_TAG_VERIFICATION_FAILED: Marketplace product tag mismatch.");
      if (expected.agreementId && agreementId !== expected.agreementId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: Marketplace agreement tag mismatch.");
      }
      if (expected.customerId && customerId !== expected.customerId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: MSP customer tag mismatch.");
      }
      return instance;
    } catch (error) {
      lastError=error;
      const message=String(error?.message || error);
      const retryable=/InvalidInstanceID\.NotFound|not visible|returned no instance/i.test(message);
      if (!retryable) throw error;
    }
  }
  throw new Error("EC2_LAUNCH_VERIFICATION_TIMEOUT: instance was launched but AWS did not make it visible for verification: "+String(lastError?.message||lastError||"unknown"));
}

'''
s=s.replace(verify_anchor,helpers+verify_anchor,1)

# Replace launch response handling so every success result comes from a fresh
# DescribeInstances response, never from copied or reconstructed text.
launch_start=s.find('          const out = await client.send(new RunInstancesCommand(')
launch_end=s.find('\n          deploymentPlans.delete(planId);',launch_start)
if launch_start<0 or launch_end<0:
    raise SystemExit("PATCH ERROR: apply launch boundaries missing")
old_launch=s[launch_start:launch_end]
run_match=re.search(r'const out = await client\.send\(new RunInstancesCommand\(\{ \.\.\.plan\.params, ClientToken: clientToken \}\)\);',old_launch)
if not run_match:
    raise SystemExit("PATCH ERROR: RunInstances call anchor missing")
new_launch=r'''          const out = await client.send(new RunInstancesCommand({ ...plan.params, ClientToken: clientToken }));
          const launchedInstance = (out.Instances || [])[0];
          const launchedInstanceId = String(launchedInstance?.InstanceId || "");
          if (!launchedInstanceId) throw new Error("EC2_LAUNCH_UNVERIFIED: RunInstances returned no instance ID.");

          const instance = await verifyLaunchedInstance(client, launchedInstanceId, {
            name: plan.name,
            productId: plan.productId,
            agreementId: plan.agreementId || null,
            customerId: plan.customerId || null
          });

          upsertMarketplaceDeployment({
            customerId: plan.customerId || null,
            productId: plan.productId,
            agreementId: plan.agreementId || null,
            instanceId: instance.InstanceId,
            name: plan.name,
            region: plan.region,
            instanceState: instance.State?.Name || "pending",
            publicIpAddress: instance.PublicIpAddress || null,
            publicDnsName: instance.PublicDnsName || null,
            launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : new Date().toISOString(),
            source: "mcp-launch-verified"
          });
'''
s=s[:launch_start]+new_launch+s[launch_end:]

# Make verification explicit in the structured tool result and tighten the
# status-reader schema so malformed IDs never reach AWS.
result_anchor='''            duplicateProtection: true,
            changesMade: true'''
result_new='''            duplicateProtection: true,
            launchVerifiedByDescribeInstances: true,
            instanceIdSource: "DescribeInstances.InstanceId",
            customerTagVerified: Boolean(plan.customerId),
            changesMade: true'''
if result_anchor not in s:
    raise SystemExit("PATCH ERROR: apply result anchor missing")
s=s.replace(result_anchor,result_new,1)

s=s.replace('instanceId: z.string().min(3)',
            'instanceId: z.string().regex(/^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/)',1)

p.write_text(s)
PY

  echo "[2/8] Patch staged guided UI"
  python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'data-verified-ec2-result="v0.14.9.68"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-verified-ec2-result="v0.14.9.68"',1)

summary_anchor='''        "State: "+(result.state||"pending"),
        "Region: "+(result.region||selectedRegion),'''
summary_new='''        "State: "+(result.state||"pending"),
        "AWS verification: "+(result.launchVerifiedByDescribeInstances?"PASSED":"NOT CONFIRMED"),
        "Instance ID source: "+(result.instanceIdSource||"unknown"),
        "Region: "+(result.region||selectedRegion),'''
if summary_anchor not in s:
    raise SystemExit("PATCH ERROR: deployment result summary anchor missing")
s=s.replace(summary_anchor,summary_new,1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"', 'uiVersion:"0.14.9.68"', s)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.26.0"}',s,count=1)
p.write_text(s)
PY

  python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.68/mcp-app.html',s,count=1)
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
fi

echo "[3/8] Validate staged backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'VODIA_EC2_LAUNCH_VERIFY_V68' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "launch verification marker missing"
grep -Fq 'EC2_INSTANCE_ID_PATTERN' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "instance ID validation missing"
grep -Fq 'verifyLaunchedInstance' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "DescribeInstances launch verification missing"
grep -Fq 'launchVerifiedByDescribeInstances: true' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "verified launch result flag missing"
grep -Fq 'VodiaMspCustomerId' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "customer deployment tag missing"
grep -Fq 'DUPLICATE_DEPLOYMENT_BLOCKED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "duplicate guard regression"
grep -Fq 'ClientToken: clientToken' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "EC2 idempotency regression"
grep -Fq 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement reuse guard regression"
echo "PASS: exact instance ID, DescribeInstances verification, customer tags, duplicate protection, and agreement protection present"

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
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided app inline JavaScript invalid"
grep -Fq 'data-verified-ec2-result="v0.14.9.68"' "$TMP/staged/msp-guided-app.html" || fail "UI release marker missing"
grep -Fq 'AWS verification:' "$TMP/staged/msp-guided-app.html" || fail "verified deployment display missing"
grep -Fq 'uiVersion:"0.14.9.68"' "$TMP/staged/msp-guided-app.html" || fail "debug trace version marker missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.68/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "v0.14.9.68 UI URI missing"
echo "PASS: UI reports AWS-verified launch result and retains valid inline JavaScript"

if [[ "$CURRENT" != "0.14.9.68" ]]; then
  echo "[5/8] Backup"
  mkdir -p "$BACKUP_DIR"
  cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
  cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
  cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
  cp -a "$VERSION" "$BACKUP_DIR/version.js"
  [[ -f /var/lib/vodia-mcp/aws-marketplace-deployments.json ]] && cp -a /var/lib/vodia-mcp/aws-marketplace-deployments.json "$BACKUP_DIR/" || true
  echo "PASS: $BACKUP_DIR"

  rollback(){
    echo "ROLLBACK: restoring v0.14.9.67 files"
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
  echo "[5/8]-[6/8] Backup/install skipped"
fi

echo "[7/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.68"' <<<"$HEALTH" || fail "health does not report v0.14.9.68"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.68 installed and verified."
echo "PASS: success is reported only after DescribeInstances returns the exact RunInstances ID."
echo "PASS: instance ID format and Vodia/Marketplace/customer tags are verified."
echo "PASS: duplicate launch, concurrent apply, EC2 ClientToken, and used-agreement guards remain active."
echo "PASS: existing deployments and subscription usage remain visible through the v0.14.9.67 ledger/reconciliation flow."
echo "NOTE: this installer does not stop or terminate any EC2 instances."
[[ -d "$BACKUP_DIR" ]] && echo "Backup: $BACKUP_DIR"
echo
echo "NEXT TEST: open Vodia Setup in a fresh card, confirm the existing subscription/deployment is shown, and do not launch another PBX unless an AVAILABLE agreement exists."
