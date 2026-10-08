#!/usr/bin/env bash
# Vodia MCP v0.14.9.44 — AWS Marketplace pricing link
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.44-marketplace-pricing-link-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PRICING_URL='https://aws.amazon.com/marketplace/procurement/?productId=prod-v5qnz6xf6wu5u&redirectUrl=https%3A%2F%2Faws.amazon.com%2Fmarketplace%2Fpp%2Fprodview-k4gepe5tujjgy&ref_=beagle'

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node curl systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$APP/version.js" "$APP/ui/msp-guided-app.html"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
echo "Current version: ${CURRENT:-unknown}"
case "$CURRENT" in
  0.14.9.43) ;;
  0.14.9.44) echo "v0.14.9.44 already installed; verification mode." ;;
  *) fail "expected v0.14.9.43 or v0.14.9.44; found ${CURRENT:-unknown}" ;;
esac

echo "[1/7] Backup"
mkdir -p "$BACKUP"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

cp -a "$APP/ui/msp-guided-app.html" "$TMP/msp-guided-app.html"
cp -a "$APP/version.js" "$TMP/version.js"

if [[ "$CURRENT" != "0.14.9.44" ]]; then
  echo "[2/7] Add AWS Marketplace pricing link"
  python3 - "$TMP/msp-guided-app.html" "$PRICING_URL" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); url=sys.argv[2]; s=p.read_text()

if 'id="marketplacePricingLink"' in s:
    raise SystemExit("PATCH ERROR: pricing link already exists")

old='''          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
          </div>'''
new=f'''          <div class="marketplace-actions">
            <button id="checkMarketplace" class="secondary" type="button">Check subscription</button>
            <button id="viewMarketplaceOffer" class="primary hidden" type="button">View plans &amp; subscribe</button>
            <a id="marketplacePricingLink" href="{url}" target="_blank" rel="noopener noreferrer"
              style="display:inline-flex;align-items:center;padding:9px 11px;border:1px solid color-mix(in srgb,CanvasText 18%,transparent);border-radius:9px;color:CanvasText;text-decoration:none;font-weight:650;font-size:inherit">
              View AWS Marketplace pricing
            </a>
          </div>'''
if s.count(old) != 1:
    raise SystemExit(f"PATCH ERROR: marketplace actions anchor count={s.count(old)}")
s=s.replace(old,new,1)
p.write_text(s)
PY
  grep -Fq "$PRICING_URL" "$TMP/msp-guided-app.html" || fail "pricing URL missing after patch"
  grep -Fq 'id="marketplacePricingLink"' "$TMP/msp-guided-app.html" || fail "pricing link missing after patch"
  echo PASS

  echo "[3/7] Stage version"
  python3 - "$TMP/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
s,n=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])0\.14\.9\.43(["\'])',r'\g<1>0.14.9.44\2',s,count=1)
if n != 1: raise SystemExit("PATCH ERROR: version anchor not found")
p.write_text(s)
PY
  grep -q 'CONNECTOR_VERSION.*0.14.9.44' "$TMP/version.js" || fail "version staging failed"

  echo "[4/7] Static validation"
  grep -Fq 'View plans &amp; subscribe' "$TMP/msp-guided-app.html" || fail "guided purchase button was removed"
  grep -Fq 'View AWS Marketplace pricing' "$TMP/msp-guided-app.html" || fail "pricing link label missing"
  grep -Fq 'aws_marketplace_present_vodia_offer' "$TMP/msp-guided-app.html" || fail "guided offer flow was altered"
  grep -Fq 'aws_marketplace_prepare_vodia_purchase' "$TMP/msp-guided-app.html" || fail "guided quote flow was altered"
  grep -Fq 'aws_marketplace_accept_vodia_purchase' "$TMP/msp-guided-app.html" || fail "guided agreement flow was altered"
  echo "PASS: external AWS pricing link added"
  echo "PASS: guided subscription workflow preserved"

  echo "[5/7] Install"
  install -o root -g root -m 0644 "$TMP/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
  install -o root -g root -m 0644 "$TMP/version.js" "$APP/version.js"

  echo "[6/7] Restart + health"
  systemctl restart "$SERVICE"
else
  echo "[2/7]-[6/7] Install skipped"
fi

HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 100 --no-pager >&2 || true; fail "MCP health failed"; }
echo "$HEALTH"
grep -q '"version":"0.14.9.44"' <<<"$HEALTH" || fail "health does not report v0.14.9.44"
grep -Fq "$PRICING_URL" "$APP/ui/msp-guided-app.html" || fail "live pricing URL missing"
grep -Fq 'id="marketplacePricingLink"' "$APP/ui/msp-guided-app.html" || fail "live pricing link missing"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.44 installed and verified."
echo "PASS: View AWS Marketplace pricing opens the official AWS Marketplace pricing/procurement page."
echo "PASS: existing buyer-specific offer, quote, approval, and subscription flow remains intact."
echo "Backup retained at: $BACKUP"
echo "Reconnect the MCP client and open Vodia setup in a new message."
