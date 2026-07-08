#!/usr/bin/env bash
set -Eeuo pipefail

# Non-interactive apt/needrestart guard.
# Prevents Ubuntu package dialogs such as "Pending kernel upgrade" from blocking installs.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFOLD=1


REPO_URL="${REPO_URL:-https://github.com/rebelking/vodia-downloads.git}"
BRANCH="${BRANCH:-feature/pharmacy-installer-polish}"
WORKDIR="${WORKDIR:-$HOME/vodia-downloads}"
CHECK_ONLY="${CHECK_ONLY:-false}"
LOG="$HOME/vodia-pharmacy-ai-install-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee -a "$LOG") 2>&1

FAILED=0

pass() { echo "✅ PASS - $*"; }
fail() { echo "❌ FAIL - $*"; FAILED=$((FAILED + 1)); }
warn() { echo "⚠️  WARN - $*"; }
fatal() { echo "❌ FATAL - $*"; echo "Log saved to: $LOG"; exit 1; }

run() {
  echo "+ $*"
  "$@"
}

must_have() {
  local label="$1"
  local pattern="$2"
  shift 2

  if grep -RqsF "$pattern" "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

must_not_have() {
  local label="$1"
  local pattern="$2"
  shift 2

  if grep -RqsF "$pattern" "$@"; then
    fail "$label"
    grep -RInF "$pattern" "$@" || true
  else
    pass "$label"
  fi
}

http_check() {
  local label="$1"
  local url="$2"
  local expected_codes="$3"

  echo
  echo "=== $label ==="
  echo "$url"

  local code
  code="$(curl -k -s -o /tmp/vodia-pharmacy-ai-http-check.out -w "%{http_code}" "$url" || echo "000")"

  echo "HTTP code: $code"

  if echo " $expected_codes " | grep -qw "$code"; then
    pass "$label returned expected HTTP code"
  else
    fail "$label returned unexpected HTTP code"
    cat /tmp/vodia-pharmacy-ai-http-check.out 2>/dev/null || true
  fi
}

echo
echo "=================================================="
echo " Vodia Pharmacy AI One-Step Installer"
echo "=================================================="
echo "Repo:    $REPO_URL"
echo "Branch:  $BRANCH"
echo "Workdir: $WORKDIR"
echo "Log:     $LOG"
echo

if [ "$(id -u)" -eq 0 ]; then
  fatal "Do not run this bootstrap script with sudo. Run it as ubuntu. The script will use sudo when needed."
fi

command -v sudo >/dev/null 2>&1 || fatal "sudo is required."

echo "=== Install bootstrap packages ==="
run sudo apt-get update -y
run sudo apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" git curl ca-certificates dnsutils

echo
echo "=== Clone or update installer repo ==="

if [ -d "$WORKDIR/.git" ]; then
  cd "$WORKDIR"
  run git fetch origin
else
  rm -rf "$WORKDIR"
  run git clone "$REPO_URL" "$WORKDIR"
  cd "$WORKDIR"
  run git fetch origin
fi

run git checkout "$BRANCH"
run git reset --hard "origin/$BRANCH"

echo
echo "=== Current branch / commits ==="
git branch --show-current
git log --oneline --decorate -8

echo
echo "=================================================="
echo " Verify the new machine pulled the fixes"
echo "=================================================="

[ -f pharmacy-ai/scripts/configure-domain-https.sh ] && pass "HTTPS helper exists" || fail "HTTPS helper missing"

must_have "Installer calls DNS/HTTPS helper" "PHARMACY_DNS_HTTPS_FLOW" pharmacy-ai/install-ubuntu.sh
must_have "HTTPS helper writes active Nginx site" "/etc/nginx/sites-available/vodia-pharmacy-ai" pharmacy-ai/scripts/configure-domain-https.sh
must_have "HTTPS helper updates PHARMACY_PUBLIC_BASE_URL" "PHARMACY_PUBLIC_BASE_URL" pharmacy-ai/scripts/configure-domain-https.sh
must_have "HTTPS helper updates PUBLIC_BASE_URL" "PUBLIC_BASE_URL" pharmacy-ai/scripts/configure-domain-https.sh
must_have "Settings route is mounted under /portal/settings" "app.use('/portal/settings'" pharmacy-ai/app/server.js

must_not_have "No stale generic DOMAIN fallback" 'PHARMACY_FQDN:-${DOMAIN' pharmacy-ai/scripts/configure-domain-https.sh
must_not_have "No hardcoded pharmaly003 test domain" "pharmaly003" pharmacy-ai/install-ubuntu.sh pharmacy-ai/scripts pharmacy-ai/app

echo
echo "=== Syntax checks ==="

if bash -n pharmacy-ai/install-ubuntu.sh; then
  pass "install-ubuntu.sh syntax OK"
else
  fail "install-ubuntu.sh syntax failed"
fi

if bash -n pharmacy-ai/scripts/configure-domain-https.sh; then
  pass "configure-domain-https.sh syntax OK"
else
  fail "configure-domain-https.sh syntax failed"
fi

if [ "$FAILED" -ne 0 ]; then
  fatal "Verification failed. Fix/push the branch before installing."
fi

if [ "$CHECK_ONLY" = "true" ]; then
  echo "CHECK_ONLY=true, stopping before install."
  echo "Log saved to: $LOG"
  exit 0
fi

echo

# BEGIN PHARMACY_BOOTSTRAP_DNS_PROMPT
echo
echo "=================================================="
echo " DNS / HTTPS selection"
echo "=================================================="

if [ -z "${PHARMACY_FQDN:-}" ]; then
  if [ -r /dev/tty ]; then
    read -r -p "Do you want to use your own DNS/FQDN and configure HTTPS now? [y/N]: " USE_DNS </dev/tty || USE_DNS=""

    case "${USE_DNS:-}" in
      y|Y|yes|YES)
        read -r -p "Enter hostname/FQDN, example pharmacy.example.com: " PHARMACY_FQDN </dev/tty || PHARMACY_FQDN=""
        PHARMACY_FQDN="$(echo "$PHARMACY_FQDN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s#:.*$##; s/[[:space:]]//g')"

        if [ -z "$PHARMACY_FQDN" ]; then
          warn "No hostname entered. Installer will continue HTTP-only."
        else
          echo "Using PHARMACY_FQDN: $PHARMACY_FQDN"
        fi
        ;;
      *)
        echo "DNS/HTTPS skipped. Installer will continue HTTP-only."
        ;;
    esac
  else
    warn "No interactive terminal detected. To configure HTTPS non-interactively, run:"
    echo "  curl -fsSL RAW_URL | PHARMACY_FQDN=your.domain.com bash"
  fi
