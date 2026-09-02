#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.13.2"
BASE_URL="${VODIA_MCP_RELEASE_BASE_URL:-https://raw.githubusercontent.com/rebelking/vodia-downloads/main}"
APP_DIR="/opt/vodia-mcp"
ENV_FILE="/etc/vodia-mcp.env"
SERVICE_FILE="/etc/systemd/system/vodia-mcp.service"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP_DIR="$(mktemp -d)"
NEW_DIR="/opt/vodia-mcp.new-${STAMP}"
OLD_DIR="/opt/vodia-mcp.previous-${STAMP}"
ENV_BACKUP="/etc/vodia-mcp.env.before-${STAMP}"
SERVICE_BACKUP="/etc/systemd/system/vodia-mcp.service.before-${STAMP}"
SWITCHED="false"

cleanup() {
  find "$TMP_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$TMP_DIR" 2>/dev/null || true
}

rollback() {
  local exit_code=$?
  if [[ "$SWITCHED" == "true" ]]; then
    echo "Upgrade failed. Rolling back application and service configuration..."
    systemctl stop vodia-mcp 2>/dev/null || true
    if [[ -d "$APP_DIR" ]]; then mv "$APP_DIR" "/opt/vodia-mcp.failed-${STAMP}"; fi
    if [[ -d "$OLD_DIR" ]]; then mv "$OLD_DIR" "$APP_DIR"; fi
    cp -a "$ENV_BACKUP" "$ENV_FILE"
    cp -a "$SERVICE_BACKUP" "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl restart vodia-mcp || true
  fi
  cleanup
  exit "$exit_code"
}
trap rollback ERR
trap cleanup EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo "Run with sudo: sudo bash upgrade-vodia-mcp-v0.13.2.sh"
  exit 1
fi
for required in "$APP_DIR/package.json" "$ENV_FILE" "$SERVICE_FILE"; do
  [[ -e "$required" ]] || { echo "Required existing installation file is missing: $required"; exit 1; }
done

CURRENT_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
[[ "$CURRENT_VERSION" == "0.13.1" ]] || {
  echo "This upgrade expects v0.13.1; found ${CURRENT_VERSION:-unknown}."
  exit 1
}

echo "[1/8] Downloading Vodia MCP ${VERSION}..."
cd "$TMP_DIR"
if [[ -n "${VODIA_MCP_PACKAGE_FILE:-}" ]]; then
  [[ -f "$VODIA_MCP_PACKAGE_FILE" ]] || { echo "Local package not found: $VODIA_MCP_PACKAGE_FILE"; exit 1; }
  LOCAL_CHECKSUM_FILE="${VODIA_MCP_CHECKSUM_FILE:-${VODIA_MCP_PACKAGE_FILE%.zip}.sha256}"
  [[ -f "$LOCAL_CHECKSUM_FILE" ]] || { echo "Local checksum not found: $LOCAL_CHECKSUM_FILE"; exit 1; }
  cp "$VODIA_MCP_PACKAGE_FILE" "vodia-mcp-v${VERSION}-complete-api.zip"
  cp "$LOCAL_CHECKSUM_FILE" "vodia-mcp-v${VERSION}-complete-api.sha256"
else
  wget --https-only --secure-protocol=TLSv1_2 -q "${BASE_URL}/vodia-mcp-v${VERSION}-complete-api.zip"
  wget --https-only --secure-protocol=TLSv1_2 -q "${BASE_URL}/vodia-mcp-v${VERSION}-complete-api.sha256"
fi

echo "[2/8] Verifying SHA-256..."
sha256sum -c "vodia-mcp-v${VERSION}-complete-api.sha256"

echo "[3/8] Extracting and checking release..."
unzip -q "vodia-mcp-v${VERSION}-complete-api.zip" -d release
test -f release/vodia-mcp/http.js
test -f release/vodia-mcp/RELEASE-NOTES-v0.13.2.md
test -f release/vodia-mcp/VODIA-WRITE-PAYLOADS.md
PACKAGE_VERSION="$(node -p "require('$TMP_DIR/release/vodia-mcp/package.json').version")"
[[ "$PACKAGE_VERSION" == "$VERSION" ]] || { echo "Expected ${VERSION}; package contains ${PACKAGE_VERSION}."; exit 1; }

echo "[4/8] Building and testing replacement..."
mkdir -p "$NEW_DIR"
cp -a release/vodia-mcp/. "$NEW_DIR/"
cd "$NEW_DIR"
npm ci --omit=dev
npm run audit:prod
npm run check
npm test
chown -R root:root "$NEW_DIR"
chmod -R a+rX "$NEW_DIR"

echo "[5/8] Backing up and switching the application..."
cp -a "$ENV_FILE" "$ENV_BACKUP"
cp -a "$SERVICE_FILE" "$SERVICE_BACKUP"
systemctl stop vodia-mcp
mv "$APP_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$APP_DIR"
SWITCHED="true"

echo "[6/8] Preserving persistent supervised-learning state..."
if ! grep -q '^StateDirectory=vodia-mcp$' "$SERVICE_FILE"; then
  sed -i '/^LogsDirectory=vodia-mcp$/a StateDirectory=vodia-mcp' "$SERVICE_FILE"
fi
chmod 0600 "$ENV_FILE"

echo "[7/8] Starting Vodia MCP ${VERSION}..."
systemctl daemon-reload
systemctl restart vodia-mcp
HEALTH_JSON=""
for attempt in {1..20}; do
  if HEALTH_JSON="$(curl -fsS http://127.0.0.1:3100/health)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH_JSON" ]] || { echo "Health endpoint did not respond."; exit 1; }
RUNNING_VERSION="$(node -e 'const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.version || ""))' "$HEALTH_JSON")"
[[ "$RUNNING_VERSION" == "$VERSION" ]] || { echo "Health check returned version ${RUNNING_VERSION:-unknown}."; exit 1; }

echo "[8/8] Upgrade completed successfully."
echo "$HEALTH_JSON"
echo "Rollback application retained at: $OLD_DIR"
echo "Configuration backups: $ENV_BACKUP and $SERVICE_BACKUP"
systemctl --no-pager --full status vodia-mcp
