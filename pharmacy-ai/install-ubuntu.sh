#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-1.0.0}"
APP_NAME="${APP_NAME:-vodia-pharmacy-ai}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vodia-pharmacy-ai}"
PORT="${PORT:-3200}"
DOMAIN="${DOMAIN:-pharmacyhub.tryvodia.com}"
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"
NODE_MAJOR="${NODE_MAJOR:-22}"
REPO_URL="${REPO_URL:-https://github.com/rebelking/vodia-downloads.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_TMP="${REPO_TMP:-/tmp/vodia-downloads-install}"
PACKAGE_APP_SUBDIR="${PACKAGE_APP_SUBDIR:-pharmacy-ai/app}"
PACKAGE_VOICE_SUBDIR="${PACKAGE_VOICE_SUBDIR:-pharmacy-ai/voice-agent}"
STAFF_TRANSFER_DESTINATION="${STAFF_TRANSFER_DESTINATION:-700}"

echo "=================================================="
echo " Vodia Pharmacy AI Full Ubuntu Installer"
echo "=================================================="
echo "Version:       ${APP_VERSION}"
echo "Install dir:   ${INSTALL_DIR}"
echo "Port:          ${PORT}"
echo "Domain:        ${DOMAIN}"
echo "App name:      ${APP_NAME}"
echo "HTTPS:         ${ENABLE_HTTPS}"
echo "Repo:          ${REPO_URL}"
echo "Branch:        ${REPO_BRANCH}"
echo "Transfer dest: ${STAFF_TRANSFER_DESTINATION}"
echo "=================================================="

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this installer with sudo."
  echo ""
  echo "Example:"
  echo "  curl -fsSL https://raw.githubusercontent.com/rebelking/vodia-downloads/main/pharmacy-ai/install-ubuntu.sh | sudo bash"
  exit 1
fi

REAL_USER="${SUDO_USER:-ubuntu}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

if ! id "${REAL_USER}" >/dev/null 2>&1; then
  echo "ERROR: Could not find user ${REAL_USER}"
  exit 1
fi

echo "[1/15] Installing system packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  curl git rsync build-essential nginx sqlite3 ufw ca-certificates gnupg unzip openssl

echo "[2/15] Installing Node.js ${NODE_MAJOR}.x if needed..."
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
else
  echo "Node already installed: $(node -v)"
fi

echo "Node: $(node -v)"
echo "npm:  $(npm -v)"

echo "[3/15] Installing PM2..."
npm install -g pm2

echo "[4/15] Downloading installer repo..."
rm -rf "${REPO_TMP}"
git clone --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_TMP}"

SRC_APP_DIR="${REPO_TMP}/${PACKAGE_APP_SUBDIR}"
SRC_VOICE_DIR="${REPO_TMP}/${PACKAGE_VOICE_SUBDIR}"

if [ ! -f "${SRC_APP_DIR}/server.js" ]; then
  echo "ERROR: Missing ${SRC_APP_DIR}/server.js"
  echo "The GitHub installer package does not contain the full app."
  exit 1
fi

if [ ! -f "${SRC_APP_DIR}/package.json" ]; then
  echo "ERROR: Missing ${SRC_APP_DIR}/package.json"
  exit 1
fi

echo "[5/15] Backing up existing install if present..."
mkdir -p /opt/backups
if [ -d "${INSTALL_DIR}" ]; then
  BACKUP="/opt/backups/${APP_NAME}-backup-$(date +%F-%H%M%S).tgz"
  tar -czf "${BACKUP}" "${INSTALL_DIR}" --exclude="${INSTALL_DIR}/node_modules" || true
  echo "Backup created: ${BACKUP}"
fi

echo "[6/15] Installing full app files..."
mkdir -p "${INSTALL_DIR}"

rsync -av --delete \
  --exclude ".env" \
  --exclude "pharmacy.db" \
  --exclude "pharmacy.db-*" \
  --exclude "node_modules" \
  "${SRC_APP_DIR}/" \
  "${INSTALL_DIR}/"

if [ -d "${SRC_VOICE_DIR}" ]; then
  mkdir -p "${INSTALL_DIR}/voice-agent"
  rsync -av --delete \
    --exclude "*.local.js" \
    --exclude "*secret*.js" \
    "${SRC_VOICE_DIR}/" \
    "${INSTALL_DIR}/voice-agent/"
fi

chown -R "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}"

echo "[7/15] Creating .env if missing..."
PUBLIC_BASE_URL="http://${DOMAIN}"

