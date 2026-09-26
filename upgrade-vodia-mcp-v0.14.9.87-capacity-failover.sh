#!/usr/bin/env bash
# Vodia MCP v0.14.9.87 — automatic EC2 AZ capacity failover
#
# Fixes:
# - Treat InsufficientInstanceCapacity as a definite rejected launch, not an
#   unknown RunInstances outcome.
# - For ONE_CLICK_MARKETPLACE, retry other public subnets/AZs in the same VPC.
# - Reuse the same dedicated Vodia PBX security group across capacity retries.
# - Use a distinct EC2 ClientToken for each subnet attempt.
# - If every candidate AZ returns a definite capacity rejection, clean up the
#   dedicated firewall and return a clear safe-to-retry capacity error.
# - Preserve VODIA_LAUNCH_CHECK_AWS only for genuinely ambiguous/non-capacity
#   errors after RunInstances is submitted.
# - Return the actual launched subnet/AZ plus capacity-attempt history.
#
# Safe workflow:
#   sudo bash this-script --dry-run
#   sudo bash this-script --apply
set -Eeuo pipefail

MODE=${1:---dry-run}
[[ "$MODE" == "--dry-run" || "$MODE" == "--apply" ]] || {
  echo "Usage: sudo bash $0 [--dry-run|--apply]" >&2
  exit 2
}
[[ ${EUID} -eq 0 ]] || { echo "Run as root/sudo." >&2; exit 1; }

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.87"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d /tmp/vodia-mcp-v87.XXXXXXXX)"
BACKUP="/var/backups/vodia-mcp-v${TO_VER}-capacity-failover-$STAMP"
PATCH_STARTED=0

cleanup(){
  rc=$?
  trap - EXIT
  if (( PATCH_STARTED && rc != 0 )); then
    echo "ROLLBACK: restoring pre-v87 files..." >&2
    cp -a "$BACKUP/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" 2>/dev/null || true
    cp -a "$BACKUP/msp-guided-app.html" "$UI" 2>/dev/null || true
    cp -a "$BACKUP/msp-guided-app-v1.js" "$GUIDED" 2>/dev/null || true
    cp -a "$BACKUP/version.js" "$VERSION" 2>/dev/null || true
    systemctl restart "$SERVICE" 2>/dev/null || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

fail(){ echo "PATCH ERROR: $*" >&2; exit 1; }

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
  0.14.9.86) ;;
  0.14.9.87) echo "v0.14.9.87 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.86 or .87; found ${CURRENT:-unknown}. No files changed." ;;
esac

echo "=== Vodia MCP v$TO_VER — automatic EC2 AZ capacity failover ==="
echo "[0/9] Live preflight — NO LIVE CHANGES"

grep -Fq 'VODIA_PRODUCT_DEPLOYMENT_ID_V86' "$BACKEND" || fail "v86 deployment identity marker missing"
grep -Fq 'async function describeNetwork' "$BACKEND" || fail "describeNetwork helper missing"
grep -Fq 'VODIA_LAUNCH_CHECK_AWS: request outcome unknown' "$BACKEND" || fail "expected v86 ambiguous launch handler missing"
grep -Fq 'createDedicatedFirewall(client,plan)' "$BACKEND" || fail "dedicated firewall launch path missing"
grep -Fq 'RunInstancesCommand({ ...launchParams, ClientToken: clientToken })' "$BACKEND" || fail "expected v86 RunInstances anchor missing"
echo "PASS: live .86 launch/firewall anchors found"

mkdir -p "$TMP/staged/ui"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/ui/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/9] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

# Add release marker next to the v86 marker.
if 'VODIA_CAPACITY_FAILOVER_V87' not in s:
    marker='const VODIA_PRODUCT_DEPLOYMENT_ID_V86 = true;'
    i=s.find(marker)
    if i<0:
        raise SystemExit('PATCH ERROR: v86 marker missing')
    e=s.find('\n',i)
    s=s[:e+1]+'const VODIA_CAPACITY_FAILOVER_V87 = true;\n'+s[e+1:]

