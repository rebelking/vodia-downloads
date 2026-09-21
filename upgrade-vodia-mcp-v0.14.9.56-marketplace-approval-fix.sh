#!/usr/bin/env bash
# Vodia MCP v0.14.9.56 — Marketplace visibility + resilient deployment approval
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/msp-customer-connections-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.56"
SOURCE_COMMIT="d09244c5eea3b6871338bd2440803e4676f421d5"
BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-marketplace-approval-fix-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node grep install systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
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
  0.14.9.54|0.14.9.55) ;;
  0.14.9.56) echo "v0.14.9.56 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.54 or v0.14.9.55; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Marketplace visibility + approval resilience ==="
mkdir -p "$TMP/staged/ui"

echo "[1/6] Stage live UI and v0.14.9.55 AWS guard backend — NO LIVE CHANGES"
cp -a "$UI" "$TMP/staged/ui/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"
curl -fsSL "$BASE_URL/msp-customer-connections-v1.js" -o "$TMP/staged/msp-customer-connections-v1.js"

echo "[2/6] Patch staged UI"
python3 - "$TMP/staged/ui/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# 1) Always give Marketplace its own visible summary inside the card.
if 'id="marketplaceSubscriptionSummary"' not in s:
    anchor='<div id="marketplaceMsg" class="guided-copy">Checking this AWS account for an active Vodia subscription…</div>'
    if anchor not in s:
        raise SystemExit("PATCH ERROR: marketplaceMsg anchor missing")
    s=s.replace(anchor, anchor+'\n          <div id="marketplaceSubscriptionSummary" class="summarybox hidden"></div>',1)

# 2) Track full subscription result if not already present.
if 'let currentMarketplaceSubscription = null;' not in s:
    anchor='let marketplaceSubscriptionActive = false;'
    if anchor not in s: raise SystemExit("PATCH ERROR: marketplace subscription state anchor missing")
    s=s.replace(anchor, anchor+'\n  let currentMarketplaceSubscription = null;',1)

