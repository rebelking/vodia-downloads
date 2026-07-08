#!/usr/bin/env bash
set -Eeuo pipefail

# Non-interactive apt/needrestart guard.
# Prevents Ubuntu package dialogs such as "Pending kernel upgrade" from blocking installs.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
export UCF_FORCE_CONFOLD=1


APP_DIR="${APP_DIR:-/opt/vodia-pharmacy-ai}"
DOMAIN="${PHARMACY_FQDN:-${1:-}}"
WEBROOT="${WEBROOT:-/var/www/letsencrypt}"
CONF="/etc/nginx/sites-available/vodia-pharmacy-ai"
ENABLED="/etc/nginx/sites-enabled/vodia-pharmacy-ai"
EMAIL="${LETSENCRYPT_EMAIL:-}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  $SUDO touch "$file"

  if $SUDO grep -q "^${key}=" "$file"; then
    $SUDO sed -i "s#^${key}=.*#${key}=${value}#" "$file"
  else
    echo "${key}=${value}" | $SUDO tee -a "$file" >/dev/null
  fi
}

update_voice_agent_urls() {
  local base_url="$1"

  $SUDO python3 - <<PY
from pathlib import Path
import re

app = Path("$APP_DIR")
base = "$base_url"

files = [
    app / "voice-agent" / "vodia-pharmacy-ai-voice-agent.local.js",
    app / "voice-agent" / "vodia-pharmacy-ai-voice-agent.template.js",
]

mapping = {
    "pharmacyRequestUrl": "/api/ai/refill-intake",
    "customerLookupUrl": "/api/ai/customer-lookup",
    "customerEnrichUrl": "/api/ai/refill-request-enrich",
    "fulfillmentUrl": "/api/ai/request-fulfillment",
}

for path in files:
    if not path.exists():
        print(f"Missing {path}")
        continue

    txt = path.read_text()
    txt = txt.replace("http://_", base)
    txt = txt.replace("https://_", base)

    txt = re.sub(r"https?://[^\"']+/api/ai/refill-intake", base + "/api/ai/refill-intake", txt)
    txt = re.sub(r"https?://[^\"']+/api/ai/customer-lookup", base + "/api/ai/customer-lookup", txt)
    txt = re.sub(r"https?://[^\"']+/api/ai/refill-request-enrich", base + "/api/ai/refill-request-enrich", txt)
    txt = re.sub(r"https?://[^\"']+/api/ai/request-fulfillment", base + "/api/ai/request-fulfillment", txt)

    for var_name, api_path in mapping.items():
        pattern = r'(var\\s+' + re.escape(var_name) + r'\\s*=\\s*)["\\'][^"\\']*["\\']'
        txt = re.sub(pattern, lambda m: f'{m.group(1)}"{base}{api_path}"', txt)

    path.write_text(txt)
    print(f"Updated {path}")
PY
}

