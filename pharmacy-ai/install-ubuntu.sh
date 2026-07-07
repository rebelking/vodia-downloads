#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-1.0.0}"
APP_NAME="${APP_NAME:-vodia-pharmacy-ai}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vodia-pharmacy-ai}"
PORT="${PORT:-3200}"
DOMAIN="${DOMAIN:-_}"
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


#############################################
# DNS Preflight Wizard
#############################################

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

has_interactive_tty() {
  [ -t 0 ] || [ -r /dev/tty ]
}

read_from_tty() {
  local prompt="${1:-}"
  local value=""

  if [ -r /dev/tty ]; then
    read -r -p "${prompt}" value </dev/tty
  else
    read -r -p "${prompt}" value
  fi

  echo "${value}"
}

normalize_hostname() {
  local value="${1:-}"
  value="$(printf '%s' "${value}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  value="$(printf '%s' "${value}" | sed -E 's#^https?://##; s#/.*$##; s/:.*$//; s/\.$//')"
  echo "${value}"
}

is_valid_public_hostname() {
  local host=""
  host="$(normalize_hostname "${1:-}")"

  [ -n "${host}" ] || return 1
  [ "${host}" != "_" ] || return 1
  [ "${host}" != "localhost" ] || return 1
  ! is_ipv4 "${host}" || return 1
  echo "${host}" | grep -q '\.' || return 1
  [ "${#host}" -le 253 ] || return 1

  echo "${host}" | grep -Eiq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}$'
}

prompt_for_domain() {
  local entered=""

  while true; do
    echo ""
    echo "Enter the public portal hostname/FQDN that you or the customer controls."
    echo ""
    echo "Examples:"
    echo "  ai.customer-domain.com"
    echo "  refills.mypharmacy.com"
    echo "  pharmacy.company.org"
    echo ""
    echo "Do not enter a hostname unless you can create DNS records for it."
    echo ""

    entered="$(read_from_tty "Portal hostname/FQDN: ")"
    entered="$(normalize_hostname "${entered}")"

    if is_valid_public_hostname "${entered}"; then
      DOMAIN="${entered}"
      export DOMAIN
      return 0
    fi

    echo ""
    echo "Invalid hostname: ${entered}"
    echo "Please enter a real public hostname, for example ai.customer-domain.com"
  done
}

confirm_domain_control() {
  local choice=""

  if ! is_true "${DNS_CONFIRM:-true}"; then
    return 0
  fi

  if ! has_interactive_tty; then
    return 0
  fi

  while true; do
    echo ""
    echo "=================================================="
    echo " Confirm Portal Hostname"
    echo "=================================================="
    echo "You entered:"
    echo "  ${DOMAIN}"
    echo ""
    echo "This installer will use:"
    echo "  https://${DOMAIN}/portal"
    echo "  https://${DOMAIN}/portal/voice-agent"
    echo "  https://${DOMAIN}/health"
    echo ""
    echo "Do you control DNS for this hostname?"
    echo ""
    echo "  1) Yes, continue"
    echo "  2) No, enter a different hostname/FQDN"
    echo "  3) Continue without HTTPS"
    echo "  4) Exit installer"
    echo "=================================================="
    echo ""

    choice="$(read_from_tty "Select [1-4]: ")"

    case "${choice}" in
      1|"")
        return 0
        ;;

      2)
        prompt_for_domain
        ;;

      3)
        echo "Continuing without HTTPS. Public URL will use HTTP."
        ENABLE_HTTPS="false"
        export ENABLE_HTTPS
        return 0
        ;;

      4)
        echo "Installer stopped by user."
        exit 1
        ;;

      *)
        echo "Invalid choice."
        ;;
    esac
  done
}


