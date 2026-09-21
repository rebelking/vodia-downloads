#!/usr/bin/env bash
# Vodia MCP v0.14.9.59 — Marketplace subscription picker + new subscription path
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.59"
SOURCE_COMMIT="5dda95e311f5cb11e4f94cd638c498773d1527a4"
RAW="https://raw.githubusercontent.com/rebelking/vodia-downloads/$SOURCE_COMMIT"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-subscription-picker-$STAMP"
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
  0.14.9.58) ;;
  0.14.9.59) echo "v0.14.9.59 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.58; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Marketplace subscription picker ==="
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

# Add an explicit active-agreement picker under the Marketplace summary.
if 'id="marketplaceAgreementSelect"' not in s:
    anchor='<div id="marketplaceSubscriptionSummary" class="summarybox hidden"></div>'
    if anchor not in s:
        raise SystemExit("PATCH ERROR: Marketplace summary anchor missing")
    picker='''\n          <div id="marketplaceAgreementBox" class="field hidden" style="margin-top:10px">
            <label for="marketplaceAgreementSelect">Active subscription used for this deployment</label>
            <select id="marketplaceAgreementSelect"></select>
            <div class="secret-note">Choose which active AWS Marketplace agreement to bind to the deployment record. You can also start another subscription below.</div>
          </div>'''
    s=s.replace(anchor,anchor+picker,1)

