#!/usr/bin/env bash
# Vodia MCP v0.14.9.54 — Marketplace subscription-first deployment UX
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.54"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-marketplace-subscription-ux-$STAMP"
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
  0.14.9.53) ;;
  0.14.9.54) echo "v0.14.9.54 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.53; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Marketplace subscription-first UX ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/6] Patch staged UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Marketplace card: add a dedicated subscription summary and explicit deployment choice.
anchor='''          <div id="marketplaceMsg" class="guided-copy">Checking this AWS account for an active Vodia subscription…</div>
          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
          </div>'''
replacement='''          <div id="marketplaceMsg" class="guided-copy">Checking this AWS account for an active Vodia subscription…</div>
          <div id="marketplaceSubscriptionSummary" class="summarybox hidden"></div>
          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
            <button id="useMarketplaceSubscription" class="primary hidden" type="button">Deploy Vodia PBX from this subscription →</button>
          </div>'''
if anchor not in s:
    if 'id="useMarketplaceSubscription"' not in s:
        raise SystemExit("PATCH ERROR: Marketplace action anchor missing")
else:
    s=s.replace(anchor,replacement,1)

# Add state for the returned Marketplace subscription.
state='''  let marketplaceSubscriptionActive = false;
  let currentMarketplaceOffer = null;'''
state_new='''  let marketplaceSubscriptionActive = false;
  let currentMarketplaceSubscription = null;
  let currentMarketplaceOffer = null;'''
if state in s:
    s=s.replace(state,state_new,1)
elif 'currentMarketplaceSubscription' not in s:
    raise SystemExit("PATCH ERROR: Marketplace state anchor missing")

# Reset subscription state.
s=s.replace('''    marketplaceSubscriptionActive=false;
    currentMarketplaceOffer=null;''','''    marketplaceSubscriptionActive=false;
    currentMarketplaceSubscription=null;
    currentMarketplaceOffer=null;''',1)