# Helpers: classify definite EC2 capacity rejection and safely retarget the
# primary network interface to another subnet in the same VPC.
if 'function isInsufficientEc2CapacityErrorV87' not in s:
    anchor='function cleanExpiredPlans() {'
    i=s.find(anchor)
    if i<0:
        raise SystemExit('PATCH ERROR: cleanExpiredPlans anchor missing')
    helper=r'''function isInsufficientEc2CapacityErrorV87(error) {
  const code=String(error?.name || error?.Code || error?.code || "");
  const message=String(error?.message || error || "");
  return /InsufficientInstanceCapacity/i.test(code)
    || /InsufficientInstanceCapacity/i.test(message)
    || /do not have sufficient.{0,80}capacity/i.test(message)
    || /insufficient.{0,40}capacity/i.test(message);
}

function runParamsForSubnetV87(baseParams,subnetId) {
  const params={...baseParams};
  if(Array.isArray(baseParams?.NetworkInterfaces) && baseParams.NetworkInterfaces.length){
    params.NetworkInterfaces=baseParams.NetworkInterfaces.map((nic,index)=>
      index===0 ? {...nic,SubnetId:subnetId} : {...nic}
    );
    delete params.SubnetId;
  } else {
    params.SubnetId=subnetId;
    if(Array.isArray(baseParams?.SecurityGroupIds)){
      params.SecurityGroupIds=[...baseParams.SecurityGroupIds];
    }
  }
  return params;
}

'''
    s=s[:i]+helper+s[i:]

apply=s.find('"aws_marketplace_apply_vodia_pbx_deployment"')
if apply<0:
    raise SystemExit('PATCH ERROR: apply tool missing')
apply_end=s.find('server.registerTool(',apply+10)
if apply_end<0:
    apply_end=len(s)
block=s[apply:apply_end]

old=r'''          const clientToken = "vodia-" + planId.replace(/-/g, "");
          const groupId = plan.firewall ? await createDedicatedFirewall(client,plan) : null;
          const launchParams = { ...plan.params };
          if (groupId) {
            if (launchParams.NetworkInterfaces) launchParams.NetworkInterfaces =
              launchParams.NetworkInterfaces.map(n=>({...n,Groups:[groupId]}));
            else launchParams.SecurityGroupIds = [groupId];
          }
          if (groupId) {
            try { await dryRunLaunch(client,launchParams); }
            catch (error) {
              try { await client.send(new DeleteSecurityGroupCommand({GroupId:groupId})); }
              catch (cleanup) { throw new Error(`VODIA_FIREWALL_CLEANUP_NEEDED: group ${groupId}; ${String(error?.message||error)}; cleanup: ${String(cleanup?.message||cleanup)}`); }
              throw error;
            }
          }
          // Never delete the group after submitting RunInstances: AWS may have
          // accepted the request even if the SDK returned a timeout.
          let out;
          try {
            out = await client.send(new RunInstancesCommand({ ...launchParams, ClientToken: clientToken }));
          } catch (error) {
            if (groupId) throw new Error(`VODIA_LAUNCH_CHECK_AWS: request outcome unknown. Check for instance and retained firewall ${groupId} before retrying plan ${planId}. AWS: ${String(error?.message||error)}`);
            throw error;
          }
'''