# Replace the Marketplace renderer so all active agreements are listed and selectable.
start=s.find('  function renderMarketplaceSubscription(')
end=s.find('\n  async function checkMarketplaceSubscription(){',start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: renderMarketplaceSubscription boundaries missing")
render=r'''  function renderMarketplaceSubscription(active,message,subscription=null){
    marketplaceSubscriptionActive=Boolean(active);
    currentMarketplaceSubscription=subscription||currentMarketplaceSubscription;
    $("marketplaceBadge").textContent=active?"Active":"Required";

    // Existing subscribers can always choose to create another Marketplace agreement.
    $("viewMarketplaceOffer").classList.remove("hidden");
    $("viewMarketplaceOffer").textContent=active?"Start another subscription":"View plans & subscribe";

    const agreements=Array.isArray(currentMarketplaceSubscription?.agreements)
      ? currentMarketplaceSubscription.agreements : [];
    const pickerBox=$("marketplaceAgreementBox");
    const picker=$("marketplaceAgreementSelect");
    const previous=picker?.value||"";

    if(picker){
      picker.innerHTML="";
      agreements.forEach((agreement,index)=>{
        const op=document.createElement("option");
        const id=agreement?.agreementId||agreement?.id||"";
        op.value=id;
        const status=agreement?.status||"ACTIVE";
        const start=agreement?.startTime?(" · "+String(agreement.startTime)):"";
        const end=agreement?.endTime?(" · ends "+String(agreement.endTime)):"";
        op.textContent="Subscription "+(index+1)+" · "+id+" · "+status+start+end;
        picker.appendChild(op);
      });
      if(previous && agreements.some(a=>(a?.agreementId||a?.id)===previous)) picker.value=previous;
      else if(agreements[0]) picker.value=agreements[0].agreementId||agreements[0].id||"";
    }
    if(pickerBox) pickerBox.classList.toggle("hidden",!active||agreements.length===0);

    const summary=$("marketplaceSubscriptionSummary");
    if(active){
      $("marketplaceOfferBox").classList.add("hidden");
      $("marketplaceQuoteBox").classList.add("hidden");
      currentMarketplaceQuote=null;
      const selectedId=picker?.value||(agreements[0]?.agreementId||agreements[0]?.id||null);
      summary.textContent=[
        "Vodia AWS Marketplace subscriptions",
        "AWS account: "+(currentAwsConnection?.account||"Unknown"),
        "Product: Vodia PBX",
        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "Status: ACTIVE",
        "Active agreement(s): "+agreements.length,
        selectedId?("Selected agreement: "+selectedId):null
      ].filter(Boolean).join("\n");
      summary.classList.remove("hidden");
    }else{
      summary.classList.add("hidden");
      if(pickerBox) pickerBox.classList.add("hidden");
    }

    setMsg("marketplaceMsg",message||(active
      ?"Choose an active subscription for this deployment, or start another subscription."
      :"No active Vodia agreement was found. Review the live AWS offer and subscribe before deployment."));
    if($("continueMarketplace")) $("continueMarketplace").disabled=!marketplaceSubscriptionActive;
    updatePlanButton();
    reportSize();
  }
'''
s=s[:start]+render+s[end:]

# Keep the summary in sync when a different agreement is chosen.
listener='''  $("marketplaceAgreementSelect").addEventListener("change",()=>{
    renderMarketplaceSubscription(marketplaceSubscriptionActive,null,currentMarketplaceSubscription);
  });\n'''
anchor='''  $("checkMarketplace").addEventListener("click",checkMarketplaceSubscription);'''
if listener.strip() not in s:
    if anchor not in s: raise SystemExit("PATCH ERROR: Marketplace listener anchor missing")
    s=s.replace(anchor,listener+anchor,1)

# Restore the proper button label after loading an offer.
s=s.replace(
  '$("viewMarketplaceOffer").textContent="View plans & subscribe";',
  '$("viewMarketplaceOffer").textContent=marketplaceSubscriptionActive?"Start another subscription":"View plans & subscribe";'
)

# Bind the selected active agreement to a deployment plan.
call_anchor='''        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID,
        region:selectedRegion,''';
call_new='''        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID,
        agreementId:$("marketplaceAgreementSelect")?.value||undefined,
        region:selectedRegion,''';
if call_anchor in s:
    s=s.replace(call_anchor,call_new,1)
elif 'agreementId:$("marketplaceAgreementSelect")?.value||undefined' not in s:
    raise SystemExit("PATCH ERROR: deployment plan call anchor missing")

# Show the chosen agreement on the review card.
review_anchor='''        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "PBX: "+name,''';
review_new='''        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "Agreement: "+(plan.selectedAgreement?.agreementId||$("marketplaceAgreementSelect")?.value||"Active agreement"),
        "PBX: "+name,''';
if review_anchor in s:
    s=s.replace(review_anchor,review_new,1)
elif '"Agreement: "+(plan.selectedAgreement?.agreementId' not in s:
    raise SystemExit("PATCH ERROR: review agreement anchor missing")

# Show agreement in post-launch status as well.
status_anchor='''      "Region: "+(status?.region||selectedRegion||""),
      "Public IP: "+(status?.publicIpAddress||"pending"),''';
status_new='''      "Region: "+(status?.region||selectedRegion||""),
      "Marketplace agreement: "+(status?.agreementId||"verified"),
      "Public IP: "+(status?.publicIpAddress||"pending"),''';
if status_anchor in s:
    s=s.replace(status_anchor,status_new,1)

# Version markers.
if 'data-subscription-picker="v0.14.9.59"' not in s:
    s=s.replace('data-deployment-safety="v0.14.9.58"',
                'data-deployment-safety="v0.14.9.58" data-subscription-picker="v0.14.9.59"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.19.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.59/mcp-app.html',s,count=1)
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

echo "[2/7] Validate backend"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null
grep -Fq 'agreementId: z.string().min(3).optional()' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement selector schema missing"
grep -Fq 'AGREEMENT_NOT_ACTIVE' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "active agreement verification missing"
grep -Fq 'VodiaMarketplaceAgreementId' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "agreement instance tag missing"
grep -Fq 'DUPLICATE_DEPLOYMENT_BLOCKED' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "duplicate guard regression"
grep -Fq 'ClientToken: clientToken' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "EC2 idempotency regression"
echo "PASS: subscription selection + deployment safety backend present"

echo "[3/7] Validate UI"
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
grep -Fq 'id="marketplaceAgreementSelect"' "$TMP/staged/msp-guided-app.html" || fail "subscription picker missing"
grep -Fq 'Start another subscription' "$TMP/staged/msp-guided-app.html" || fail "new subscription action missing"
grep -Fq 'agreementId:$("marketplaceAgreementSelect")?.value||undefined' "$TMP/staged/msp-guided-app.html" || fail "selected agreement not passed to plan"
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling regression"
echo "PASS: active subscription list/picker + new subscription path present"

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
  echo "ROLLBACK: restoring v0.14.9.58 files"
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
grep -q '"version":"0.14.9.59"' <<<"$HEALTH" || fail "health does not report v0.14.9.59"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.59 installed"
echo "PASS: All active Vodia Marketplace agreements are listed and selectable."
echo "PASS: Existing subscribers can start another Marketplace subscription."
echo "PASS: Selected agreement is verified, stored in the deployment plan, and tagged on the EC2 instance."
echo "PASS: Duplicate-launch protection and automatic status polling are retained."
echo "NOTE: EC2 RunInstances uses the Marketplace product entitlement; agreement selection is used for verification, audit/traceability, and deployment tagging."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.59 UI resource."