else
  echo "Using PHARMACY_FQDN from environment: $PHARMACY_FQDN"
fi
# END PHARMACY_BOOTSTRAP_DNS_PROMPT


echo "=================================================="
echo " Starting Pharmacy AI installer"
echo "=================================================="
echo "When the DNS/HTTPS wizard asks for your hostname, enter your real FQDN."
echo "Example: robinson.tryvodia.com"
echo

cd "$WORKDIR/pharmacy-ai"

chmod +x install-ubuntu.sh scripts/configure-domain-https.sh 2>/dev/null || true

COMMON_INSTALL_ENV=(
  REPO_URL="$REPO_URL"
  BRANCH="$BRANCH"
  REPO_BRANCH="$BRANCH"
  INSTALL_BRANCH="$BRANCH"
  PHARMACY_BRANCH="$BRANCH"
  PHARMACY_INSTALLER_SOURCE_DIR="$WORKDIR/pharmacy-ai"
)

if [ -n "${PHARMACY_FQDN:-}" ]; then
  echo "PHARMACY_FQDN was provided: $PHARMACY_FQDN"
  run sudo env \
    -u DOMAIN \
    -u PUBLIC_BASE_URL \
    -u PHARMACY_PUBLIC_BASE_URL \
    "${COMMON_INSTALL_ENV[@]}" \
    PHARMACY_FQDN="$PHARMACY_FQDN" \
    ./install-ubuntu.sh
else
  run sudo env \
    -u DOMAIN \
    -u PUBLIC_BASE_URL \
    -u PHARMACY_PUBLIC_BASE_URL \
    -u PHARMACY_FQDN \
    "${COMMON_INSTALL_ENV[@]}" \
    ./install-ubuntu.sh
fi


