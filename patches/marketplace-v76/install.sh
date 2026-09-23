#!/usr/bin/env bash
set -Eeuo pipefail
ASSETS="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
DRY_RUN="${VODIA_MCP_DRY_RUN:-0}"
fail() { echo "FAIL: $*" >&2; exit 1; }
for cmd in python3 node npm cp install curl; do command -v "$cmd" >/dev/null || fail "$cmd is required"; done
if [[ "$DRY_RUN" != 1 ]]; then
  [[ "$EUID" -eq 0 ]] || fail "Run the installer as root."
  command -v systemctl >/dev/null || fail "systemctl is required"
fi
FILES=(aws-marketplace-ec2-deploy-v1.js ui/msp-guided-app.html msp-guided-app-v1.js version.js)
for f in "${FILES[@]}"; do [[ -f "$APP/$f" ]] || fail "Missing $APP/$f"; done
[[ ! -L "$APP/marketplace-v76" ]] || fail "Refusing a symlink at the module destination"
TMP="$(mktemp -d -t vodia-marketplace-v76.XXXXXXXX)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/staged/ui" "$TMP/staged/marketplace-v76"
for f in "${FILES[@]}"; do cp -a "$APP/$f" "$TMP/staged/$f"; done
cp "$ASSETS/license-read.mjs" "$ASSETS/package.json" "$ASSETS/package-lock.json" "$TMP/staged/marketplace-v76/"
echo "[1/5] Patch and syntax-check staged source"
python3 "$ASSETS/patch.py" "$TMP/staged"
echo "[2/5] Install isolated, locked License Manager dependency"
npm ci --prefix "$TMP/staged/marketplace-v76" --ignore-scripts --no-audit --no-fund
node --input-type=module -e 'await import(process.argv[1]); console.log("License Manager SDK loads")' "$TMP/staged/marketplace-v76/node_modules/@aws-sdk/client-license-manager/dist-cjs/index.js"
node --check "$TMP/staged/marketplace-v76/license-read.mjs"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "PASS: staging and SDK checks passed. No installed files changed; no service restart."
  exit 0
fi
systemctl is-active --quiet "$SERVICE" || fail "Service must be healthy before installation"
BACKUP="$(mktemp -d "${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v76.XXXXXXXX")"
mkdir -p "$BACKUP/ui"
for f in "${FILES[@]}"; do cp -a "$APP/$f" "$BACKUP/$f"; done
if [[ -d "$APP/marketplace-v76" ]]; then cp -a "$APP/marketplace-v76" "$BACKUP/marketplace-v76"; fi
echo "[3/5] Backup: $BACKUP"
rollback() {
  trap - ERR
  echo "Installation failed. Restoring source from $BACKUP" >&2
  for f in "${FILES[@]}"; do cp -a "$BACKUP/$f" "$APP/$f"; done
  if [[ -d "$APP/marketplace-v76" ]]; then mv "$APP/marketplace-v76" "$BACKUP/failed-module"; fi
  if [[ -d "$BACKUP/marketplace-v76" ]]; then cp -a "$BACKUP/marketplace-v76" "$APP/marketplace-v76"; fi
  systemctl restart "$SERVICE" || true
  echo "Backup retained: $BACKUP" >&2
  exit 1
}
trap rollback ERR
echo "[4/5] Install and restart"
if [[ -d "$APP/marketplace-v76" ]]; then mv "$APP/marketplace-v76" "$BACKUP/previous-module"; fi
cp -a "$TMP/staged/marketplace-v76" "$APP/marketplace-v76"
chmod -R a+rX "$APP/marketplace-v76"
for f in "${FILES[@]}"; do install -m 0644 "$TMP/staged/$f" "$APP/$f"; done
systemctl restart "$SERVICE"
echo "[5/5] Verify version and health"
HEALTH=""
for attempt in {1..30}; do
  if HEALTH="$(curl --max-time 2 -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then
    if node -e 'const h=JSON.parse(process.argv[1]); process.exit(h.version === "0.14.9.76" ? 0 : 1)' "$HEALTH"; then break; fi
  fi
  sleep 1
done
node -e 'const h=JSON.parse(process.argv[1]); process.exit(h.version === "0.14.9.76" ? 0 : 1)' "$HEALTH"
systemctl is-active --quiet "$SERVICE"
trap - ERR
echo "PASS: v0.14.9.76 healthy. Reconnect the MCP and open a fresh Vodia Setup card."
echo "No subscription purchased and no PBX launched. Backup: $BACKUP"