if [ ! -f "${INSTALL_DIR}/.env" ]; then
  SESSION_SECRET="$(openssl rand -hex 32)"
  PHARMACY_SECRET="$(openssl rand -hex 32)"

  cat > "${INSTALL_DIR}/.env" <<ENVEOF
NODE_ENV=production
APP_MODE=demo
PORT=${PORT}
PUBLIC_BASE_URL=${PUBLIC_BASE_URL}

PORTAL_SESSION_SECRET=${SESSION_SECRET}
PHARMACY_SECRET=${PHARMACY_SECRET}
PHARMACY_API_SECRET=${PHARMACY_SECRET}
VODIA_PHARMACY_SECRET=${PHARMACY_SECRET}

SQLITE_PATH=${INSTALL_DIR}/pharmacy.db

PBX_BASE_URL=
PBX_ADMIN_USER=
PBX_ADMIN_PASS=

SMARTY_AUTH_ID=
SMARTY_AUTH_TOKEN=

SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_FROM=no-reply@${DOMAIN}
ENVEOF

  chmod 600 "${INSTALL_DIR}/.env"
  chown "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}/.env"

  echo ""
  echo "Generated PHARMACY_SECRET:"
  echo "${PHARMACY_SECRET}"
  echo ""
  echo "Save this secret. It is required for Vodia PBX / AI webhook calls."
else
  echo ".env already exists. Keeping existing .env."
fi

echo "[8/15] Loading install environment values..."
PHARMACY_SECRET_VALUE="$(grep -E '^(PHARMACY_SECRET|PHARMACY_API_SECRET)=' "${INSTALL_DIR}/.env" | head -1 | cut -d= -f2- || true)"
PUBLIC_URL_VALUE="$(grep '^PUBLIC_BASE_URL=' "${INSTALL_DIR}/.env" | cut -d= -f2- || true)"

if [ -z "${PHARMACY_SECRET_VALUE}" ]; then
  PHARMACY_SECRET_VALUE="$(openssl rand -hex 32)"
  cat >> "${INSTALL_DIR}/.env" <<ENVEOF
PHARMACY_SECRET=${PHARMACY_SECRET_VALUE}
PHARMACY_API_SECRET=${PHARMACY_SECRET_VALUE}
VODIA_PHARMACY_SECRET=${PHARMACY_SECRET_VALUE}
ENVEOF
fi

if [ -z "${PUBLIC_URL_VALUE}" ]; then
  PUBLIC_URL_VALUE="${PUBLIC_BASE_URL}"
  echo "PUBLIC_BASE_URL=${PUBLIC_URL_VALUE}" >> "${INSTALL_DIR}/.env"
fi

echo "[9/15] Creating clean empty database if missing..."
if [ ! -f "${INSTALL_DIR}/pharmacy.db" ]; then
  if [ -s "${INSTALL_DIR}/schema.sql" ]; then
    sqlite3 "${INSTALL_DIR}/pharmacy.db" < "${INSTALL_DIR}/schema.sql"
    sqlite3 "${INSTALL_DIR}/pharmacy.db" "PRAGMA journal_mode=WAL;" >/dev/null || true
    echo "Created DB from schema.sql: ${INSTALL_DIR}/pharmacy.db"
  else
    echo "WARNING: No schema.sql found. Creating blank DB."
    sqlite3 "${INSTALL_DIR}/pharmacy.db" "PRAGMA journal_mode=WAL;" >/dev/null || true
  fi

  chown "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}/pharmacy.db" 2>/dev/null || true
  chmod 600 "${INSTALL_DIR}/pharmacy.db" 2>/dev/null || true
else
  echo "Database already exists. Keeping ${INSTALL_DIR}/pharmacy.db"
fi

echo "[10/15] Generating local Vodia Voice Agent script..."
VOICE_TEMPLATE="${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.template.js"
VOICE_LOCAL="${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.local.js"

if [ -f "${VOICE_TEMPLATE}" ]; then
  mkdir -p "${INSTALL_DIR}/voice-agent"

  sed \
    -e "s|__PHARMACY_API_SECRET__|${PHARMACY_SECRET_VALUE}|g" \
    -e "s|__PHARMACY_BASE_URL__|${PUBLIC_URL_VALUE}|g" \
    -e "s|__STAFF_TRANSFER_DESTINATION__|${STAFF_TRANSFER_DESTINATION}|g" \
    "${VOICE_TEMPLATE}" \
    > "${VOICE_LOCAL}"

  chmod 600 "${VOICE_LOCAL}"
  chown "${REAL_USER}:${REAL_USER}" "${VOICE_LOCAL}"

  echo "Voice Agent script generated:"
  echo "  ${VOICE_LOCAL}"