# BEGIN POST_INSTALL_COPY_HELPERS
echo
echo "=== Copy helper scripts into installed app ==="
if [ -d "$WORKDIR/pharmacy-ai/scripts" ]; then
  sudo mkdir -p /opt/vodia-pharmacy-ai/scripts
  sudo rsync -a "$WORKDIR/pharmacy-ai/scripts/" /opt/vodia-pharmacy-ai/scripts/
  sudo chmod +x /opt/vodia-pharmacy-ai/scripts/*.sh 2>/dev/null || true
  pass "Installer helper scripts copied to /opt/vodia-pharmacy-ai/scripts"
else
  warn "Installer helper scripts source folder missing: $WORKDIR/pharmacy-ai/scripts"
fi
# END POST_INSTALL_COPY_HELPERS

echo
echo "=================================================="
echo " Post-install validation"
echo "=================================================="

BASE_URL=""

if sudo test -f /root/vodia-pharmacy-ai-public-url.txt; then
  BASE_URL="$(sudo cat /root/vodia-pharmacy-ai-public-url.txt | tr -d '[:space:]')"
fi

if [ -z "$BASE_URL" ]; then
  fail "/root/vodia-pharmacy-ai-public-url.txt is missing or empty"
  BASE_URL="http://_"
fi

DOMAIN="${BASE_URL#https://}"
DOMAIN="${DOMAIN#http://}"
DOMAIN="${DOMAIN%%/*}"

echo "Using BASE_URL: $BASE_URL"
echo "Using DOMAIN:   $DOMAIN"

# BEGIN DNS_MATCH_VALIDATION
SKIP_PUBLIC_CHECKS="false"

if [ -n "${DOMAIN:-}" ] && [ "$DOMAIN" != "_" ] && command -v dig >/dev/null 2>&1; then
  SERVER_PUBLIC_IP="$(curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://ifconfig.me 2>/dev/null || true)"
  DNS_A_RECORDS="$(dig +short "$DOMAIN" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)"

  echo
  echo "=== DNS ownership check ==="
  echo "Domain:          $DOMAIN"
  echo "Server public IP: ${SERVER_PUBLIC_IP:-unknown}"
  echo "DNS A record(s):"
  echo "${DNS_A_RECORDS:-none}"

  if [ -n "$SERVER_PUBLIC_IP" ] && ! echo "$DNS_A_RECORDS" | grep -qx "$SERVER_PUBLIC_IP"; then
    warn "DNS for $DOMAIN does not point to this server yet. Public URL tests may hit another server."
    SKIP_PUBLIC_CHECKS="true"
  else
    pass "DNS points to this server"
  fi
fi
# END DNS_MATCH_VALIDATION


echo
echo "=== Ports ==="
sudo ss -ltnp | grep -E ':80|:443|:3200' || true

echo
echo "=== Local health ==="
curl -s http://127.0.0.1:3200/health || true
echo

if [ "${SKIP_PUBLIC_CHECKS:-false}" = "true" ]; then
  warn "Skipping public HTTP checks because DNS is not pointing to this server."
else
  http_check "Public health" "$BASE_URL/health" "200 301 302"
  http_check "Portal" "$BASE_URL/portal" "200 301 302"
  http_check "Portal settings" "$BASE_URL/portal/settings" "200 301 302 401"
  http_check "Voice Agent" "$BASE_URL/portal/voice-agent" "200 301 302 401"
fi

echo
echo "=== Env URLs ==="
sudo grep -nE "PUBLIC_BASE_URL|PHARMACY_DOMAIN|PHARMACY_PUBLIC_BASE_URL" /opt/vodia-pharmacy-ai/.env || true

echo
echo "=== Placeholder check ==="

if sudo grep -RqsE "http://_|https://_" /opt/vodia-pharmacy-ai/.env /opt/vodia-pharmacy-ai/voice-agent 2>/dev/null; then
  fail "Placeholder URL still exists"
  sudo grep -RInE "http://_|https://_" /opt/vodia-pharmacy-ai/.env /opt/vodia-pharmacy-ai/voice-agent 2>/dev/null || true
else
  pass "No http://_ or https://_ placeholder found"
fi

echo
echo "=== Voice Agent URLs ==="
sudo grep -nE "http://_|https://_|api/ai|$DOMAIN" /opt/vodia-pharmacy-ai/voice-agent/vodia-pharmacy-ai-voice-agent.local.js 2>/dev/null | head -50 || true

echo
echo "=== Nginx site ==="
sudo grep -nE "server_name|ssl_certificate|proxy_pass" /etc/nginx/sites-enabled/vodia-pharmacy-ai 2>/dev/null || true

echo
echo "=== Certbot ==="
if command -v certbot >/dev/null 2>&1; then
  sudo certbot certificates || true
else
  warn "certbot is not installed. This is expected when DNS mismatch caused HTTPS to be skipped."
fi

echo
echo "=== PM2 ==="
sudo -iu ubuntu pm2 status || true

echo
echo "=== Portal login file ==="
sudo cat /root/vodia-pharmacy-ai-portal-login.txt 2>/dev/null || true

echo
echo "=================================================="
echo " Final result"
echo "=================================================="

if [ "$FAILED" -ne 0 ]; then
  echo "❌ Install completed, but validation found problems."
  echo "Log saved to: $LOG"
  exit 1
fi

echo "✅ Vodia Pharmacy AI install flow passed."
echo "Log saved to: $LOG"