is_ipv4() {
  echo "${1:-}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

get_public_ipv4() {
  local ip=""

  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

  if [ -z "${ip}" ]; then
    ip="$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  fi

  if is_ipv4 "${ip}"; then
    echo "${ip}"
  fi
}

resolve_domain_ipv4() {
  local domain="${1:-}"

  if command -v dig >/dev/null 2>&1; then
    dig +short A "${domain}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
  fi

  getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

dns_ipv4_matches() {
  local domain="${1:-}"
  local target_ip="${2:-}"
  local ip=""

  while IFS= read -r ip; do
    if [ "${ip}" = "${target_ip}" ]; then
      return 0
    fi
  done < <(resolve_domain_ipv4 "${domain}" | sort -u)

  return 1
}

print_dns_fix_instructions() {
  local domain="${1:-}"
  local server_ip="${2:-}"
  local dns_ips="${3:-none}"

  echo ""
  echo "=================================================="
  echo " DNS Preflight Wizard"
  echo "=================================================="
  echo "Portal hostname / FQDN:"
  echo "  ${domain}"
  echo ""
  echo "This server public IP:"
  echo "  ${server_ip}"
  echo ""
  echo "DNS currently resolves to:"
  echo "  ${dns_ips}"
  echo ""
  echo "DNS does NOT point this hostname to this server."
  echo ""
  echo "At the DNS provider for a domain you control, create or update this IPv4 A record:"
  echo ""
  echo "Type:  A"
  echo "Hostname / FQDN:  ${domain}"
  echo "Points to / Value: ${server_ip}"
  echo "TTL:   300"
  echo "=================================================="
  echo ""
}

dns_preflight_wizard() {
  DNS_WIZARD="${DNS_WIZARD:-true}"
  DNS_WAIT_SECONDS="${DNS_WAIT_SECONDS:-600}"
  DNS_RETRY_INTERVAL="${DNS_RETRY_INTERVAL:-15}"
  DNS_SKIP_CHECK="${DNS_SKIP_CHECK:-false}"

  if ! is_true "${ENABLE_HTTPS:-false}"; then
    echo "DNS preflight skipped because HTTPS is disabled."
    return 0
  fi

  if is_true "${DNS_SKIP_CHECK}"; then
    echo "WARNING: DNS preflight skipped because DNS_SKIP_CHECK=true."
    return 0
  fi

  DOMAIN="$(normalize_hostname "${DOMAIN:-}")"
  export DOMAIN

  if ! is_valid_public_hostname "${DOMAIN:-}"; then
    if is_true "${DNS_WIZARD}" && has_interactive_tty; then
      prompt_for_domain
    else
      echo "ERROR: A public hostname/FQDN is required for HTTPS."
      echo "Rerun with DOMAIN=ai.customer-domain.com, or set ENABLE_HTTPS=false for HTTP-only testing."
      exit 1
    fi
  fi

  confirm_domain_control

  if ! is_true "${ENABLE_HTTPS:-false}"; then
    return 0
  fi

  if is_ipv4 "${DOMAIN}"; then
    echo "WARNING: DOMAIN is an IP address. Let's Encrypt needs a real DNS name. Disabling HTTPS."
    ENABLE_HTTPS="false"
    export ENABLE_HTTPS
    return 0
  fi

  local server_ip=""
  local dns_ips=""
  local choice=""
  local elapsed=0

  server_ip="$(get_public_ipv4)"

  if [ -z "${server_ip}" ]; then
    echo "ERROR: Could not detect this server's public IPv4 address."
    echo "Fix network access or rerun with ENABLE_HTTPS=false."
    exit 1
  fi

  while true; do
    dns_ips="$(resolve_domain_ipv4 "${DOMAIN}" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    dns_ips="${dns_ips:-none}"

    if dns_ipv4_matches "${DOMAIN}" "${server_ip}"; then
      echo "DNS preflight passed:"
      echo "  ${DOMAIN} -> ${server_ip}"
      return 0
    fi

    print_dns_fix_instructions "${DOMAIN}" "${server_ip}" "${dns_ips}"

    if ! is_true "${DNS_WIZARD}" || [ ! -t 0 ]; then
      echo "ERROR: DNS mismatch and installer is not running interactively."
      echo "Fix DNS, rerun with ENABLE_HTTPS=false, or use DNS_SKIP_CHECK=true only if you know what you are doing."
      exit 1
    fi

    echo "Choose an option:"
    echo "  1) I updated DNS, check again"
    echo "  2) Wait and keep checking"
    echo "  3) Re-enter hostname/FQDN"
    echo "  4) Continue without HTTPS"
    echo "  5) Exit installer"
    echo ""

    choice="$(read_from_tty "Select [1-5]: ")"


    case "${choice}" in
      1|"")
        continue
        ;;

      2)
        elapsed=0
        echo "Waiting up to ${DNS_WAIT_SECONDS} seconds for DNS to update..."

        while [ "${elapsed}" -lt "${DNS_WAIT_SECONDS}" ]; do
          sleep "${DNS_RETRY_INTERVAL}"
          elapsed=$((elapsed + DNS_RETRY_INTERVAL))

          dns_ips="$(resolve_domain_ipv4 "${DOMAIN}" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
          dns_ips="${dns_ips:-none}"

          if dns_ipv4_matches "${DOMAIN}" "${server_ip}"; then
            echo "DNS preflight passed:"
            echo "  ${DOMAIN} -> ${server_ip}"
            return 0
          fi

          echo "Still waiting... DNS currently points to: ${dns_ips}"
        done

        echo "DNS did not update within ${DNS_WAIT_SECONDS} seconds."
        ;;

      3)
        prompt_for_domain
        confirm_domain_control

        if ! is_true "${ENABLE_HTTPS:-false}"; then
          return 0
        fi
        ;;

      4)
        echo "Continuing without HTTPS. Public URL will use HTTP."
        ENABLE_HTTPS="false"
        export ENABLE_HTTPS
        return 0
        ;;

      5)
        echo "Installer stopped by user."
        echo ""
        echo "To rerun only the DNS wizard later:"
        echo "  sudo DNS_ONLY=true ENABLE_HTTPS=true bash /tmp/install-pharmacy-ai-polish.sh"
        echo ""
        echo "Or with a corrected hostname:"
        echo "  sudo DNS_ONLY=true ENABLE_HTTPS=true DOMAIN=ai.customer-domain.com bash /tmp/install-pharmacy-ai-polish.sh"
        exit 1
        ;;

      *)
        echo "Invalid choice."
        ;;
    esac
  done
}