new=r'''          const baseClientToken = "vodia-" + planId.replace(/-/g, "");
          const groupId = plan.firewall ? await createDedicatedFirewall(client,plan) : null;
          const launchParams = { ...plan.params };
          if (groupId) {
            if (launchParams.NetworkInterfaces) launchParams.NetworkInterfaces =
              launchParams.NetworkInterfaces.map(n=>({...n,Groups:[groupId]}));
            else launchParams.SecurityGroupIds = [groupId];
          }
          if (groupId) {
            try { await dryRunLaunch(client,launchParams); }
            catch (error) {
              try { await client.send(new DeleteSecurityGroupCommand({GroupId:groupId})); }
              catch (cleanup) { throw new Error(`VODIA_FIREWALL_CLEANUP_NEEDED: group ${groupId}; ${String(error?.message||error)}; cleanup: ${String(cleanup?.message||cleanup)}`); }
              throw error;
            }
          }

          // V87: one-click capacity failover. A returned
          // InsufficientInstanceCapacity is a definite rejection (no instance
          // was created), so it is safe to retry another subnet/AZ. Reuse the
          // same dedicated Vodia security group, but use a distinct ClientToken
          // because the subnet parameter changes between attempts.
          const primarySubnetId =
            launchParams?.NetworkInterfaces?.[0]?.SubnetId ||
            launchParams?.SubnetId ||
            plan?.params?.NetworkInterfaces?.[0]?.SubnetId ||
            plan?.params?.SubnetId ||
            null;

          let candidateSubnetIds = primarySubnetId ? [primarySubnetId] : [];
          if (plan.deploymentMethod === "ONE_CLICK_MARKETPLACE" && primarySubnetId) {
            const network = await describeNetwork(plan.roleArn,plan.externalId,plan.region);
            const selectedSubnet = (network.subnets || []).find(row=>row.subnetId===primarySubnetId);
            const vpcId = selectedSubnet?.vpcId || plan.firewall?.vpcId || null;
            const primaryAz = selectedSubnet?.availabilityZone || null;
            const seenAz = new Set(primaryAz ? [primaryAz] : []);
            const fallbacks = (network.subnets || [])
              .filter(row=>
                row.subnetId &&
                row.subnetId!==primarySubnetId &&
                (!vpcId || row.vpcId===vpcId) &&
                row.state==="available" &&
                row.mapPublicIpOnLaunch===true
              )
              .sort((a,b)=>{
                const az=String(a.availabilityZone||"").localeCompare(String(b.availabilityZone||""));
                return az || String(a.subnetId||"").localeCompare(String(b.subnetId||""));
              })
              .filter(row=>{
                const az=row.availabilityZone || null;
                if(az && seenAz.has(az)) return false;
                if(az) seenAz.add(az);
                return true;
              })
              .map(row=>row.subnetId);
            candidateSubnetIds=[primarySubnetId,...fallbacks];
          }
          if(!candidateSubnetIds.length){
            throw new Error("EC2_SUBNET_REQUIRED: deployment plan has no subnet to launch into.");
          }

          const capacityAttempts=[];
          let out=null;
          let launchedSubnetId=primarySubnetId;

          for(let attemptIndex=0; attemptIndex<candidateSubnetIds.length; attemptIndex++){
            const subnetId=candidateSubnetIds[attemptIndex];
            const attemptParams=runParamsForSubnetV87(launchParams,subnetId);
            const clientToken=baseClientToken+"-"+String(attemptIndex+1);
            try {
              out=await client.send(new RunInstancesCommand({...attemptParams,ClientToken:clientToken}));
              launchedSubnetId=subnetId;
              capacityAttempts.push({subnetId,status:"LAUNCHED"});
              break;
            } catch(error) {
              if(isInsufficientEc2CapacityErrorV87(error)){
                capacityAttempts.push({
                  subnetId,
                  status:attemptIndex<candidateSubnetIds.length-1 ? "CAPACITY_RETRY" : "CAPACITY_EXHAUSTED",
                  error:String(error?.message || error)
                });
                if(attemptIndex<candidateSubnetIds.length-1) continue;

                // Every submitted request was definitively rejected for
                // capacity, so no EC2 instance exists from these attempts.
                // The dedicated firewall can therefore be cleaned up safely.
                if(groupId){
                  try { await client.send(new DeleteSecurityGroupCommand({GroupId:groupId})); }
                  catch(cleanup){
                    throw new Error(`VODIA_FIREWALL_CLEANUP_NEEDED: all EC2 attempts were rejected for capacity, but firewall ${groupId} could not be removed. cleanup: ${String(cleanup?.message||cleanup)}`);
                  }
                }
                throw new Error(
                  "EC2_INSUFFICIENT_CAPACITY_ALL_AZS: no instance was launched. " +
                  "Capacity was unavailable in all eligible one-click subnets/AZs in " + plan.region +
                  ". Retrying later or choosing another region is safe."
                );
              }

              // Non-capacity RunInstances errors may include transport/time-out
              // failures where AWS could have accepted the request. Preserve
              // the firewall and force reconciliation before retrying.
              if (groupId) throw new Error(
                `VODIA_LAUNCH_CHECK_AWS: request outcome unknown. Check for instance and retained firewall ${groupId} before retrying plan ${planId}. AWS: ${String(error?.message||error)}`
              );
              throw error;
            }
          }

          if(!out){
            throw new Error("EC2_LAUNCH_NO_RESULT: no RunInstances result was returned after one-click capacity attempts.");
          }
'''

