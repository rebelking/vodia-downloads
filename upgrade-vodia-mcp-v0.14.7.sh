#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="0.14.7"
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
AUTH_DB_BACKUP="/var/backups/vodia-mcp-auth.db.before-${STAMP}"
SWITCHED="false"

cleanup() {
  find "$TMP_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$TMP_DIR" 2>/dev/null || true
}

existing_env_value() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=\"\([^\"]*\)\"$/\1/p" "$ENV_FILE" | head -n1
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
  echo "Run with sudo: sudo bash upgrade-vodia-mcp-v0.14.7.sh"
  exit 1
fi
for required in "$APP_DIR/package.json" "$ENV_FILE" "$SERVICE_FILE"; do
  [[ -e "$required" ]] || { echo "Required existing installation file is missing: $required"; exit 1; }
done

CURRENT_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
[[ "$CURRENT_VERSION" == "0.14.4" || "$CURRENT_VERSION" == "0.14.5" || "$CURRENT_VERSION" == "0.14.6" ]] || {
  echo "This upgrade expects v0.14.4, v0.14.5, or v0.14.6; found ${CURRENT_VERSION:-unknown}."
  exit 1
}

PUBLIC_BASE_URL_VALUE="${VODIA_MCP_PUBLIC_BASE_URL:-$(existing_env_value PUBLIC_BASE_URL)}"
if [[ -z "$PUBLIC_BASE_URL_VALUE" ]]; then
  read -r -p "Public MCP base URL [https://mcp-test.tryvodia.com]: " PUBLIC_BASE_URL_VALUE </dev/tty
  PUBLIC_BASE_URL_VALUE="${PUBLIC_BASE_URL_VALUE:-https://mcp-test.tryvodia.com}"
fi
[[ "$PUBLIC_BASE_URL_VALUE" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || { echo "PUBLIC_BASE_URL must be an HTTPS origin without a path."; exit 1; }
SESSION_SECRET_VALUE="$(existing_env_value SESSION_SECRET)"
SESSION_SECRET_VALUE="${SESSION_SECRET_VALUE:-$(openssl rand -base64 48 | tr -d '\n')}"
AUTH_DB_PATH="$(existing_env_value DB_PATH)"
AUTH_DB_PATH="${AUTH_DB_PATH:-/var/lib/vodia-mcp/auth.db}"

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
test -f release/vodia-mcp/RELEASE-NOTES-v0.14.7.md
test -f release/vodia-mcp/VODIA-WRITE-PAYLOADS.md
PACKAGE_VERSION="$(node -p "require('$TMP_DIR/release/vodia-mcp/package.json').version")"
[[ "$PACKAGE_VERSION" == "$VERSION" ]] || { echo "Expected ${VERSION}; package contains ${PACKAGE_VERSION}."; exit 1; }

echo "[4/8] Building and testing replacement..."
if ! command -v node >/dev/null 2>&1 || ! node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=13)?0:1)' 2>/dev/null; then
  echo "Installing Node.js 22 because Vodia MCP 0.14.7 requires Node.js 22.13+..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi
mkdir -p "$NEW_DIR"
cp -a release/vodia-mcp/. "$NEW_DIR/"
cd "$NEW_DIR"
npm ci --omit=dev
npm run audit:prod
npm run check
npm test
if ! command -v setpriv >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y util-linux
fi
chown -R root:root "$NEW_DIR"
chmod -R a+rX "$NEW_DIR"

echo "[5/8] Backing up and switching the application..."
cp -a "$ENV_FILE" "$ENV_BACKUP"
cp -a "$SERVICE_FILE" "$SERVICE_BACKUP"
if [[ -f "$AUTH_DB_PATH" ]]; then
  install -d -o root -g root -m 0700 /var/backups
  cp -a "$AUTH_DB_PATH" "$AUTH_DB_BACKUP"
  chown root:root "$AUTH_DB_BACKUP"
  chmod 0600 "$AUTH_DB_BACKUP"
fi
systemctl stop vodia-mcp
mv "$APP_DIR" "$OLD_DIR"
mv "$NEW_DIR" "$APP_DIR"
SWITCHED="true"
install -o root -g root -m 0755 "$APP_DIR/scripts/vodia-mcp-auth" /usr/local/bin/vodia-mcp-auth

echo "[6/8] Preserving state and configuring OAuth identity..."
if ! grep -q '^StateDirectory=vodia-mcp$' "$SERVICE_FILE"; then
  sed -i '/^LogsDirectory=vodia-mcp$/a StateDirectory=vodia-mcp' "$SERVICE_FILE"
fi
if ! grep -q '^PUBLIC_BASE_URL=' "$ENV_FILE"; then
  cat >> "$ENV_FILE" <<EOF
PUBLIC_BASE_URL="$PUBLIC_BASE_URL_VALUE"
DB_PATH="$AUTH_DB_PATH"
SESSION_SECRET="$SESSION_SECRET_VALUE"
ACCESS_TOKEN_TTL_SECONDS="3600"
REFRESH_TOKEN_TTL_SECONDS="2592000"
AUTH_CODE_TTL_SECONDS="120"
SESSION_TTL_SECONDS="43200"
ALLOWED_REDIRECT_URIS="https://claude.ai/api/mcp/auth_callback,https://claude.com/api/mcp/auth_callback"
ALLOW_LOOPBACK_REDIRECTS="true"
LEGACY_STATIC_TOKEN_ENABLED="true"
TRUST_PROXY="true"
OAUTH_TOOL_RESULT_LIMIT_BYTES="140000"
EOF
fi
install -d -o vodiamcp -g vodiamcp -m 0700 "$(dirname "$AUTH_DB_PATH")"
AUTH_USER_COUNT="$(runuser -u vodiamcp -- env DB_PATH="$AUTH_DB_PATH" node --disable-warning=ExperimentalWarning "$APP_DIR/auth-cli.js" list-users | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).length)))')"
if [[ "$AUTH_USER_COUNT" == "0" ]]; then
  OAUTH_ADMIN_EMAIL="${VODIA_OAUTH_ADMIN_EMAIL:-}"
  OAUTH_ADMIN_NAME="${VODIA_OAUTH_ADMIN_NAME:-}"
  OAUTH_ADMIN_PASSWORD="${VODIA_OAUTH_ADMIN_PASSWORD:-}"
  [[ -n "$OAUTH_ADMIN_EMAIL" ]] || read -r -p "Initial OAuth administrator email: " OAUTH_ADMIN_EMAIL </dev/tty
  [[ -n "$OAUTH_ADMIN_NAME" ]] || read -r -p "Initial OAuth administrator display name: " OAUTH_ADMIN_NAME </dev/tty
  if [[ -z "$OAUTH_ADMIN_PASSWORD" ]]; then read -r -s -p "Initial OAuth administrator password (12+ characters): " OAUTH_ADMIN_PASSWORD </dev/tty; echo; fi
  [[ ${#OAUTH_ADMIN_PASSWORD} -ge 12 ]] || { echo "OAuth administrator password must contain at least 12 characters."; exit 1; }
  runuser -u vodiamcp -- env DB_PATH="$AUTH_DB_PATH" VODIA_BOOTSTRAP_PASSWORD="$OAUTH_ADMIN_PASSWORD" node --disable-warning=ExperimentalWarning "$APP_DIR/auth-cli.js" create-admin --email "$OAUTH_ADMIN_EMAIL" --name "$OAUTH_ADMIN_NAME" >/dev/null
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
if [[ -f "$AUTH_DB_BACKUP" ]]; then echo "Authentication database backup: $AUTH_DB_BACKUP"; fi
systemctl --no-pager --full status vodia-mcp