if is_true "${DNS_ONLY:-false}"; then
  ENABLE_HTTPS="${ENABLE_HTTPS:-true}"
  DNS_WIZARD="${DNS_WIZARD:-true}"
  export ENABLE_HTTPS
  export DNS_WIZARD

  echo "Running DNS wizard only. No app files will be installed or changed."
  dns_preflight_wizard
  echo ""
  echo "DNS wizard completed successfully."
  echo ""


# BEGIN SMTP_ADMIN_SETTINGS_DEPLOY_ASSURANCE
echo
echo "[post] Ensuring Pharmacy AI SMTP/admin settings feature is deployed..."

if [ "${DNS_ONLY:-false}" = "true" ]; then
  echo "[post] DNS_ONLY=true, skipping app deploy assurance."
else
  PHARMACY_INSTALL_DIR="${PHARMACY_INSTALL_DIR:-/opt/vodia-pharmacy-ai}"
  PHARMACY_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PHARMACY_SOURCE_APP="${PHARMACY_SOURCE_APP:-$PHARMACY_INSTALLER_DIR/app}"

  if [ ! -d "$PHARMACY_INSTALL_DIR" ]; then
    echo "[post] WARNING: installed app directory missing: $PHARMACY_INSTALL_DIR"
  elif [ ! -f "$PHARMACY_SOURCE_APP/routes/adminSettings.js" ]; then
    echo "[post] WARNING: source adminSettings.js missing: $PHARMACY_SOURCE_APP/routes/adminSettings.js"
  else
    echo "[post] Source app: $PHARMACY_SOURCE_APP"
    echo "[post] Installed app: $PHARMACY_INSTALL_DIR"

    mkdir -p "$PHARMACY_INSTALL_DIR/routes"

    echo "[post] Copying adminSettings.js..."
    install -m 0644 "$PHARMACY_SOURCE_APP/routes/adminSettings.js" "$PHARMACY_INSTALL_DIR/routes/adminSettings.js"

    echo "[post] Mounting /admin/settings in installed server.js if needed..."
    python3 - "$PHARMACY_INSTALL_DIR/server.js" <<'PYROUTE'