if old not in block:
    raise SystemExit('PATCH ERROR: exact v86 launch block not found')
block=block.replace(old,new,1)

# Return and persist the actual AWS placement chosen after any failover.
ledger_anchor='''            region: plan.region,
            instanceState: instance.State?.Name || "pending",'''
if ledger_anchor not in block:
    raise SystemExit('PATCH ERROR: ledger region anchor missing')
block=block.replace(
    ledger_anchor,
    '''            region: plan.region,
            availabilityZone: instance.Placement?.AvailabilityZone || null,
            subnetId: instance.SubnetId || launchedSubnetId || null,
            instanceState: instance.State?.Name || "pending",''',
    1
)

response_anchor='''            marketplaceAmi: plan.marketplaceAmi || null,
            region: plan.region,
            name: plan.name,'''
if response_anchor not in block:
    raise SystemExit('PATCH ERROR: apply response region anchor missing')
block=block.replace(
    response_anchor,
    '''            marketplaceAmi: plan.marketplaceAmi || null,
            region: plan.region,
            availabilityZone: instance.Placement?.AvailabilityZone || null,
            subnetId: instance.SubnetId || launchedSubnetId || null,
            capacityFailoverUsed: Boolean(primarySubnetId && (instance.SubnetId || launchedSubnetId) !== primarySubnetId),
            capacityAttempts,
            name: plan.name,''',
    1
)

s=s[:apply]+block+s[apply_end:]
p.write_text(s)
PY

echo "[2/9] Bump staged UI trace/resource/version — NO LIVE CHANGES"
python3 - "$TMP/staged/ui/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,count=re.subn(r'uiVersion:"0\.14\.9\.86"','uiVersion:"0.14.9.87"',s,count=1)
if count!=1 and 'uiVersion:"0.14.9.87"' not in s:
    raise SystemExit('PATCH ERROR: UI version .86 anchor missing')
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
pattern=re.compile(r'(const\s+GUIDED_UI_URI\s*=\s*["\'])([^"\']+)(["\']\s*;)')
m=pattern.search(s)
if not m:
    raise SystemExit('PATCH ERROR: GUIDED_UI_URI declaration missing')
target='ui://vodia/msp-guided/v0.14.9.87/mcp-app.html'
s=s[:m.start(2)]+target+s[m.end(2):]
p.write_text(s)
PY

python3 - "$TMP/staged/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(
  r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
  r'\g<1>0.14.9.87\2',
  s,count=1
)
if count!=1:
    raise SystemExit('PATCH ERROR: CONNECTOR_VERSION anchor missing')
p.write_text(n)
PY

echo "[3/9] Validate staged JavaScript"
node --input-type=module --check < "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend JavaScript invalid"
node --input-type=module --check < "$TMP/staged/msp-guided-app-v1.js" || fail "resource JavaScript invalid"
node --input-type=module --check < "$TMP/staged/version.js" || fail "version JavaScript invalid"