else
  echo "WARNING: Voice Agent template not found:"
  echo "  ${VOICE_TEMPLATE}"
fi

echo "[11/15] Installing npm dependencies..."
cd "${INSTALL_DIR}"
sudo -u "${REAL_USER}" npm install --omit=dev

echo "[12/15] Creating/resetting portal admin login..."
PORTAL_ADMIN_USERNAME="${PORTAL_ADMIN_USERNAME:-admin@vodia.local}"
PORTAL_ADMIN_PASSWORD="${PORTAL_ADMIN_PASSWORD:-}"

if [ -z "${PORTAL_ADMIN_PASSWORD}" ]; then
  PORTAL_ADMIN_PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)!A1"
  PORTAL_ADMIN_PASSWORD_GENERATED="true"
else
  PORTAL_ADMIN_PASSWORD_GENERATED="false"
fi

export PORTAL_ADMIN_USERNAME
export PORTAL_ADMIN_PASSWORD
export SQLITE_PATH="${INSTALL_DIR}/pharmacy.db"

cd "${INSTALL_DIR}"

node <<'NODE'
require("dotenv").config({ path: "/opt/vodia-pharmacy-ai/.env" });

const sqlite3 = require("sqlite3").verbose();

let bcrypt;
try {
  bcrypt = require("bcrypt");
} catch (e) {
  bcrypt = require("bcryptjs");
}

const dbPath = process.env.SQLITE_PATH || "/opt/vodia-pharmacy-ai/pharmacy.db";
const username = process.env.PORTAL_ADMIN_USERNAME || "admin@vodia.local";
const password = process.env.PORTAL_ADMIN_PASSWORD || "";

if (!password) {
  console.error("ERROR: Portal admin password missing.");
  process.exit(1);
}

const db = new sqlite3.Database(dbPath);

function run(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.run(sql, params, function (err) {
      err ? reject(err) : resolve(this);
    });
  });
}

function get(sql, params = []) {
  return new Promise((resolve, reject) => {
    db.get(sql, params, (err, row) => err ? reject(err) : resolve(row));
  });
}

(async () => {
  const hash = await bcrypt.hash(password, 10);
  const now = new Date().toISOString();

  const existing = await get(
    "SELECT id FROM portal_users WHERE username = ? LIMIT 1",
    [username]
  );

  if (existing && existing.id) {
    await run(
      `UPDATE portal_users
       SET name = ?,
           email = ?,
           password_hash = ?,
           role = 'admin',
           active = 1,
           revoked_at = NULL,
           updated_at = ?
       WHERE id = ?`,
      ["Portal Admin", username, hash, now, existing.id]
    );

    console.log("Portal admin updated: " + username);
  } else {
    await run(
      `INSERT INTO portal_users
       (name, email, username, password_hash, role, active, created_at, updated_at)
       VALUES (?, ?, ?, ?, 'admin', 1, CURRENT_TIMESTAMP, ?)`,
      ["Portal Admin", username, username, hash, now]
    );

    console.log("Portal admin created: " + username);
  }

  db.close();
})().catch(err => {
  console.error("ERROR creating portal admin:", err.message);
  db.close();
  process.exit(1);
});
NODE

chown "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}/pharmacy.db" "${INSTALL_DIR}"/pharmacy.db-* 2>/dev/null || true
chmod 600 "${INSTALL_DIR}/pharmacy.db" 2>/dev/null || true

PORTAL_LOGIN_FILE="/root/vodia-pharmacy-ai-portal-login.txt"
cat > "${PORTAL_LOGIN_FILE}" <<LOGIN_EOF
Vodia Pharmacy AI Portal Login
URL: https://${DOMAIN}/portal
Username: ${PORTAL_ADMIN_USERNAME}
Password: ${PORTAL_ADMIN_PASSWORD}
LOGIN_EOF
chmod 600 "${PORTAL_LOGIN_FILE}"

echo "Portal admin login saved to:"
echo "  ${PORTAL_LOGIN_FILE}"


echo "[13/15] Starting PM2 app..."
sudo -u "${REAL_USER}" pm2 delete "${APP_NAME}" >/dev/null 2>&1 || true
sudo -u "${REAL_USER}" bash -lc "cd '${INSTALL_DIR}' && pm2 start server.js --name '${APP_NAME}' --update-env"
sudo -u "${REAL_USER}" pm2 save

echo "[14/15] Configuring PM2 startup..."
pm2 startup systemd -u "${REAL_USER}" --hp "${REAL_HOME}" >/dev/null 2>&1 || true
sudo -u "${REAL_USER}" pm2 save >/dev/null 2>&1 || true