from pathlib import Path
import re
import sys

entry = Path(sys.argv[1])

if not entry.exists():
    print(f"ERROR: server.js not found: {entry}")
    sys.exit(1)

txt = entry.read_text()

if "routes/adminSettings" in txt or "adminSettingsRouter" in txt:
    print("/admin/settings already mounted.")
    sys.exit(0)

m = re.search(r'\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*express\s*\(\s*\)', txt)
appvar = m.group(1) if m else "app"

mount = f"""
// Pharmacy AI admin settings: SMTP, Security, Tenant Binding, CRM placeholders
try {{
  const adminSettingsRouter = require('./routes/adminSettings');
  {appvar}.use('/admin/settings', adminSettingsRouter);
  {appvar}.get('/settings', (req, res) => res.redirect('/admin/settings'));
  console.log('Pharmacy AI admin settings mounted at /admin/settings');
}} catch (err) {{
  console.error('Failed to mount Pharmacy AI admin settings:', err.message);
}}
"""

lines = txt.splitlines(keepends=True)
insert_at = None

for i, line in enumerate(lines):
    if ".use" in line and ("404" in line or "Not Found" in line):
        insert_at = i
        break

if insert_at is None:
    for i, line in enumerate(lines):
        if ".listen(" in line:
            insert_at = i
            break

if insert_at is None:
    txt = txt.rstrip() + "\n\n" + mount + "\n"
else:
    lines.insert(insert_at, mount + "\n")
    txt = "".join(lines)

entry.write_text(txt)
print("Mounted /admin/settings.")
PYROUTE

    echo "[post] Ensuring nodemailer dependency exists..."
    cd "$PHARMACY_INSTALL_DIR"
    npm install nodemailer --save

    echo "[post] Syntax check..."
    node -c "$PHARMACY_INSTALL_DIR/routes/adminSettings.js"
    node -c "$PHARMACY_INSTALL_DIR/server.js"

    echo "[post] Fixing ownership..."
    chown -R ubuntu:ubuntu "$PHARMACY_INSTALL_DIR" 2>/dev/null || true

    echo "[post] Restarting PM2 app if running..."
    if command -v pm2 >/dev/null 2>&1; then
      if id ubuntu >/dev/null 2>&1; then
        sudo -iu ubuntu pm2 restart vodia-pharmacy-ai 2>/dev/null || true
        sudo -iu ubuntu pm2 save 2>/dev/null || true
      fi
      pm2 restart vodia-pharmacy-ai 2>/dev/null || true
      pm2 save 2>/dev/null || true
    fi

    echo "[post] SMTP/admin settings deploy assurance complete."
  fi
fi
# END SMTP_ADMIN_SETTINGS_DEPLOY_ASSURANCE

  exit 0
fi

echo "[1/15] Installing system packages..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  curl git rsync build-essential nginx sqlite3 dnsutils ufw ca-certificates gnupg unzip openssl

echo "DNS preflight / public hostname check..."
dns_preflight_wizard

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
    grep -v "sqlite_sequence" "${INSTALL_DIR}/schema.sql" | sqlite3 "${INSTALL_DIR}/pharmacy.db"
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




# BEGIN SMTP_ADMIN_SETTINGS_DEPLOY_BEFORE_PM2
echo
echo "[smtp-settings] Ensuring admin settings route is deployed..."

