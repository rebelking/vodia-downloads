#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.14.9.71"
ASSET_COMMIT="a11b83d0a54d9066163d62523d816830ad017499"
BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${ASSET_COMMIT}/releases/v${VERSION}"
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v${VERSION}-aws-inventory-${STAMP}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

current="$(sed -n 's/.*CONNECTOR_VERSION = "\([^"]*\)".*/\1/p' "$APP/version.js" | head -1)"
echo "Current version: ${current:-unknown}"
if [[ "$current" != "0.14.9.70" && "$current" != "$VERSION" ]]; then
  echo "FAIL: this cumulative patch requires v0.14.9.70 (found ${current:-unknown})." >&2
  exit 1
fi

echo "[1/8] Download immutable v${VERSION} files — NO LIVE CHANGES"
mkdir -p "$TMP/ui"
curl -fsSL "$BASE/aws-marketplace-ec2-deploy-v1.js" -o "$TMP/aws-marketplace-ec2-deploy-v1.js"
curl -fsSL "$BASE/msp-guided-app-v1.js" -o "$TMP/msp-guided-app-v1.js"
curl -fsSL "$BASE/msp-guided-app.html" -o "$TMP/ui/msp-guided-app.html"
curl -fsSL "$BASE/version.js" -o "$TMP/version.js"

echo "[2/8] Validate staged backend"
node --check "$TMP/aws-marketplace-ec2-deploy-v1.js"
node --check "$TMP/msp-guided-app-v1.js"
grep -q 'VODIA_AWS_INVENTORY_V71 = true' "$TMP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'scanVodiaManagedInventory' "$TMP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'MARKETPLACE_AGREEMENT_ALREADY_IN_USE' "$TMP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'agreementReleaseBlockedByInstances' "$TMP/aws-marketplace-ec2-deploy-v1.js"
echo "PASS: cross-region inventory, duplicate guard, and safe subscription release are present"

echo "[3/8] Validate staged guided UI"
grep -q 'data-aws-inventory="v0.14.9.71"' "$TMP/ui/msp-guided-app.html"
grep -q 'AWS Vodia PBX inventory' "$TMP/ui/msp-guided-app.html"
grep -q 'Duplicate agreement' "$TMP/ui/msp-guided-app.html"
grep -q 'uiVersion:"0.14.9.71"' "$TMP/ui/msp-guided-app.html"
awk '/<script type="module">/{capture=1;next}/<\/script>/{capture=0}capture' "$TMP/ui/msp-guided-app.html" > "$TMP/ui-inline.js"
node --check "$TMP/ui-inline.js"
echo "PASS: full EC2 inventory and per-instance monitor/termination selection are present"

echo "[4/8] Backup"
mkdir -p "$BACKUP/ui"
cp -a "$APP/aws-marketplace-ec2-deploy-v1.js" "$BACKUP/"
cp -a "$APP/msp-guided-app-v1.js" "$BACKUP/"
cp -a "$APP/ui/msp-guided-app.html" "$BACKUP/ui/"
cp -a "$APP/version.js" "$BACKUP/"
echo "PASS: $BACKUP"

echo "[5/8] Install"
install -m 0644 "$TMP/aws-marketplace-ec2-deploy-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js"
install -m 0644 "$TMP/msp-guided-app-v1.js" "$APP/msp-guided-app-v1.js"
install -m 0644 "$TMP/ui/msp-guided-app.html" "$APP/ui/msp-guided-app.html"
install -m 0644 "$TMP/version.js" "$APP/version.js"

echo "[6/8] Restart"
systemctl restart vodia-mcp.service

echo "[7/8] Verify live service"
health="$(curl -fsS http://127.0.0.1:3100/health)"
echo "$health"
grep -q '"version":"0.14.9.71"' <<<"$health"
grep -q 'VODIA_AWS_INVENTORY_V71 = true' "$APP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'data-aws-inventory="v0.14.9.71"' "$APP/ui/msp-guided-app.html"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v${VERSION} installed and verified."
echo "PASS: Marketplace now shows every active Vodia-managed EC2 instance found across enabled regions."
echo "PASS: duplicate instances on one agreement are flagged and individually selectable for monitoring or termination."
echo "PASS: planning and apply both block another launch while that agreement has an active instance."
echo "PASS: terminating one duplicate does not release the agreement while another active instance remains."
echo "NOTICE: this installer did not stop or terminate any EC2 instance."
echo "Backup: $BACKUP"
echo
echo "NEXT TEST: reconnect the MCP client, open a fresh Vodia Setup card, choose the customer, and click Check subscription."