echo "[15/15] Configuring Nginx..."
cat > /etc/nginx/conf.d/vodia-websocket-map.conf <<'NGINXMAPEOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
NGINXMAPEOF

cat > /etc/nginx/sites-available/vodia-pharmacy-ai <<NGINXEOF
server {
    listen 80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 180s;
        proxy_send_timeout 180s;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/vodia-pharmacy-ai /etc/nginx/sites-enabled/vodia-pharmacy-ai

if [ -L /etc/nginx/sites-enabled/default ]; then
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl reload nginx

ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 'Nginx Full' >/dev/null 2>&1 || true

if [ "${ENABLE_HTTPS}" = "true" ]; then
  echo "Installing Certbot and requesting HTTPS certificate..."
  DEBIAN_FRONTEND=noninteractive apt install -y certbot python3-certbot-nginx

  certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect || {
    echo "WARNING: Certbot failed. HTTP install still completed."
    echo "Retry later:"
    echo "  sudo certbot --nginx -d ${DOMAIN}"
  }

  if grep -q "PUBLIC_BASE_URL=http://${DOMAIN}" "${INSTALL_DIR}/.env"; then
    sed -i "s|PUBLIC_BASE_URL=http://${DOMAIN}|PUBLIC_BASE_URL=https://${DOMAIN}|g" "${INSTALL_DIR}/.env"

    if [ -f "${VOICE_TEMPLATE}" ]; then
      PHARMACY_SECRET_VALUE="$(grep -E '^(PHARMACY_SECRET|PHARMACY_API_SECRET)=' "${INSTALL_DIR}/.env" | head -1 | cut -d= -f2- || true)"
      PUBLIC_URL_VALUE="https://${DOMAIN}"

      sed \
        -e "s|__PHARMACY_API_SECRET__|${PHARMACY_SECRET_VALUE}|g" \
        -e "s|__PHARMACY_BASE_URL__|${PUBLIC_URL_VALUE}|g" \
        -e "s|__STAFF_TRANSFER_DESTINATION__|${STAFF_TRANSFER_DESTINATION}|g" \
        "${VOICE_TEMPLATE}" \
        > "${VOICE_LOCAL}"

      chmod 600 "${VOICE_LOCAL}"
      chown "${REAL_USER}:${REAL_USER}" "${VOICE_LOCAL}"
    fi

    sudo -u "${REAL_USER}" pm2 restart "${APP_NAME}" --update-env
  fi
fi

echo ""
echo "=================================================="
echo " Install complete"
echo "=================================================="
echo "Local health:"
echo "  curl http://127.0.0.1:${PORT}/health"
echo ""
echo "Public health:"
if [ "${ENABLE_HTTPS}" = "true" ]; then
  echo "  curl https://${DOMAIN}/health"
  echo "  https://${DOMAIN}/portal"
else
  echo "  curl http://${DOMAIN}/health"
  echo "  http://${DOMAIN}/portal"
fi
echo ""
echo "Portal:"
if [ "${ENABLE_HTTPS}" = "true" ]; then
  echo "  https://${DOMAIN}/portal"
else
  echo "  http://${DOMAIN}/portal"
fi
echo ""
echo "Portal admin login:"
echo "  Username: ${PORTAL_ADMIN_USERNAME}"
echo "  Password: ${PORTAL_ADMIN_PASSWORD}"
echo "  Saved to: /root/vodia-pharmacy-ai-portal-login.txt"
echo ""
echo "App folder:"
echo "  ${INSTALL_DIR}"
echo ""
echo "Database:"
echo "  ${INSTALL_DIR}/pharmacy.db"
echo ""
echo "Voice Agent template:"
echo "  ${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.template.js"
echo ""
echo "Voice Agent ready-to-copy local script:"
echo "  ${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.local.js"
echo ""
echo "Voice Agent portal copy/download page:"
if [ "${ENABLE_HTTPS}" = "true" ]; then
  echo "  https://${DOMAIN}/portal/voice-agent"
else
  echo "  http://${DOMAIN}/portal/voice-agent"
fi
echo ""
echo "Important:"
echo "  Copy the local script into the Vodia Voice Agent JavaScript field."
echo "  Add the OpenAI API key in the Vodia Voice Agent OpenAI key field."
echo "  Do NOT paste the OpenAI key into the script."
echo ""
echo "PM2:"
echo "  pm2 status"
echo "  pm2 logs ${APP_NAME} --lines 80"
echo "=================================================="
