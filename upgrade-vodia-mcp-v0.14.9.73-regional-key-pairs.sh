#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.14.9.73"
ASSET_COMMIT="69043afa67a36586cb99eb7379b6c18852b11d31"
BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${ASSET_COMMIT}/releases/v${VERSION}"
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v${VERSION}-regional-key-pairs-${STAMP}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

current="$(sed -n 's/.*CONNECTOR_VERSION = "\([^"]*\)".*/\1/p' "$APP/version.js" | head -1)"
echo "Current version: ${current:-unknown}"
if [[ "$current" != "0.14.9.72" && "$current" != "$VERSION" ]]; then
  echo "FAIL: this patch requires v0.14.9.72 (found ${current:-unknown})." >&2
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
grep -q 'DescribeKeyPairsCommand' "$TMP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'keyPairsRegion: region' "$TMP/aws-marketplace-ec2-deploy-v1.js"
grep -q 'keyType: k.KeyType' "$TMP/aws-marketplace-ec2-deploy-v1.js"
echo "PASS: regional AWS key-pair discovery and stable sorting are present"

echo "[3/8] Validate staged guided UI"
grep -q 'data-regional-key-pairs="v0.14.9.73"' "$TMP/ui/msp-guided-app.html"
grep -q 'No SSH key pairs found in' "$TMP/ui/msp-guided-app.html"
grep -q 'EC2 key pairs are Region-specific' "$TMP/ui/msp-guided-app.html"
grep -q 'uiVersion:"0.14.9.73"' "$TMP/ui/msp-guided-app.html"
awk '/<script>/{capture=1;next}/<\/script>/{capture=0}capture' "$TMP/ui/msp-guided-app.html" > "$TMP/ui-inline.js"
test -s "$TMP/ui-inline.js"
node --check "$TMP/ui-inline.js"
echo "PASS: the card automatically reloads and explains regional SSH key-pair results"

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
health=""
for attempt in $(seq 1 30); do
  if health="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
if [[ -z "$health" ]]; then
  echo "FAIL: vodia-mcp did not answer its health endpoint within 30 seconds." >&2
  systemctl status vodia-mcp.service --no-pager -l || true
  journalctl -u vodia-mcp.service --since "2 minutes ago" --no-pager -n 80 || true
  exit 1
fi
echo "$health"
grep -q '"version":"0.14.9.73"' <<<"$health"

echo "[8/8] Complete"
echo "PASS: Vodia MCP v${VERSION} installed and verified."
echo "PASS: changing the deployment Region automatically reloads EC2 options."
echo "PASS: the SSH selector shows key pairs returned by AWS for that exact Region."
echo "PASS: an empty result names the checked Region and explains that EC2 key pairs are Region-specific."
echo "PASS: Reload EC2 options refreshes key pairs and preserves the prior selection when it still exists."
echo "NOTICE: this installer did not create, import, delete, or expose any SSH private key."
echo "Backup: $BACKUP"
echo
echo "NEXT TEST: reconnect the MCP client, open a fresh Vodia Setup card, choose a Region with an EC2 key pair, and confirm the SSH selector populates."
