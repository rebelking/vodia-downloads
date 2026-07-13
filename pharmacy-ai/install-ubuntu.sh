#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-1.1.0}"
APP_NAME="${APP_NAME:-vodia-pharmacy-ai}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vodia-pharmacy-ai}"
PORT="${PORT:-3200}"
DOMAIN="${DOMAIN:-}"
ENABLE_HTTPS="${ENABLE_HTTPS:-true}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
NODE_MAJOR="${NODE_MAJOR:-22}"
REPO_URL="${REPO_URL:-https://github.com/rebelking/vodia-downloads.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_TMP="${REPO_TMP:-/tmp/vodia-downloads-install}"
PACKAGE_APP_SUBDIR="${PACKAGE_APP_SUBDIR:-pharmacy-ai/app}"
PACKAGE_VOICE_SUBDIR="${PACKAGE_VOICE_SUBDIR:-pharmacy-ai/voice-agent}"
STAFF_TRANSFER_DESTINATION="${STAFF_TRANSFER_DESTINATION:-700}"
ADMIN_NAME="${ADMIN_NAME:-}"
ADMIN_USERNAME="${ADMIN_USERNAME:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
SKIP_ADMIN_CREATE="${SKIP_ADMIN_CREATE:-false}"
SHOW_GENERATED_SECRET="${SHOW_GENERATED_SECRET:-false}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  echo "INFO: $*"
}

