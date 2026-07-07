#!/usr/bin/env bash
set -Eeuo pipefail

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
run sudo apt-get install -y git curl ca-certificates dnsutils

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
echo "=================================================="
echo " Starting Pharmacy AI installer"
echo "=================================================="
echo "When the DNS/HTTPS wizard asks for your hostname, enter your real FQDN."
echo "Example: robinson.tryvodia.com"
echo

cd "$WORKDIR/pharmacy-ai"

chmod +x install-ubuntu.sh scripts/configure-domain-https.sh 2>/dev/null || true

if [ -n "${PHARMACY_FQDN:-}" ]; then
  echo "PHARMACY_FQDN was provided: $PHARMACY_FQDN"
  run sudo env -u DOMAIN -u PUBLIC_BASE_URL -u PHARMACY_PUBLIC_BASE_URL PHARMACY_FQDN="$PHARMACY_FQDN" ./install-ubuntu.sh
else
  run sudo env -u DOMAIN -u PUBLIC_BASE_URL -u PHARMACY_PUBLIC_BASE_URL -u PHARMACY_FQDN ./install-ubuntu.sh
fi

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

echo
echo "=== Ports ==="
sudo ss -ltnp | grep -E ':80|:443|:3200' || true

echo
echo "=== Local health ==="
curl -s http://127.0.0.1:3200/health || true
echo

http_check "Public health" "$BASE_URL/health" "200"
http_check "Portal" "$BASE_URL/portal" "200 301 302"
http_check "Portal settings" "$BASE_URL/portal/settings" "200 301 302 401"
http_check "Voice Agent" "$BASE_URL/portal/voice-agent" "200 301 302 401"

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
sudo certbot certificates || true

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