if [ "${DNS_ONLY:-false}" != "true" ]; then
  PHARMACY_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PHARMACY_SOURCE_APP="${PHARMACY_SOURCE_APP:-$PHARMACY_INSTALLER_DIR/app}"
  PHARMACY_TARGET_APP="${PHARMACY_INSTALL_DIR:-/opt/vodia-pharmacy-ai}"

  echo "[smtp-settings] Source app: $PHARMACY_SOURCE_APP"
  echo "[smtp-settings] Target app: $PHARMACY_TARGET_APP"

  if [ ! -f "$PHARMACY_SOURCE_APP/routes/adminSettings.js" ]; then
    echo "[smtp-settings] WARNING: missing source adminSettings.js: $PHARMACY_SOURCE_APP/routes/adminSettings.js"
  elif [ ! -d "$PHARMACY_TARGET_APP" ]; then
    echo "[smtp-settings] WARNING: missing installed app dir: $PHARMACY_TARGET_APP"
  else
    mkdir -p "$PHARMACY_TARGET_APP/routes"

    echo "[smtp-settings] Copying adminSettings.js..."
    cp -f "$PHARMACY_SOURCE_APP/routes/adminSettings.js" "$PHARMACY_TARGET_APP/routes/adminSettings.js"

    echo "[smtp-settings] Mounting /admin/settings in installed server.js if needed..."
    python3 - "$PHARMACY_TARGET_APP/server.js" <<'PYROUTE'
from pathlib import Path
import re
import sys

entry = Path(sys.argv[1])

if not entry.exists():
    print(f"ERROR: server.js not found: {entry}")
    sys.exit(1)

txt = entry.read_text()

if "routes/adminSettings" in txt or "adminSettingsRouter" in txt:
    print("/admin/settings already mounted.")
    sys.exit(0)

m = re.search(r'\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*express\s*\(\s*\)', txt)
appvar = m.group(1) if m else "app"

mount = f"""
// Pharmacy AI admin settings: SMTP, Security, Tenant Binding, CRM placeholders
try {{
  const adminSettingsRouter = require('./routes/adminSettings');
  {appvar}.use('/admin/settings', adminSettingsRouter);
  {appvar}.get('/settings', (req, res) => res.redirect('/admin/settings'));
  console.log('Pharmacy AI admin settings mounted at /admin/settings');
}} catch (err) {{
  console.error('Failed to mount Pharmacy AI admin settings:', err.message);
}}
"""

lines = txt.splitlines(keepends=True)
insert_at = None

for i, line in enumerate(lines):
    if ".use" in line and ("404" in line or "Not Found" in line):
        insert_at = i
        break

if insert_at is None:
    for i, line in enumerate(lines):
        if ".listen(" in line:
            insert_at = i
            break

if insert_at is None:
    txt = txt.rstrip() + "\n\n" + mount + "\n"
else:
    lines.insert(insert_at, mount + "\n")
    txt = "".join(lines)

entry.write_text(txt)
print("Mounted /admin/settings.")
PYROUTE

    cd "$PHARMACY_TARGET_APP"

    echo "[smtp-settings] Ensuring nodemailer exists..."
    npm install nodemailer --save

    echo "[smtp-settings] Syntax check..."
    node -c "$PHARMACY_TARGET_APP/routes/adminSettings.js"
    node -c "$PHARMACY_TARGET_APP/server.js"

    chown -R ubuntu:ubuntu "$PHARMACY_TARGET_APP" 2>/dev/null || true

    echo "[smtp-settings] /admin/settings deployed."
  fi
fi
# END SMTP_ADMIN_SETTINGS_DEPLOY_BEFORE_PM2




# BEGIN PHARMACY_APP_SOURCE_OVERLAY_BEFORE_PM2
echo
echo "[app-overlay] Ensuring installed app matches installer source app..."