# Replace rendering function so active means "show the subscription", not "skip past it".
start=s.find('  function renderMarketplaceSubscription(active,message){')
end=s.find('\n  async function checkMarketplaceSubscription(){',start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: renderMarketplaceSubscription boundaries missing")

render='''  function renderMarketplaceSubscription(active,message,subscription=null){
    marketplaceSubscriptionActive=Boolean(active);
    currentMarketplaceSubscription=subscription||currentMarketplaceSubscription;
    $("marketplaceBadge").textContent=active?"Active":"Required";
    $("viewMarketplaceOffer").classList.toggle("hidden",Boolean(active));
    $("useMarketplaceSubscription").classList.toggle("hidden",!active);

    if(active){
      $("marketplaceOfferBox").classList.add("hidden");
      $("marketplaceQuoteBox").classList.add("hidden");
      currentMarketplaceQuote=null;

      const agreements=Array.isArray(currentMarketplaceSubscription?.agreements)
        ? currentMarketplaceSubscription.agreements : [];
      const first=agreements[0]||{};
      const agreementId=first.agreementId||first.id||null;
      const startTime=first.startTime||first.acceptanceTime||null;
      const endTime=first.endTime||null;
      $("marketplaceSubscriptionSummary").textContent=[
        "Vodia AWS Marketplace subscription",
        "AWS account: "+(currentAwsConnection?.account||"Unknown"),
        "Product: Vodia PBX",
        "Product ID: "+VODIA_MARKETPLACE_PRODUCT_ID,
        "Status: ACTIVE",
        "Active agreement(s): "+agreements.length,
        agreementId?("Agreement ID: "+agreementId):null,
        startTime?("Started: "+startTime):null,
        endTime?("Ends: "+endTime):null,
        "",
        "This subscription authorizes Vodia PBX Marketplace deployments in this AWS account.",
        "Choose Deploy Vodia PBX from this subscription to configure the EC2 instance that will run the PBX."
      ].filter(Boolean).join("\n");
      $("marketplaceSubscriptionSummary").classList.remove("hidden");
    }else{
      $("marketplaceSubscriptionSummary").classList.add("hidden");
      $("useMarketplaceSubscription").classList.add("hidden");
    }

    setMsg("marketplaceMsg",message||(active
      ?"Your Vodia Marketplace subscription is active. Review it below, then choose whether to deploy a PBX from it."
      :"No active Vodia agreement was found. Review the live AWS offer and subscribe before deployment."));
    if($("continueMarketplace")) $("continueMarketplace").disabled=!marketplaceSubscriptionActive;
    updatePlanButton();
    reportSize();
  }
'''
s=s[:start]+render+s[end:]

# Keep the complete subscription result instead of throwing it away.
old='''      renderMarketplaceSubscription(Boolean(r.active));
      return Boolean(r.active);'''
new='''      renderMarketplaceSubscription(Boolean(r.active),null,r);
      return Boolean(r.active);'''
if old not in s:
    raise SystemExit("PATCH ERROR: subscription result anchor missing")
s=s.replace(old,new,1)

# Make subscription acceptance re-read and show the active subscription details.
s=s.replace('''        renderMarketplaceSubscription(true,"Vodia Marketplace subscription is active. Agreement "+r.agreementId+" was verified and deployment planning is unlocked.");''',
'''        const subscription=dataFrom(await callTool("aws_marketplace_check_subscription",{
          customerId:id,
          productId:VODIA_MARKETPLACE_PRODUCT_ID
        }));
        renderMarketplaceSubscription(true,"Vodia Marketplace subscription is active. Agreement "+r.agreementId+" was verified.",subscription);''',1)

# Explicit deployment action from the subscription card.
handler_anchor='''  $("checkMarketplace").addEventListener("click",checkMarketplaceSubscription);'''
handler='''  $("useMarketplaceSubscription").addEventListener("click",async()=>{
    if(!marketplaceSubscriptionActive) return;
    setMsg("marketplaceMsg","Using this active Vodia Marketplace subscription for the new PBX deployment.");
    await advanceToAwsStep();
  });

'''
if handler_anchor not in s:
    raise SystemExit("PATCH ERROR: Marketplace handler anchor missing")
s=s.replace(handler_anchor,handler+handler_anchor,1)

# If the old Next button exists, give it the same meaning rather than silently skipping context.
s=s.replace('>Next: Configure EC2 →</button>','>Deploy from this subscription →</button>')

# Improve step-4 wording. EC2 is the runtime created FROM the Marketplace subscription.
s=s.replace(
  'Vodia Marketplace subscription active for AWS account "+(currentAwsConnection.account||"")+". Choose the EC2 region and machine settings."',
  'Deploying Vodia PBX from the active Marketplace subscription in AWS account "+(currentAwsConnection.account||"")+". Choose where the PBX EC2 instance will run."'
)
s=s.replace(
  'Choose the EC2 region and machine settings.',
  'Choose where the Vodia PBX instance from this Marketplace subscription will run.'
)

# Cache marker/version.
if 'data-marketplace-deploy-choice="v0.14.9.54"' not in s:
    s=s.replace('<div class="card"', '<div class="card" data-marketplace-deploy-choice="v0.14.9.54"', 1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.16.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.54/mcp-app.html',s,count=1)
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
grep -Fq 'id="marketplaceSubscriptionSummary"' "$TMP/staged/msp-guided-app.html" || fail "subscription summary missing"
grep -Fq 'id="useMarketplaceSubscription"' "$TMP/staged/msp-guided-app.html" || fail "explicit deploy choice missing"
grep -Fq 'Deploy Vodia PBX from this subscription' "$TMP/staged/msp-guided-app.html" || fail "deployment wording missing"
grep -Fq 'data-marketplace-deploy-choice="v0.14.9.54"' "$TMP/staged/msp-guided-app.html" || fail "v0.14.9.54 UI marker missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.54/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "UI cache-bust missing"
echo "PASS"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[4/6] Install"
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
grep -q '"version":"0.14.9.54"' <<<"$HEALTH" || fail "health does not report v0.14.9.54"
echo "$HEALTH"
echo "PASS"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.54 installed"
echo "PASS: Marketplace step shows the active Vodia subscription before EC2 configuration."
echo "PASS: User explicitly chooses 'Deploy Vodia PBX from this subscription'."
echo "PASS: EC2 configuration is presented as the runtime deployment from the Marketplace entitlement."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.54 UI."
