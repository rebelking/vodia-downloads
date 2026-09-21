#!/usr/bin/env bash
# Vodia MCP v0.14.9.63 — live Review & Deploy parity + configure cleanup
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.63"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-review-parity-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.62) ;;
  0.14.9.63) echo "v0.14.9.63 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.62; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — live Review & Deploy parity ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/6] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Clean obsolete controls from the consolidated Configure EC2 step.
helper_anchor='''    const configure=$("awsStepPanel");
    if(configure){'''
if helper_anchor not in s:
    raise SystemExit("PATCH ERROR: consolidated configure helper missing")

cleanup='''    const configure=$("awsStepPanel");
    if(configure){
      const legacyBack=$("backToCustomer");
      const legacyContinue=$("continueDeploy");
      const legacyBackDeploy=$("backToAws");
      if(legacyBack) legacyBack.classList.add("hidden");
      if(legacyContinue) legacyContinue.classList.add("hidden");
      if(legacyBackDeploy) legacyBackDeploy.classList.add("hidden");'''
s=s.replace(helper_anchor,cleanup,1)

# One network/options button with clear wording.
s=s.replace('load.textContent="Load AWS network";','load.textContent="Load EC2 options";')
s=s.replace('$("loadNetwork").textContent="Load AWS network";',
            '$("loadNetwork").textContent=currentNetwork?"Reload EC2 options":"Load EC2 options";')

# Configure action labels.
s=s.replace('back.textContent="Back";','back.textContent="Back to Marketplace";',1)
s=s.replace('>Validate &amp; Create Plan</button>',
            '>Validate &amp; Create Plan</button>',1)

# Strengthen Review & Deploy summary to mirror the replica but use real data.
plan_summary_old='''      $("planSummary").textContent=[
        "Plan validated — no instance launched",'''
if plan_summary_old not in s:
    raise SystemExit("PATCH ERROR: plan summary anchor missing")
plan_summary_new='''      const selectedAgreementId=
        plan.selectedAgreement?.agreementId||
        $("marketplaceAgreementSelect")?.value||
        currentMarketplaceSubscription?.agreements?.[0]?.agreementId||
        "verified";
      $("planSummary").textContent=[
        "Plan validated — no instance launched",
        "Marketplace agreement: "+selectedAgreementId,''';
s=s.replace(plan_summary_old,plan_summary_new,1)

# Review step should clearly state that no instance has launched yet.
review_msg='''      setMsg("deployMsg","DryRun passed. Review the plan and enter the exact approval to launch EC2.");
      setStep(4);'''
review_msg_new='''      setMsg("deployMsg","DryRun passed. No EC2 instance has been launched. Enter the exact approval below to deploy.");
      $("deploymentApproval").focus();
      setStep(4);'''
if review_msg in s:
    s=s.replace(review_msg,review_msg_new,1)

# Exact approval feedback remains explicit.
if 'Approval matches. Ready to deploy.' not in s:
    raise SystemExit("PATCH ERROR: approval feedback regression")

# Improve live status card wording and preserve selected agreement.
status_anchor='''      "Marketplace agreement: "+(status?.agreementId||"verified"),
      "Public IP: "+(status?.publicIpAddress||"pending"),'''
status_new='''      "Marketplace agreement: "+(
        status?.agreementId||
        launchResult?.agreementId||
        $("marketplaceAgreementSelect")?.value||
        "verified"
      ),
      "Public IP: "+(status?.publicIpAddress||"pending"),'''
if status_anchor in s:
    s=s.replace(status_anchor,status_new,1)

# Once a real launch begins, prevent another click while polling.
launch_success='''      $("approvalBox").classList.add("hidden");
      setMsg("deployMsg","Vodia PBX deployment started successfully.");'''
launch_success_new='''      $("approvalBox").classList.add("hidden");
      $("applyDeployment").disabled=true;
      setMsg("deployMsg","Vodia PBX deployment started successfully. Waiting for AWS to report running state and public network details…");'''
if launch_success in s:
    s=s.replace(launch_success,launch_success_new,1)

# Only re-enable deploy after errors; after successful launch, approvalBox is hidden.
finally_old='''    }finally{
      $("applyDeployment").disabled=false;
      $("applyDeployment").textContent="Deploy Vodia PBX";
      reportSize();
    }
  });'''
finally_new='''    }finally{
      if(!$("approvalBox").classList.contains("hidden")){
        $("applyDeployment").disabled=$("deploymentApproval").value.trim()!==resolvedDeploymentPlan()?.confirmation;
      }
      $("applyDeployment").textContent="Deploy Vodia PBX";
      reportSize();
    }
  });'''
if finally_old in s:
    s=s.replace(finally_old,finally_new,1)

# Better success copy after polling.
s=s.replace(
  'setMsg("deployMsg","Vodia PBX is running. Public network details are shown above.");',
  'setMsg("deployMsg","Vodia PBX is running. The real AWS instance ID, public IP, and public DNS are shown above.");'
)

# Review panel title/copy.
s=s.replace(
  '<p>Review the validated deployment plan, enter the exact approval, then launch.</p>',
  '<p>Review the validated Marketplace-backed EC2 plan. Deployment occurs only after the exact approval is entered.</p>',
  1
)

# Marker/version.
if 'data-review-parity="v0.14.9.63"' not in s:
    s=s.replace('data-validate-button-fix="v0.14.9.62"',
                'data-validate-button-fix="v0.14.9.62" data-review-parity="v0.14.9.63"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.21.2"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.63/mcp-app.html',s,count=1)
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

echo "[2/6] Validate staged UI"
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
grep -Fq 'Marketplace agreement: "+selectedAgreementId' "$TMP/staged/msp-guided-app.html" || fail "review agreement summary missing"
grep -Fq 'No EC2 instance has been launched.' "$TMP/staged/msp-guided-app.html" || fail "review safety copy missing"
grep -Fq 'Load EC2 options' "$TMP/staged/msp-guided-app.html" || fail "configure button cleanup missing"
grep -Fq 'The real AWS instance ID, public IP, and public DNS are shown above.' "$TMP/staged/msp-guided-app.html" || fail "live success copy missing"
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling regression"
grep -Fq 'rawPlanResult?.isError' "$TMP/staged/msp-guided-app.html" || fail "planner error propagation regression"
grep -Fq 'data-review-parity="v0.14.9.63"' "$TMP/staged/msp-guided-app.html" || fail "version marker missing"
echo "PASS: live Review & Deploy parity present"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.62 UI files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/6] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.63"' <<<"$HEALTH" || fail "health does not report v0.14.9.63"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.63 installed"
echo "PASS: Configure EC2 has one clean options-loading path and one plan-validation action."
echo "PASS: Review & Deploy mirrors the replica flow but uses real AWS/Marketplace data."
echo "PASS: Exact approval remains mandatory before a real EC2 launch."
echo "PASS: Successful launch polls AWS and displays the real instance ID, public IP, DNS, and agreement."
echo "PASS: Duplicate launch protection and planner error propagation are retained."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.63 UI resource."