if [ "${DNS_ONLY:-false}" != "true" ]; then
  PHARMACY_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PHARMACY_SOURCE_APP="${PHARMACY_SOURCE_APP:-$PHARMACY_INSTALLER_DIR/app}"
  PHARMACY_TARGET_APP="${PHARMACY_INSTALL_DIR:-/opt/vodia-pharmacy-ai}"

  echo "[app-overlay] Source app: $PHARMACY_SOURCE_APP"
  echo "[app-overlay] Target app: $PHARMACY_TARGET_APP"

  if [ ! -d "$PHARMACY_SOURCE_APP" ]; then
    echo "[app-overlay] WARNING: source app missing: $PHARMACY_SOURCE_APP"
  elif [ ! -d "$PHARMACY_TARGET_APP" ]; then
    echo "[app-overlay] WARNING: target app missing: $PHARMACY_TARGET_APP"
  else
    echo "[app-overlay] Overlaying source app code into target app..."

    (
      cd "$PHARMACY_SOURCE_APP"
      tar \
        --exclude='./node_modules' \
        --exclude='./backups' \
        --exclude='./.env' \
        --exclude='./pharmacy.db' \
        --exclude='./*.db' \
        --exclude='./*.sqlite' \
        --exclude='./data/admin-settings.json' \
        --exclude='./voice-agent/vodia-pharmacy-ai-voice-agent.local.js' \
        -cf - .
    ) | (
      cd "$PHARMACY_TARGET_APP"
      tar -xf -
    )

    cd "$PHARMACY_TARGET_APP"

    echo "[app-overlay] Installing/updating npm dependencies..."
    npm install

    echo "[app-overlay] Syntax check..."
    node -c "$PHARMACY_TARGET_APP/server.js"

    if [ -f "$PHARMACY_TARGET_APP/routes/adminSettings.js" ]; then
      node -c "$PHARMACY_TARGET_APP/routes/adminSettings.js"
    fi

    echo "[app-overlay] Route checks in installed server.js:"
    grep -n "portal/voice-agent\|admin/settings\|adminSettings" "$PHARMACY_TARGET_APP/server.js" || true

    chown -R ubuntu:ubuntu "$PHARMACY_TARGET_APP" 2>/dev/null || true

    echo "[app-overlay] Installed app overlay complete."
  fi
fi
# END PHARMACY_APP_SOURCE_OVERLAY_BEFORE_PM2


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


# BEGIN PHARMACY_DNS_HTTPS_FLOW
echo
echo "[domain] Optional DNS / HTTPS setup..."

if [ "${DNS_ONLY:-false}" != "true" ]; then
  PHARMACY_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PHARMACY_HTTPS_SCRIPT="$PHARMACY_INSTALLER_DIR/scripts/configure-domain-https.sh"

  if [ -x "$PHARMACY_HTTPS_SCRIPT" ]; then
    "$PHARMACY_HTTPS_SCRIPT" || echo "[domain] WARNING: DNS/HTTPS setup did not complete. App is installed; rerun HTTPS helper later if needed."
  else
    echo "[domain] WARNING: missing HTTPS helper: $PHARMACY_HTTPS_SCRIPT"
  fi
else
  echo "[domain] DNS_ONLY=true, skipping HTTPS setup."
fi
# END PHARMACY_DNS_HTTPS_FLOW



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

# BEGIN PHARMACY_FINAL_PUBLIC_URL_HELPER
PHARMACY_PUBLIC_BASE_URL_DISPLAY="${PHARMACY_PUBLIC_BASE_URL:-}"

if [ -f /root/vodia-pharmacy-ai-public-url.txt ]; then
  PHARMACY_PUBLIC_BASE_URL_DISPLAY="$(cat /root/vodia-pharmacy-ai-public-url.txt | tr -d '[:space:]')"
fi

if [ -z "$PHARMACY_PUBLIC_BASE_URL_DISPLAY" ] && [ -n "${PHARMACY_FQDN:-}" ]; then
  PHARMACY_PUBLIC_BASE_URL_DISPLAY="https://${PHARMACY_FQDN}"
fi

if [ -z "$PHARMACY_PUBLIC_BASE_URL_DISPLAY" ] && [ -n "${DOMAIN:-}" ] && [ "${DOMAIN:-_}" != "_" ]; then
  PHARMACY_PUBLIC_BASE_URL_DISPLAY="https://${DOMAIN}"
fi

if [ -z "$PHARMACY_PUBLIC_BASE_URL_DISPLAY" ]; then
  PHARMACY_PUBLIC_BASE_URL_DISPLAY="http://_"
fi

PHARMACY_PUBLIC_BASE_URL_DISPLAY="${PHARMACY_PUBLIC_BASE_URL_DISPLAY%/}"
# END PHARMACY_FINAL_PUBLIC_URL_HELPER


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