is_valid_domain() {
  local value="$1"

  [[ -n "${value}" ]] || return 1
  [[ "${value}" != .* ]] || return 1
  [[ "${value}" != *"://"* ]] || return 1
  [[ "${value}" != */* ]] || return 1
  [[ "${value}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

prompt_required() {
  local variable_name="$1"
  local prompt_text="$2"
  local secret_mode="${3:-false}"
  local current_value="${!variable_name:-}"

  if [[ -n "${current_value}" ]]; then
    return 0
  fi

  [[ -r /dev/tty ]] || die "${variable_name} is required. Supply it as an environment variable."

  if [[ "${secret_mode}" == "true" ]]; then
    IFS= read -r -s -p "${prompt_text}" current_value < /dev/tty
    echo > /dev/tty
  else
    IFS= read -r -p "${prompt_text}" current_value < /dev/tty
  fi

  printf -v "${variable_name}" '%s' "${current_value}"
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  python3 - "${file}" "${key}" "${value}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = path.read_text().splitlines() if path.exists() else []
output = []
found = False

for line in lines:
    if line.startswith(key + "="):
        output.append(f"{key}={value}")
        found = True
    else:
        output.append(line)

if not found:
    output.append(f"{key}={value}")

path.write_text("\n".join(output) + "\n")
PY
}

validate_voice_template() {
  local file="$1"

  [[ -s "${file}" ]] || die "Voice Agent template is missing or empty: ${file}"

  if grep -n '```' "${file}" >/dev/null; then
    grep -n '```' "${file}" >&2 || true
    die "Voice Agent template contains Markdown code fences."
  fi

  grep -q '__PHARMACY_API_SECRET__' "${file}" \
    || die "Voice Agent template is missing __PHARMACY_API_SECRET__."
  grep -q '__PHARMACY_BASE_URL__' "${file}" \
    || die "Voice Agent template is missing __PHARMACY_BASE_URL__."
  grep -q '__STAFF_TRANSFER_DESTINATION__' "${file}" \
    || die "Voice Agent template is missing __STAFF_TRANSFER_DESTINATION__."

  [[ "$(grep -o '__PHARMACY_API_SECRET__' "${file}" | wc -l)" -eq 1 ]] \
    || die "Voice Agent template must contain exactly one API-secret placeholder."
  [[ "$(grep -o '__STAFF_TRANSFER_DESTINATION__' "${file}" | wc -l)" -eq 1 ]] \
    || die "Voice Agent template must contain exactly one transfer placeholder."
  [[ "$(grep -o '__PHARMACY_BASE_URL__' "${file}" | wc -l)" -eq 5 ]] \
    || die "Voice Agent template must contain five backend base-URL placeholders."

  if grep -Eq 'var pharmacyApiSecret = "[0-9a-fA-F]{32,}"' "${file}"; then
    die "Voice Agent template appears to contain a live Pharmacy API secret."
  fi

  if grep -Eq 'https://(pen\.tryvodia\.com|pharmacy\.audiomercy\.com)' "${file}"; then
    die "Voice Agent template contains a hard-coded deployment hostname."
  fi

  local required_markers=(
    'function checkDrugClassification'
    'function handleLookupPreviousPharmacyRequest'
    'function handleLeaveStatusCallbackNote'
    'function handleSearchPharmacyLocations'
    'function handleSelectPharmacyLocation'
    'function handleTransferCall(ws, callId, args)'
    'function handleEndCall(ws, callId, args)'
    'var pharmacyLocationSearchUrl'
    'call.dial("openai")'
  )

  local marker
  for marker in "${required_markers[@]}"; do
    grep -Fq "${marker}" "${file}" \
      || die "Voice Agent template is missing required marker: ${marker}"
  done

  node --check "${file}" >/dev/null \
    || die "Voice Agent template failed JavaScript syntax validation."
}

validate_generated_voice_script() {
  local file="$1"
  local expected_public_url="$2"

  [[ -s "${file}" ]] || die "Generated Voice Agent script is missing or empty: ${file}"

  if grep -n '```' "${file}" >/dev/null; then
    grep -n '```' "${file}" >&2 || true
    die "Generated Voice Agent script contains Markdown code fences."
  fi

  if grep -Eq '__PHARMACY_API_SECRET__|__PHARMACY_BASE_URL__|__STAFF_TRANSFER_DESTINATION__' "${file}"; then
    die "Generated Voice Agent script still contains unresolved installer placeholders."
  fi

  if grep -Fq 'https://./' "${file}" || grep -Fq 'https://.tryvodia.com' "${file}"; then
    die "Generated Voice Agent script contains a malformed hostname."
  fi

  grep -Fq "${expected_public_url}/api/ai/refill-intake" "${file}" \
    || die "Generated Voice Agent script does not contain the expected refill-intake URL."
  grep -Fq "${expected_public_url}/api/ai/pharmacy-location-search" "${file}" \
    || die "Generated Voice Agent script does not contain the expected pharmacy-location URL."

  node --check "${file}" >/dev/null \
    || die "Generated Voice Agent script failed JavaScript syntax validation."
}

render_voice_script() {
  local template_file="$1"
  local output_file="$2"
  local public_url="$3"
  local pharmacy_secret="$4"
  local transfer_destination="$5"

  python3 - "${template_file}" "${output_file}" "${public_url}" "${pharmacy_secret}" "${transfer_destination}" <<'PY'
from pathlib import Path
import sys

template_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
public_url = sys.argv[3].rstrip("/")
pharmacy_secret = sys.argv[4]
transfer_destination = sys.argv[5]

text = template_path.read_text()

replacements = {
    "__PHARMACY_API_SECRET__": pharmacy_secret,
    "__PHARMACY_BASE_URL__": public_url,
    "__STAFF_TRANSFER_DESTINATION__": transfer_destination,
}

for token, value in replacements.items():
    if token not in text:
        raise SystemExit(f"Missing placeholder in template: {token}")
    text = text.replace(token, value)

output_path.parent.mkdir(parents=True, exist_ok=True)
output_path.write_text(text)
PY

  chmod 600 "${output_file}"
  chown "${REAL_USER}:${REAL_USER}" "${output_file}"

  validate_generated_voice_script "${output_file}" "${public_url}"
}

check_route_status() {
  local label="$1"
  local url="$2"
  local code

  code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" || true)"

  case "${code}" in
    200|302|303|401|403)
      echo "GOOD: ${label} route exists (HTTP ${code})"
      ;;
    *)
      die "${label} route failed verification (HTTP ${code})"
      ;;
  esac
}

if [[ "$(id -u)" -ne 0 ]]; then
  die "Run this installer with sudo."
fi

REAL_USER="${SUDO_USER:-ubuntu}"
REAL_HOME="$(eval echo "~${REAL_USER}")"

id "${REAL_USER}" >/dev/null 2>&1 \
  || die "Could not find installation user: ${REAL_USER}"

prompt_required DOMAIN "Enter pharmacy FQDN (example: pen.tryvodia.com): "

is_valid_domain "${DOMAIN}" \
  || die "Invalid domain '${DOMAIN}'. Enter only a complete hostname such as pen.tryvodia.com."

if [[ "${ENABLE_HTTPS}" != "true" && "${ENABLE_HTTPS}" != "false" ]]; then
  die "ENABLE_HTTPS must be true or false."
fi

if [[ "${ENABLE_HTTPS}" == "true" && -z "${LETSENCRYPT_EMAIL}" ]]; then
  LETSENCRYPT_EMAIL="admin@${DOMAIN}"
fi

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
echo "Admin setup:   $([[ "${SKIP_ADMIN_CREATE}" == "true" ]] && echo skipped || echo enabled)"
echo "=================================================="

echo "[1/16] Installing system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl git rsync build-essential nginx sqlite3 ufw ca-certificates gnupg unzip openssl

echo "[2/16] Validating DNS..."
DNS_IPS="$(getent ahostsv4 "${DOMAIN}" | awk '{print $1}' | sort -u || true)"

if [[ -z "${DNS_IPS}" ]]; then
  die "DNS does not resolve for ${DOMAIN}. Create the A record first."
fi

SERVER_PUBLIC_IP="$(
  curl -4 -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
  || curl -4 -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
  || true
)"

echo "Server public IP: ${SERVER_PUBLIC_IP:-unknown}"
echo "DNS IPv4 address(es):"
echo "${DNS_IPS}"

if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  [[ -n "${SERVER_PUBLIC_IP}" ]] \
    || die "Could not determine this server's public IPv4 address."

  echo "${DNS_IPS}" | grep -Fxq "${SERVER_PUBLIC_IP}" \
    || die "${DOMAIN} does not point to this server. Correct DNS before requesting HTTPS."
fi

echo "[3/16] Installing Node.js ${NODE_MAJOR}.x if needed..."
if ! command -v node >/dev/null 2>&1; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
else
  echo "Node already installed: $(node -v)"
fi

echo "Node: $(node -v)"
echo "npm:  $(npm -v)"

echo "[4/16] Installing PM2..."
npm install -g pm2

echo "[5/16] Downloading installer repository..."
rm -rf "${REPO_TMP}"
git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_TMP}"

SRC_APP_DIR="${REPO_TMP}/${PACKAGE_APP_SUBDIR}"
SRC_VOICE_DIR="${REPO_TMP}/${PACKAGE_VOICE_SUBDIR}"
SRC_VOICE_TEMPLATE="${SRC_VOICE_DIR}/vodia-pharmacy-ai-voice-agent.template.js"

echo "[6/16] Validating application package..."
required_files=(
  "${SRC_APP_DIR}/server.js"
  "${SRC_APP_DIR}/package.json"
  "${SRC_APP_DIR}/schema.sql"
  "${SRC_APP_DIR}/routes/adminSettings.js"
  "${SRC_APP_DIR}/voice-agent-portal-routes.js"
  "${SRC_VOICE_TEMPLATE}"
)

for required_file in "${required_files[@]}"; do
  [[ -f "${required_file}" ]] || die "Required package file is missing: ${required_file}"
done

grep -Fq "app.use('/portal/settings', adminSettingsRouter)" "${SRC_APP_DIR}/server.js" \
  || die "Settings route is not mounted in server.js."
grep -Fq "installVoiceAgentPortalRoutes(app);" "${SRC_APP_DIR}/server.js" \
  || die "Voice Agent portal route is not mounted in server.js."
grep -Fq '<a href="/portal/settings">Settings</a>' "${SRC_APP_DIR}/portal.js" \
  || die "Settings navigation link is missing from portal.js."
grep -Fq '<a href="/portal/voice-agent">Voice Agent</a>' "${SRC_APP_DIR}/portal.js" \
  || die "Voice Agent navigation link is missing from portal.js."

validate_voice_template "${SRC_VOICE_TEMPLATE}"
echo "GOOD: Voice Agent template passed syntax and regression checks."

SCHEMA_TEST_DB="$(mktemp /tmp/vodia-pharmacy-schema.XXXXXX.db)"
trap 'rm -f "${SCHEMA_TEST_DB:-}"' EXIT

if ! sqlite3 "${SCHEMA_TEST_DB}" < "${SRC_APP_DIR}/schema.sql"; then
  die "schema.sql failed clean-database validation."
fi

rm -f "${SCHEMA_TEST_DB}"
SCHEMA_TEST_DB=""
echo "GOOD: schema.sql passed clean-database validation."

echo "[7/16] Backing up existing installation..."
mkdir -p /opt/backups

if [[ -d "${INSTALL_DIR}" ]]; then
  BACKUP="/opt/backups/${APP_NAME}-backup-$(date +%F-%H%M%S).tgz"
  tar --exclude="${INSTALL_DIR}/node_modules" -czf "${BACKUP}" "${INSTALL_DIR}" || true
  echo "Backup created: ${BACKUP}"
fi

echo "[8/16] Installing application files..."
mkdir -p "${INSTALL_DIR}"

rsync -av --delete \
  --exclude ".env" \
  --exclude "pharmacy.db" \
  --exclude "pharmacy.db-*" \
  --exclude "node_modules" \
  --exclude "data/" \
  "${SRC_APP_DIR}/" \
  "${INSTALL_DIR}/"

mkdir -p "${INSTALL_DIR}/voice-agent"

rsync -av --delete \
  --exclude "*.local.js" \
  --exclude "*secret*.js" \
  "${SRC_VOICE_DIR}/" \
  "${INSTALL_DIR}/voice-agent/"

chown -R "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}"

echo "[9/16] Creating and updating environment configuration..."
ENV_FILE="${INSTALL_DIR}/.env"
SECRETS_FILE="/root/vodia-pharmacy-ai-install-secrets.txt"

if [[ ! -f "${ENV_FILE}" ]]; then
  SESSION_SECRET="$(openssl rand -hex 32)"
  PHARMACY_SECRET_VALUE="$(openssl rand -hex 32)"

  cat > "${ENV_FILE}" <<ENVEOF
NODE_ENV=production
APP_MODE=demo
PORT=${PORT}
PUBLIC_BASE_URL=http://${DOMAIN}
PHARMACY_PUBLIC_BASE_URL=http://${DOMAIN}

PORTAL_SESSION_SECRET=${SESSION_SECRET}
PHARMACY_SECRET=${PHARMACY_SECRET_VALUE}
PHARMACY_API_SECRET=${PHARMACY_SECRET_VALUE}
VODIA_PHARMACY_SECRET=${PHARMACY_SECRET_VALUE}

SQLITE_PATH=${INSTALL_DIR}/pharmacy.db
DB_PATH=${INSTALL_DIR}/pharmacy.db

PBX_BASE_URL=
PBX_ADMIN_USER=
PBX_ADMIN_PASS=

SMARTY_AUTH_ID=
SMARTY_AUTH_TOKEN=

SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=false
SMTP_USER=
SMTP_PASS=
SMTP_FROM=no-reply@${DOMAIN}
EMAIL_FROM=no-reply@${DOMAIN}

STAFF_TRANSFER_DESTINATION=${STAFF_TRANSFER_DESTINATION}
ENVEOF
else
  echo ".env already exists. Preserving secrets and local settings."

  PHARMACY_SECRET_VALUE="$(
    grep -E '^(PHARMACY_SECRET|PHARMACY_API_SECRET)=' "${ENV_FILE}" \
      | head -1 \
      | cut -d= -f2- \
      || true
  )"

  if [[ -z "${PHARMACY_SECRET_VALUE}" ]]; then
    PHARMACY_SECRET_VALUE="$(openssl rand -hex 32)"
  fi

  SESSION_SECRET="$(
    grep '^PORTAL_SESSION_SECRET=' "${ENV_FILE}" \
      | head -1 \
      | cut -d= -f2- \
      || true
  )"

  if [[ -z "${SESSION_SECRET}" ]]; then
    SESSION_SECRET="$(openssl rand -hex 32)"
  fi
fi

set_env_value "${ENV_FILE}" PORT "${PORT}"
set_env_value "${ENV_FILE}" PUBLIC_BASE_URL "http://${DOMAIN}"
set_env_value "${ENV_FILE}" PHARMACY_PUBLIC_BASE_URL "http://${DOMAIN}"
set_env_value "${ENV_FILE}" PORTAL_SESSION_SECRET "${SESSION_SECRET}"
set_env_value "${ENV_FILE}" PHARMACY_SECRET "${PHARMACY_SECRET_VALUE}"
set_env_value "${ENV_FILE}" PHARMACY_API_SECRET "${PHARMACY_SECRET_VALUE}"
set_env_value "${ENV_FILE}" VODIA_PHARMACY_SECRET "${PHARMACY_SECRET_VALUE}"
set_env_value "${ENV_FILE}" SQLITE_PATH "${INSTALL_DIR}/pharmacy.db"
set_env_value "${ENV_FILE}" DB_PATH "${INSTALL_DIR}/pharmacy.db"
set_env_value "${ENV_FILE}" STAFF_TRANSFER_DESTINATION "${STAFF_TRANSFER_DESTINATION}"

chmod 600 "${ENV_FILE}"
chown "${REAL_USER}:${REAL_USER}" "${ENV_FILE}"

cat > "${SECRETS_FILE}" <<SECRETEOF
PHARMACY_SECRET=${PHARMACY_SECRET_VALUE}
PORTAL_SESSION_SECRET=${SESSION_SECRET}
SECRETEOF

chmod 600 "${SECRETS_FILE}"

if [[ "${SHOW_GENERATED_SECRET}" == "true" ]]; then
  echo "Generated PHARMACY_SECRET: ${PHARMACY_SECRET_VALUE}"
else
  echo "Generated secrets saved securely to: ${SECRETS_FILE}"
fi

echo "[10/16] Creating clean database if missing..."
if [[ ! -f "${INSTALL_DIR}/pharmacy.db" ]]; then
  sqlite3 "${INSTALL_DIR}/pharmacy.db" < "${INSTALL_DIR}/schema.sql"
  sqlite3 "${INSTALL_DIR}/pharmacy.db" "PRAGMA journal_mode=WAL;" >/dev/null
  chown "${REAL_USER}:${REAL_USER}" "${INSTALL_DIR}/pharmacy.db"
  chmod 600 "${INSTALL_DIR}/pharmacy.db"
  echo "Created database: ${INSTALL_DIR}/pharmacy.db"
else
  echo "Database already exists. Preserving ${INSTALL_DIR}/pharmacy.db"
fi

echo "[11/16] Generating and validating Vodia Voice Agent script..."
VOICE_TEMPLATE="${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.template.js"
VOICE_LOCAL="${INSTALL_DIR}/voice-agent/vodia-pharmacy-ai-voice-agent.local.js"

validate_voice_template "${VOICE_TEMPLATE}"
render_voice_script \
  "${VOICE_TEMPLATE}" \
  "${VOICE_LOCAL}" \
  "http://${DOMAIN}" \
  "${PHARMACY_SECRET_VALUE}" \
  "${STAFF_TRANSFER_DESTINATION}"

echo "GOOD: Generated Voice Agent script passed syntax and URL validation."

echo "[12/16] Installing npm dependencies..."
cd "${INSTALL_DIR}"
sudo -u "${REAL_USER}" npm install --omit=dev

echo "[13/16] Creating the initial administrator..."
if [[ "${SKIP_ADMIN_CREATE}" == "true" ]]; then
  echo "Initial administrator creation skipped by SKIP_ADMIN_CREATE=true."
else
  EXISTING_ADMIN_COUNT="$(
    sqlite3 "${INSTALL_DIR}/pharmacy.db" \
      "SELECT COUNT(*) FROM portal_users WHERE role='admin' AND active=1;" \
      2>/dev/null \
      || echo 0
  )"

  if [[ "${EXISTING_ADMIN_COUNT}" =~ ^[1-9][0-9]*$ ]] \
     && [[ -z "${ADMIN_USERNAME}" ]] \
     && [[ -z "${ADMIN_PASSWORD}" ]]; then
    echo "An active administrator already exists. Preserving it."
  else
    prompt_required ADMIN_NAME "Admin full name: "
    prompt_required ADMIN_USERNAME "Admin username: "

    [[ -n "${ADMIN_NAME}" ]] || die "Admin full name cannot be empty."
    [[ -n "${ADMIN_USERNAME}" ]] || die "Admin username cannot be empty."

    while true; do
      ADMIN_PASSWORD=""
      ADMIN_PASSWORD_CONFIRM=""

      prompt_required ADMIN_PASSWORD "Admin password: " true

      if [[ "${#ADMIN_PASSWORD}" -lt 10 ]]; then
        echo "ERROR: Admin password must contain at least 10 characters."
        echo "Please enter the password again."
        echo
        continue
      fi

      prompt_required ADMIN_PASSWORD_CONFIRM "Re-enter admin password: " true

      if [[ "${ADMIN_PASSWORD}" != "${ADMIN_PASSWORD_CONFIRM}" ]]; then
        echo "ERROR: Passwords do not match."
        echo "Please enter both passwords again."
        echo
        continue
      fi

      break
    done

    sudo -u "${REAL_USER}" env \
      ADMIN_NAME="${ADMIN_NAME}" \
      ADMIN_USERNAME="${ADMIN_USERNAME}" \
      ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
      node <<'NODE'
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcrypt');

const name = String(process.env.ADMIN_NAME || '').trim();
const username = String(process.env.ADMIN_USERNAME || '').trim();
const password = String(process.env.ADMIN_PASSWORD || '');

if (!name || !username || !password) {
  console.error('Administrator values are incomplete.');
  process.exit(1);
}

const db = new sqlite3.Database('./pharmacy.db');
const passwordHash = bcrypt.hashSync(password, 12);

db.get(
  'SELECT id FROM portal_users WHERE username = ?',
  [username],
  function (selectError, row) {
    if (selectError) {
      console.error(selectError.message);
      return db.close(() => process.exit(1));
    }

    if (row) {
      db.run(
        `UPDATE portal_users
         SET name = ?, password_hash = ?, role = 'admin', active = 1
         WHERE username = ?`,
        [name, passwordHash, username],
        function (updateError) {
          if (updateError) {
            console.error(updateError.message);
            return db.close(() => process.exit(1));
          }

          console.log(`Administrator "${username}" updated.`);
          db.close();
        }
      );
      return;
    }

    db.run(
      `INSERT INTO portal_users
       (name, email, username, password_hash, role, active)
       VALUES (?, NULL, ?, ?, 'admin', 1)`,
      [name, username, passwordHash],
      function (insertError) {
        if (insertError) {
          console.error(insertError.message);
          return db.close(() => process.exit(1));
        }

        console.log(`Administrator "${username}" created.`);
        db.close();
      }
    );
  }
);
NODE
  fi
fi

unset ADMIN_PASSWORD

echo "[14/16] Starting application with PM2..."
sudo -u "${REAL_USER}" pm2 delete "${APP_NAME}" >/dev/null 2>&1 || true
sudo -u "${REAL_USER}" bash -lc \
  "cd '${INSTALL_DIR}' && pm2 start server.js --name '${APP_NAME}' --update-env"
sudo -u "${REAL_USER}" pm2 save

pm2 startup systemd -u "${REAL_USER}" --hp "${REAL_HOME}" >/dev/null 2>&1 || true
sudo -u "${REAL_USER}" pm2 save >/dev/null 2>&1 || true

echo "[15/16] Configuring Nginx and HTTPS..."
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

ln -sf \
  /etc/nginx/sites-available/vodia-pharmacy-ai \
  /etc/nginx/sites-enabled/vodia-pharmacy-ai

rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl reload nginx

ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow 'Nginx Full' >/dev/null 2>&1 || true

FINAL_PUBLIC_URL="http://${DOMAIN}"

if [[ "${ENABLE_HTTPS}" == "true" ]]; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx

  certbot --nginx \
    -d "${DOMAIN}" \
    --non-interactive \
    --agree-tos \
    -m "${LETSENCRYPT_EMAIL}" \
    --redirect

  FINAL_PUBLIC_URL="https://${DOMAIN}"

  set_env_value "${ENV_FILE}" PUBLIC_BASE_URL "${FINAL_PUBLIC_URL}"
  set_env_value "${ENV_FILE}" PHARMACY_PUBLIC_BASE_URL "${FINAL_PUBLIC_URL}"

  render_voice_script \
    "${VOICE_TEMPLATE}" \
    "${VOICE_LOCAL}" \
    "${FINAL_PUBLIC_URL}" \
    "${PHARMACY_SECRET_VALUE}" \
    "${STAFF_TRANSFER_DESTINATION}"

  sudo -u "${REAL_USER}" pm2 restart "${APP_NAME}" --update-env
  sudo -u "${REAL_USER}" pm2 save >/dev/null
fi

echo "${FINAL_PUBLIC_URL}" > /root/vodia-pharmacy-ai-public-url.txt
chmod 600 /root/vodia-pharmacy-ai-public-url.txt

echo "[16/16] Running post-install regression checks..."
validate_generated_voice_script "${VOICE_LOCAL}" "${FINAL_PUBLIC_URL}"

HEALTH_OK="false"

for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null; then
    HEALTH_OK="true"
    break
  fi
  sleep 1
done

[[ "${HEALTH_OK}" == "true" ]] \
  || die "Application health endpoint did not become ready."

check_route_status "Settings" "http://127.0.0.1:${PORT}/portal/settings"
check_route_status "Voice Agent" "http://127.0.0.1:${PORT}/portal/voice-agent"

curl -fsS "${FINAL_PUBLIC_URL}/health" >/dev/null \
  || die "Public health endpoint failed."

echo ""
echo "=================================================="
echo " Install complete"
echo "=================================================="
echo "Portal:"
echo "  ${FINAL_PUBLIC_URL}/portal"
echo ""
echo "Settings:"
echo "  ${FINAL_PUBLIC_URL}/portal/settings"
echo ""
echo "Voice Agent page:"
echo "  ${FINAL_PUBLIC_URL}/portal/voice-agent"
echo ""
echo "Local health:"
echo "  curl http://127.0.0.1:${PORT}/health"
echo ""
echo "Public health:"
echo "  curl ${FINAL_PUBLIC_URL}/health"
echo ""
echo "App folder:"
echo "  ${INSTALL_DIR}"
echo ""
echo "Database:"
echo "  ${INSTALL_DIR}/pharmacy.db"
echo ""
echo "Voice Agent template:"
echo "  ${VOICE_TEMPLATE}"
echo ""
echo "Voice Agent ready-to-copy local script:"
echo "  ${VOICE_LOCAL}"
echo ""
echo "Secure installer secrets file:"
echo "  ${SECRETS_FILE}"
echo ""
echo "PM2:"
echo "  pm2 status"
echo "  pm2 logs ${APP_NAME} --lines 80"
echo "=================================================="