write_http_nginx() {
  local domain="$1"

  $SUDO mkdir -p "$WEBROOT/.well-known/acme-challenge"

  echo "acme-ok" | $SUDO tee "$WEBROOT/.well-known/acme-challenge/ping" >/dev/null

  if [ -f "$CONF" ]; then
    $SUDO cp -a "$CONF" "$CONF.bak.http.$(date +%Y%m%d-%H%M%S)"
  fi

  $SUDO tee "$CONF" >/dev/null <<EOF_CONF
server {
    listen 80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        proxy_pass http://127.0.0.1:3200;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF_CONF

  $SUDO ln -sf "$CONF" "$ENABLED"
  $SUDO nginx -t
  $SUDO systemctl reload nginx
}

write_https_nginx() {
  local domain="$1"

  $SUDO cp -a "$CONF" "$CONF.bak.https.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

  $SUDO tee "$CONF" >/dev/null <<EOF_CONF
server {
    listen 80;
    server_name $domain;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass http://127.0.0.1:3200;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF_CONF

  $SUDO nginx -t
  $SUDO systemctl reload nginx
}

echo
echo "=================================================="
echo " DNS / HTTPS setup"
echo "=================================================="

if [ -z "$DOMAIN" ]; then
  echo "[domain] No PHARMACY_FQDN provided. Skipping HTTPS."
  exit 0
fi

DOMAIN="$(echo "$DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s#:.*$##; s/[[:space:]]//g')"

$SUDO apt-get update
$SUDO apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" bind9-dnsutils curl ca-certificates nginx

SERVER_IP="$(curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS4 https://ifconfig.me 2>/dev/null || true)"
DNS_IPS="$(dig +short "$DOMAIN" A | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true)"

echo
echo "[domain] Domain: $DOMAIN"
echo "[domain] Server public IP: ${SERVER_IP:-unknown}"
echo "[domain] DNS A record IP(s): ${DNS_IPS:-none}"

if [ -z "$SERVER_IP" ] || ! echo "$DNS_IPS" | grep -qx "$SERVER_IP"; then
  echo
  echo "[domain] DNS does not point to this server yet."
  echo "Create or update this DNS record:"
  echo
  echo "  Type: A"
  echo "  Name/FQDN: $DOMAIN"
  echo "  Value: $SERVER_IP"
  echo "  TTL: 300"
  echo
  echo "[domain] Configuring HTTP only and skipping Certbot."

  write_http_nginx "$DOMAIN"

  BASE_URL="http://$DOMAIN"

  set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$BASE_URL"
  set_env_value "$APP_DIR/.env" "PHARMACY_DOMAIN" "$DOMAIN"
  set_env_value "$APP_DIR/.env" "PHARMACY_PUBLIC_BASE_URL" "$BASE_URL"

  echo "$BASE_URL" | $SUDO tee /root/vodia-pharmacy-ai-public-url.txt >/dev/null

  if [ -f /root/vodia-pharmacy-ai-portal-login.txt ]; then
    $SUDO sed -i -E "s#^URL: .*#URL: $BASE_URL/portal#" /root/vodia-pharmacy-ai-portal-login.txt
  fi

  update_voice_agent_urls "$BASE_URL"

  echo
  echo "[domain] HTTP public URLs:"
  echo "  $BASE_URL/portal"
  echo "  $BASE_URL/portal/settings"
  echo "  $BASE_URL/portal/voice-agent"

  exit 0
fi

echo
echo "[domain] DNS matches this server."

write_http_nginx "$DOMAIN"

echo
echo "[domain] Public ACME challenge test:"
curl -fsS "http://$DOMAIN/.well-known/acme-challenge/ping" || {
  echo
  echo "[domain] ERROR: ACME challenge path is not publicly reachable over HTTP."
  exit 1
}
echo

$SUDO apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" certbot

if [ -z "$EMAIL" ]; then
  if [ -r /dev/tty ]; then
    read -r -p "Let's Encrypt email, optional but recommended: " EMAIL </dev/tty || EMAIL=""
  fi
fi

CERTBOT_ARGS=(
  certonly
  --webroot
  -w "$WEBROOT"
  -d "$DOMAIN"
  --agree-tos
  --non-interactive
  --keep-until-expiring
)

if [ -n "$EMAIL" ]; then
  CERTBOT_ARGS+=(--email "$EMAIL")
else
  CERTBOT_ARGS+=(--register-unsafely-without-email)
fi

echo "[domain] Requesting certificate for $DOMAIN..."
$SUDO certbot "${CERTBOT_ARGS[@]}"

write_https_nginx "$DOMAIN"

BASE_URL="https://$DOMAIN"

set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$BASE_URL"
set_env_value "$APP_DIR/.env" "PHARMACY_DOMAIN" "$DOMAIN"
set_env_value "$APP_DIR/.env" "PHARMACY_PUBLIC_BASE_URL" "$BASE_URL"

echo "$BASE_URL" | $SUDO tee /root/vodia-pharmacy-ai-public-url.txt >/dev/null

if [ -f /root/vodia-pharmacy-ai-portal-login.txt ]; then
  $SUDO sed -i -E "s#^URL: .*#URL: $BASE_URL/portal#" /root/vodia-pharmacy-ai-portal-login.txt
fi

update_voice_agent_urls "$BASE_URL"

$SUDO -iu ubuntu pm2 restart vodia-pharmacy-ai --update-env || true

echo
echo "[domain] HTTPS public URLs:"
echo "  $BASE_URL/health"
echo "  $BASE_URL/portal"
echo "  $BASE_URL/portal/settings"
echo "  $BASE_URL/portal/voice-agent"