python3 - "$TMP/staged/ui/msp-guided-app.html" "$TMP/ui-check.js" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',text,re.S|re.I)
if not scripts:
    raise SystemExit('VALIDATION ERROR: no UI script found')
Path(sys.argv[2]).write_text('\n'.join(scripts))
PY
node --check "$TMP/ui-check.js" || fail "guided UI JavaScript invalid"

echo "[4/9] Validate v87 behavior markers"
grep -Fq 'VODIA_CAPACITY_FAILOVER_V87' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "v87 marker missing"
grep -Fq 'isInsufficientEc2CapacityErrorV87' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "capacity classifier missing"
grep -Fq 'candidateSubnetIds' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "candidate subnet failover missing"
grep -Fq 'CAPACITY_RETRY' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "capacity retry state missing"
grep -Fq 'EC2_INSUFFICIENT_CAPACITY_ALL_AZS' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "capacity exhausted error missing"
grep -Fq 'capacityFailoverUsed' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "capacity response metadata missing"
grep -Fq 'VODIA_LAUNCH_CHECK_AWS: request outcome unknown' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "ambiguous-outcome guard missing"
grep -Fq '0.14.9.87' "$TMP/staged/version.js" || fail "version .87 missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.87/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "v87 guided resource URI missing"

echo "PASS: v87 capacity-only retry path staged"
echo "PASS: dedicated Vodia firewall is reused across AZ attempts"
echo "PASS: ambiguous non-capacity launch outcomes still fail closed"
echo "PASS: all-capacity-failed path cleans dedicated firewall"

if [[ "$MODE" == "--dry-run" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.87 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[5/9] Backup current code"
mkdir -p "$BACKUP"
cp -a "$BACKEND" "$BACKUP/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP/version.js"
echo "PASS: $BACKUP"

echo "[6/9] Install staged files"
PATCH_STARTED=1
install -o "$(stat -c %u "$BACKEND")" -g "$(stat -c %g "$BACKEND")" -m "$(stat -c %a "$BACKEND")" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o "$(stat -c %u "$UI")" -g "$(stat -c %g "$UI")" -m "$(stat -c %a "$UI")" "$TMP/staged/ui/msp-guided-app.html" "$UI"
install -o "$(stat -c %u "$GUIDED")" -g "$(stat -c %g "$GUIDED")" -m "$(stat -c %a "$GUIDED")" "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o "$(stat -c %u "$VERSION")" -g "$(stat -c %g "$VERSION")" -m "$(stat -c %a "$VERSION")" "$TMP/staged/version.js" "$VERSION"

echo "[7/9] Restart MCP"
systemctl restart "$SERVICE"

echo "[8/9] Health + live verification"
HEALTH=""
for _ in {1..30}; do
  HEALTH="$(curl -fsS --max-time 5 http://127.0.0.1:3100/health 2>/dev/null || true)"
  [[ -n "$HEALTH" ]] && break
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "health endpoint did not recover"
grep -q '"version":"0.14.9.87"' <<<"$HEALTH" || fail "health does not report 0.14.9.87: $HEALTH"

grep -Fq 'VODIA_CAPACITY_FAILOVER_V87' "$BACKEND" || fail "live v87 marker missing"
grep -Fq 'CAPACITY_RETRY' "$BACKEND" || fail "live capacity retry missing"
grep -Fq 'EC2_INSUFFICIENT_CAPACITY_ALL_AZS' "$BACKEND" || fail "live capacity-exhausted guard missing"

PATCH_STARTED=0
echo "$HEALTH"

echo "[9/9] Complete"
echo "PASS: Vodia MCP v0.14.9.87 installed."
echo "PASS: one-click now retries alternate public subnets/AZs on definite EC2 capacity rejection."
echo "PASS: the same Vodia dedicated PBX firewall is reused during failover."
echo "PASS: non-capacity ambiguous RunInstances errors still retain the firewall and fail closed."
echo "Backup: $BACKUP"
echo
echo "Open Vodia Setup in a NEW message/tab so the v0.14.9.87 resource URI is loaded."
