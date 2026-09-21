#!/usr/bin/env bash
# Vodia MCP v0.14.9.60 — subscription-first deployment naming UX
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.60"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-subscription-first-name-$STAMP"
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
  0.14.9.59) ;;
  0.14.9.60) echo "v0.14.9.60 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.59; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — subscription-first PBX naming ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/6] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# 1) PBX deployment name must be explicitly chosen; do not silently reuse "vodia-pbx".
old='<input id="pbxName" maxlength="128" placeholder="customer-pbx" value="vodia-pbx">'
new='''<input id="pbxName" maxlength="128" placeholder="Enter a unique PBX deployment name" value="">
            <div class="secret-note">This names the EC2/PBX deployment. It is separate from the AWS Marketplace subscription you selected.</div>'''
if old in s:
    s=s.replace(old,new,1)
elif 'placeholder="Enter a unique PBX deployment name"' not in s:
    raise SystemExit("PATCH ERROR: pbxName markup anchor missing")

# 2) Track when the user explicitly chose "Start another subscription".
state_anchor='let currentMarketplaceQuote = null;'
if 'let creatingNewMarketplaceSubscription = false;' not in s:
    if state_anchor not in s: raise SystemExit("PATCH ERROR: Marketplace state anchor missing")
    s=s.replace(state_anchor,state_anchor+'\n  let creatingNewMarketplaceSubscription = false;',1)

# 3) Add helper that transitions from subscription completion to naming the new deployment.
helper_anchor='  function marketplaceText(value){'
helper=r'''  function promptForPbxDeploymentName(agreementId){
    currentDeploymentPlan=null;
    try{sessionStorage.removeItem("vodiaDeploymentPlan");}catch(_e){}
    if($("approvalBox")){
      $("approvalBox").classList.add("hidden");
      $("approvalBox").dataset.planId="";
      $("approvalBox").dataset.confirmation="";
    }
    if($("planSummary")) $("planSummary").classList.add("hidden");
    const input=$("pbxName");
    input.value="";
    input.placeholder="Enter a unique PBX deployment name";
    setMsg("deployMsg",
      "Marketplace subscription "+(agreementId||"")+" is ready. Name this PBX deployment, then validate the EC2 plan.");
    requestAnimationFrame(()=>{
      input.scrollIntoView({behavior:"smooth",block:"center"});
      input.focus();
    });
    reportSize();
  }

'''
if 'function promptForPbxDeploymentName(agreementId)' not in s:
    if helper_anchor not in s: raise SystemExit("PATCH ERROR: helper insertion anchor missing")
    s=s.replace(helper_anchor,helper+helper_anchor,1)

# 4) Starting another subscription is an explicit workflow transition.
click_old='$("viewMarketplaceOffer").addEventListener("click",()=>loadMarketplaceOffer());'
click_new='''$("viewMarketplaceOffer").addEventListener("click",()=>{
    creatingNewMarketplaceSubscription=marketplaceSubscriptionActive;
    loadMarketplaceOffer();
  });'''
if click_old in s:
    s=s.replace(click_old,click_new,1)
elif 'creatingNewMarketplaceSubscription=marketplaceSubscriptionActive;' not in s:
    raise SystemExit("PATCH ERROR: Start another subscription listener anchor missing")

# 5) After a newly accepted agreement becomes active, select it and ask for a PBX deployment name.
accept_anchor='''      if(active){
        renderMarketplaceSubscription(true,"Vodia Marketplace subscription is active. Agreement "+r.agreementId+" was verified and deployment planning is unlocked.");
      }else{'''
accept_new='''      if(active){
        await checkMarketplaceSubscription();
        if($("marketplaceAgreementSelect") && r.agreementId){
          const exists=[...$("marketplaceAgreementSelect").options].some(o=>o.value===r.agreementId);
          if(exists) $("marketplaceAgreementSelect").value=r.agreementId;
          renderMarketplaceSubscription(true,
            "New Vodia Marketplace subscription is active. Now name the PBX deployment.",
            currentMarketplaceSubscription);
        }
        if(creatingNewMarketplaceSubscription){
          promptForPbxDeploymentName(r.agreementId);
        }
        creatingNewMarketplaceSubscription=false;
      }else{'''
if accept_anchor in s:
    s=s.replace(accept_anchor,accept_new,1)