# 3) Replace marketplace renderer with one that exposes account/product/status/agreement.
start=s.find('  function renderMarketplaceSubscription(')
end=s.find('\n  async function checkMarketplaceSubscription(){',start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: renderMarketplaceSubscription boundaries missing")
render='''  function renderMarketplaceSubscription(active,message,subscription=null){
    marketplaceSubscriptionActive=Boolean(active);
    currentMarketplaceSubscription=subscription||currentMarketplaceSubscription;
    $("marketplaceBadge").textContent=active?"Active":"Required";
    $("viewMarketplaceOffer").classList.toggle("hidden",Boolean(active));

    const summary=$("marketplaceSubscriptionSummary");
    if(active){
      $("marketplaceOfferBox").classList.add("hidden");
      $("marketplaceQuoteBox").classList.add("hidden");
      currentMarketplaceQuote=null;
      const agreements=Array.isArray(currentMarketplaceSubscription?.agreements)
        ? currentMarketplaceSubscription.agreements : [];
      const first=agreements[0]||{};
      const agreementId=first.agreementId||first.id||null;
      summary.textContent=[
        "Vodia AWS Marketplace subscription",
        "AWS account: "+(currentAwsConnection?.account||"Unknown"),
        "Product: Vodia PBX",
        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "Status: ACTIVE",
        "Active agreement(s): "+agreements.length,
        agreementId?("Agreement ID: "+agreementId):null
      ].filter(Boolean).join("\n");
      summary.classList.remove("hidden");
    }else{
      summary.classList.add("hidden");
    }

    setMsg("marketplaceMsg",message||(active
      ?"Active Vodia AWS Marketplace agreement verified. This PBX deployment will use that subscription."
      :"No active Vodia agreement was found. Review the live AWS offer and subscribe before deployment."));
    if($("continueMarketplace")) $("continueMarketplace").disabled=!marketplaceSubscriptionActive;
    updatePlanButton();
    reportSize();
  }
'''
s=s[:start]+render+s[end:]

# 4) Preserve the complete subscription response.
s=s.replace(
'''      renderMarketplaceSubscription(Boolean(r.active));
      return Boolean(r.active);''',
'''      renderMarketplaceSubscription(Boolean(r.active),null,r);
      return Boolean(r.active);''',1)

# 5) Make Marketplace identity visible in the final deployment plan as well.
needle='''        "Plan validated — no instance launched",
        "PBX: "+name,''';
replacement='''        "Plan validated — no instance launched",
        "Marketplace: Vodia PBX — ACTIVE",
        "AWS account: "+(currentAwsConnection?.account||"Unknown"),
        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "PBX: "+name,''';
if needle in s:
    s=s.replace(needle,replacement,1)
elif '"Marketplace: Vodia PBX — ACTIVE"' not in s:
    raise SystemExit("PATCH ERROR: plan summary anchor missing")

# 6) Persist short-lived deployment plan state so a host/card re-render does not
# make the Deploy button silently do nothing.
plan_anchor='''      currentDeploymentPlan=plan;
      $("planSummary").textContent=['''
plan_new='''      currentDeploymentPlan=plan;
      const persistedPlan={
        planId:plan.planId,
        confirmation:plan.confirmation,
        customerId:customerId(),
        savedAt:Date.now()
      };
      try{sessionStorage.setItem("vodiaDeploymentPlan",JSON.stringify(persistedPlan));}catch(_e){}
      $("approvalBox").dataset.planId=plan.planId||"";
      $("approvalBox").dataset.confirmation=plan.confirmation||"";
      $("planSummary").textContent=['''
if plan_anchor in s:
    s=s.replace(plan_anchor,plan_new,1)
elif 'sessionStorage.setItem("vodiaDeploymentPlan"' not in s:
    raise SystemExit("PATCH ERROR: plan persistence anchor missing")

# 7) Approval input gives immediate feedback and controls the deploy button.
listener_anchor='''  $("applyDeployment").addEventListener("click",async()=>{'''
listener='''  function resolvedDeploymentPlan(){
    if(currentDeploymentPlan?.planId) return currentDeploymentPlan;
    const box=$("approvalBox");
    if(box?.dataset?.planId && box?.dataset?.confirmation){
      return {planId:box.dataset.planId,confirmation:box.dataset.confirmation};
    }
    try{
      const saved=JSON.parse(sessionStorage.getItem("vodiaDeploymentPlan")||"null");
      if(saved?.planId && saved?.confirmation && Date.now()-Number(saved.savedAt||0)<15*60*1000){
        return saved;
      }
    }catch(_e){}
    return null;
  }

  $("deploymentApproval").addEventListener("input",()=>{
    const plan=resolvedDeploymentPlan();
    const entered=$("deploymentApproval").value.trim();
    const matches=Boolean(plan?.confirmation && entered===plan.confirmation);
    $("applyDeployment").disabled=!matches;
    setMsg("deployMsg",entered
      ? (matches?"Approval matches. Ready to deploy.":"Approval does not exactly match the validated plan.")
      : "Paste the exact approval from the validated plan.");
  });

'''
if listener_anchor not in s:
    raise SystemExit("PATCH ERROR: applyDeployment listener anchor missing")
if 'function resolvedDeploymentPlan(){' not in s:
    s=s.replace(listener_anchor,listener+listener_anchor,1)

# 8) Replace silent early-return with a visible recoverable error and use persisted plan.
old_apply='''  $("applyDeployment").addEventListener("click",async()=>{
    if(!currentDeploymentPlan?.planId) return;
    const confirmation=$("deploymentApproval").value.trim();
    if(confirmation!==currentDeploymentPlan.confirmation){
      setMsg("deployMsg","Enter the exact approval shown in the validated plan.");
      return;
    }
    try{'''
new_apply='''  $("applyDeployment").addEventListener("click",async()=>{
    const plan=resolvedDeploymentPlan();
    if(!plan?.planId){
      setMsg("deployMsg","Deployment plan state was lost or expired. Click Validate & Create Plan again.");
      return;
    }
    const confirmation=$("deploymentApproval").value.trim();
    if(confirmation!==plan.confirmation){
      setMsg("deployMsg","Enter the exact approval shown in the validated plan.");
      return;
    }
    try{'''
if old_apply in s:
    s=s.replace(old_apply,new_apply,1)
elif 'Deployment plan state was lost or expired.' not in s:
    raise SystemExit("PATCH ERROR: apply handler start missing")

s=s.replace('''        planId:currentDeploymentPlan.planId,
        confirmation''','''        planId:plan.planId,
        confirmation''',1)

# On successful launch clear persisted plan; on new validated plan require exact match.
success='''      setMsg("deployMsg","Vodia PBX deployment started successfully.");
      currentDeploymentPlan=null;'''
success_new='''      setMsg("deployMsg","Vodia PBX deployment started successfully.");
      currentDeploymentPlan=null;
      try{sessionStorage.removeItem("vodiaDeploymentPlan");}catch(_e){}
      $("approvalBox").dataset.planId="";
      $("approvalBox").dataset.confirmation="";'''
if success in s:
    s=s.replace(success,success_new,1)

# Ensure button starts disabled until exact approval is entered.
s=s.replace(
'<button id="applyDeployment" class="primary" type="button" style="margin-top:9px">Deploy Vodia PBX</button>',
'<button id="applyDeployment" class="primary" type="button" style="margin-top:9px" disabled>Deploy Vodia PBX</button>',1)

# Version/cache marker.
if 'data-marketplace-approval-fix="v0.14.9.56"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-marketplace-approval-fix="v0.14.9.56"', 1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.18.0"}',s,count=1)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.56/mcp-app.html',s,count=1)
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

echo "[3/6] Validate staged source"
node --check "$TMP/staged/msp-customer-connections-v1.js" >/dev/null
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
grep -Fq 'alreadyConnected: true' "$TMP/staged/msp-customer-connections-v1.js" || fail "existing AWS guard missing"
grep -Fq 'id="marketplaceSubscriptionSummary"' "$TMP/staged/ui/msp-guided-app.html" || fail "Marketplace summary missing"
grep -Fq '"Marketplace: Vodia PBX — ACTIVE"' "$TMP/staged/ui/msp-guided-app.html" || fail "Marketplace review line missing"
grep -Fq 'function resolvedDeploymentPlan(){' "$TMP/staged/ui/msp-guided-app.html" || fail "deployment plan recovery missing"
grep -Fq 'Deployment plan state was lost or expired.' "$TMP/staged/ui/msp-guided-app.html" || fail "visible plan-state error missing"
grep -Fq 'Approval matches. Ready to deploy.' "$TMP/staged/ui/msp-guided-app.html" || fail "approval feedback missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.56/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "UI cache bust missing"
echo "PASS"

echo "[4/6] Backup"
mkdir -p "$BACKUP_DIR/ui"
cp -a "$BACKEND" "$BACKUP_DIR/msp-customer-connections-v1.js"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$UI" "$BACKUP_DIR/ui/msp-guided-app.html"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.key ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.key "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring previous application files"
  cp -a "$BACKUP_DIR/msp-customer-connections-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/ui/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[5/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-customer-connections-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/ui/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[6/6] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.56"' <<<"$HEALTH" || fail "health does not report v0.14.9.56"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"
echo "PASS"
echo "PASS: Vodia MCP v0.14.9.56 installed"
echo "PASS: Marketplace subscription is visible in the setup/review card."
echo "PASS: Existing AWS connection guard is retained."
echo "PASS: Exact deployment approval gives immediate match feedback."
echo "PASS: Deployment plan state survives normal card re-render within the plan TTL."
echo "PASS: Missing/expired plan state now shows an error instead of doing nothing."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.56 UI."