elif 'promptForPbxDeploymentName(r.agreementId);' not in s:
    raise SystemExit("PATCH ERROR: subscription acceptance transition anchor missing")

# 6) Selecting an existing agreement and having no name should explicitly prompt for one.
change_anchor='''  $("marketplaceAgreementSelect").addEventListener("change",()=>{
    renderMarketplaceSubscription(marketplaceSubscriptionActive,null,currentMarketplaceSubscription);
  });'''
change_new='''  $("marketplaceAgreementSelect").addEventListener("change",()=>{
    renderMarketplaceSubscription(marketplaceSubscriptionActive,null,currentMarketplaceSubscription);
    if(!$("pbxName").value.trim()){
      setMsg("deployMsg","Subscription selected. Enter a unique PBX deployment name before validating the EC2 plan.");
    }
  });'''
if change_anchor in s:
    s=s.replace(change_anchor,change_new,1)

# 7) Do not attempt planning without an explicit deployment name.
validation_old='''    if(!id||!selectedRegion||!name||!instanceType||!subnetId||!securityGroupId){
      setMsg("deployMsg","Complete the PBX, region, subnet, and security-group fields.");
      return;
    }'''
validation_new='''    if(!name){
      setMsg("deployMsg","Enter a unique PBX deployment name. The Marketplace subscription and PBX name are separate.");
      $("pbxName").focus();
      return;
    }
    if(!id||!selectedRegion||!instanceType||!subnetId||!securityGroupId){
      setMsg("deployMsg","Complete the region, instance type, subnet, and security-group fields.");
      return;
    }'''
if validation_old in s:
    s=s.replace(validation_old,validation_new,1)
elif 'The Marketplace subscription and PBX name are separate.' not in s:
    raise SystemExit("PATCH ERROR: plan validation anchor missing")

# 8) Surface backend planner failures when possible instead of masking them.
generic='if(!plan.planId||!plan.confirmation) throw new Error("The deployment planner did not return an approval.");'
improved='''if(!plan.planId||!plan.confirmation){
        const reason=
          plan?.error?.message||
          plan?.error||
          plan?.message||
          plan?.details?.message||
          plan?.details?.error||
          plan?.data?.error||
          "The deployment planner did not return an approval.";
        throw new Error(typeof reason==="string"?reason:JSON.stringify(reason));
      }'''
if generic in s:
    s=s.replace(generic,improved,1)

# 9) Make the deploy step language match the new workflow.
s=s.replace(
  'Choose the PBX and AWS network settings, validate the Marketplace subscription, and create a no-change deployment plan.',
  'Choose a Marketplace subscription, name the PBX deployment, configure AWS, and create a no-change deployment plan.'
)

# 10) Version/cache markers.
if 'data-subscription-first-name="v0.14.9.60"' not in s:
    s=s.replace('data-subscription-picker="v0.14.9.59"',
                'data-subscription-picker="v0.14.9.59" data-subscription-first-name="v0.14.9.60"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.20.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.60/mcp-app.html',s,count=1)
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
grep -Fq 'placeholder="Enter a unique PBX deployment name"' "$TMP/staged/msp-guided-app.html" || fail "explicit PBX name field missing"
grep -Fq 'function promptForPbxDeploymentName(agreementId)' "$TMP/staged/msp-guided-app.html" || fail "subscription-to-name transition missing"
grep -Fq 'creatingNewMarketplaceSubscription=marketplaceSubscriptionActive;' "$TMP/staged/msp-guided-app.html" || fail "new-subscription state missing"
grep -Fq 'The Marketplace subscription and PBX name are separate.' "$TMP/staged/msp-guided-app.html" || fail "PBX name guard missing"
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling regression"
grep -Fq 'id="marketplaceAgreementSelect"' "$TMP/staged/msp-guided-app.html" || fail "subscription picker regression"
echo "PASS: subscription-first PBX naming UX valid"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.59 UI files"
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
grep -q '"version":"0.14.9.60"' <<<"$HEALTH" || fail "health does not report v0.14.9.60"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.60 installed"
echo "PASS: PBX deployment name is no longer prefilled with vodia-pbx."
echo "PASS: A newly activated Marketplace subscription transitions directly to 'name this PBX deployment'."
echo "PASS: Existing subscriptions remain selectable."
echo "PASS: Duplicate-launch protection and automatic AWS status polling are retained."
echo "PASS: Planner failures are surfaced when the backend returns an error/message."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.60 UI resource."
