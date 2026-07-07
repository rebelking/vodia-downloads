#!/usr/bin/env bash
set -euo pipefail

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

APP_DIR="${PHARMACY_INSTALL_DIR:-/opt/vodia-pharmacy-ai}"
DOMAIN="${PHARMACY_FQDN:-${1:-}}"
NONINTERACTIVE="${PHARMACY_NONINTERACTIVE:-false}"

normalize_domain() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##; s#:.*$##; s/[[:space:]]//g'
}

valid_domain() {
  local d="$1"
  [[ "$d" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]
}

get_public_ip() {
  curl -fsS -4 https://ifconfig.me 2>/dev/null || curl -fsS -4 https://icanhazip.com 2>/dev/null || true
}

get_dns_ips() {
  dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | xargs || true
}

set_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  $SUDO python3 - "$file" "$key" "$value" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = path.read_text().splitlines() if path.exists() else []
prefix = key + "="
out = []
found = False

for line in lines:
    if line.startswith(prefix):
        out.append(f"{key}={value}")
        found = True
    else:
        out.append(line)

if not found:
    out.append(f"{key}={value}")

path.write_text("\n".join(out) + "\n")
PY
}

update_nginx_server_name() {
  local domain="$1"
  local conf="/etc/nginx/sites-available/vodia-pharmacy-ai"

  echo "[domain] Writing active Nginx config: $conf"

  if [ -f "$conf" ]; then
    $SUDO cp -a "$conf" "$conf.bak.domain-https.$(date +%Y%m%d-%H%M%S)"
  fi

  $SUDO tee "$conf" >/dev/null <<EOF_CONF
server {
    listen 80;
    server_name $domain;

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

  $SUDO ln -sf "$conf" /etc/nginx/sites-enabled/vodia-pharmacy-ai

  $SUDO nginx -t
  $SUDO systemctl reload nginx

  echo "[domain] Active Nginx server_name:"
  $SUDO grep -n "server_name\|proxy_pass" /etc/nginx/sites-enabled/vodia-pharmacy-ai || true
}


update_voice_agent_urls() {
  local base_url="$1"

  if [ ! -d "$APP_DIR" ]; then
    echo "[domain] App directory missing, cannot update Voice Agent URLs: $APP_DIR"
    return 0
  fi

  $SUDO python3 - "$APP_DIR" "$base_url" <<'PY'
from pathlib import Path
import re
import sys

app = Path(sys.argv[1])
base = sys.argv[2].rstrip("/")

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
        continue

    txt = path.read_text()
    txt = txt.replace("http://_", base)
    txt = txt.replace("https://_", base)

    for var_name, api_path in mapping.items():
        url = base + api_path
        pattern = r'(var\s+' + re.escape(var_name) + r'\s*=\s*)["\'][^"\']*["\']'
        txt = re.sub(pattern, lambda m: f'{m.group(1)}"{url}"', txt)

    path.write_text(txt)
    print(f"Updated {path}")
PY
}

configure_http_only_domain() {
  local domain="$1"
  local base_url="http://$domain"

  echo "[domain] Configuring HTTP hostname only: $domain"

  update_nginx_server_name "$domain"

  if [ -f "$APP_DIR/.env" ]; then
    set_env_value "$APP_DIR/.env" "PHARMACY_DOMAIN" "$domain"
    set_env_value "$APP_DIR/.env" "PHARMACY_PUBLIC_BASE_URL" "$base_url"
    set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$base_url"
    set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$base_url"
  fi

  update_voice_agent_urls "$base_url"

  echo "$base_url" | $SUDO tee /root/vodia-pharmacy-ai-public-url.txt >/dev/null

  if [ -f /root/vodia-pharmacy-ai-portal-login.txt ]; then
    $SUDO sed -i -E "s#^URL: .*#URL: $base_url/portal#" /root/vodia-pharmacy-ai-portal-login.txt
  fi

  echo
  echo "[domain] HTTP public URLs:"
  echo "  $base_url/portal"
  echo "  $base_url/portal/settings"
  echo "  $base_url/portal/voice-agent"
}

configure_https_domain() {
  local domain="$1"
  local email="${LETSENCRYPT_EMAIL:-}"

  echo "[domain] Installing Certbot..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y certbot python3-certbot-nginx

  if [ -z "$email" ] && [ "$NONINTERACTIVE" != "true" ] && [ -t 0 ]; then
    read -r -p "Let's Encrypt email, optional but recommended: " email || true
  fi

  local args=(--nginx -d "$domain" --agree-tos --redirect --non-interactive)

  if [ -n "$email" ]; then
    args+=(-m "$email")
  else
    args+=(--register-unsafely-without-email)
  fi

  echo "[domain] Requesting certificate for $domain..."
  $SUDO certbot "${args[@]}"

  local base_url="https://$domain"

  if [ -f "$APP_DIR/.env" ]; then
    set_env_value "$APP_DIR/.env" "PHARMACY_DOMAIN" "$domain"
    set_env_value "$APP_DIR/.env" "PHARMACY_PUBLIC_BASE_URL" "$base_url"
    set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$base_url"
    set_env_value "$APP_DIR/.env" "PUBLIC_BASE_URL" "$base_url"
  fi

  update_voice_agent_urls "$base_url"

  echo "$base_url" | $SUDO tee /root/vodia-pharmacy-ai-public-url.txt >/dev/null

  if [ -f /root/vodia-pharmacy-ai-portal-login.txt ]; then
    $SUDO sed -i -E "s#^URL: .*#URL: $base_url/portal#" /root/vodia-pharmacy-ai-portal-login.txt
  fi

  echo
  echo "[domain] HTTPS public URLs:"
  echo "  $base_url/portal"
  echo "  $base_url/portal/settings"
  echo "  $base_url/portal/voice-agent"
}

echo
echo "=================================================="
echo " DNS / HTTPS setup"
echo "=================================================="

if [ -z "$DOMAIN" ]; then
  if [ "$NONINTERACTIVE" = "true" ] || [ ! -t 0 ]; then
    echo "[domain] No PHARMACY_FQDN provided. Skipping HTTPS."
    exit 0
  fi

  read -r -p "Do you want to use your own DNS/FQDN and configure HTTPS now? [y/N]: " use_dns || true

  case "${use_dns:-}" in
    y|Y|yes|YES)
      read -r -p "Enter hostname/FQDN, example pharmacy.example.com: " DOMAIN || true
      ;;
    *)
      echo "[domain] Skipping DNS/HTTPS. App will remain HTTP-only."
      exit 0
      ;;
  esac
fi

DOMAIN="$(normalize_domain "$DOMAIN")"

if ! valid_domain "$DOMAIN"; then
  echo "[domain] Invalid hostname/FQDN: $DOMAIN"
  exit 1
fi

$SUDO apt-get update -y
$SUDO apt-get install -y dnsutils curl ca-certificates nginx

PUBLIC_IP="$(get_public_ip | tr -d '[:space:]')"

if [ -z "$PUBLIC_IP" ]; then
  echo "[domain] Could not detect public IP. Configuring HTTP only."
  configure_http_only_domain "$DOMAIN"
  exit 0
fi

while true; do
  DNS_IPS="$(get_dns_ips "$DOMAIN")"

  echo
  echo "[domain] Domain: $DOMAIN"
  echo "[domain] Server public IP: $PUBLIC_IP"
  echo "[domain] DNS A record IP(s): ${DNS_IPS:-none}"

  if echo " $DNS_IPS " | grep -q " $PUBLIC_IP "; then
    echo "[domain] DNS matches this server."
    break
  fi

  echo
  echo "[domain] DNS does not point to this server yet."
  echo "Create or update this DNS record:"
  echo
  echo "  Type: A"
  echo "  Name/FQDN: $DOMAIN"
  echo "  Value: $PUBLIC_IP"
  echo "  TTL: 300"
  echo

  if [ "$NONINTERACTIVE" = "true" ] || [ ! -t 0 ]; then
    echo "[domain] Non-interactive mode. Configuring HTTP only and skipping Certbot."
    configure_http_only_domain "$DOMAIN"
    exit 0
  fi

  echo "Choose:"
  echo "  r = recheck DNS"
  echo "  c = change hostname"
  echo "  s = skip HTTPS and use HTTP for now"
  echo "  q = quit"
  read -r -p "Choice [r/c/s/q]: " choice || true

  case "${choice:-r}" in
    r|R)
      continue
      ;;
    c|C)
      read -r -p "Enter hostname/FQDN: " DOMAIN || true
      DOMAIN="$(normalize_domain "$DOMAIN")"
      if ! valid_domain "$DOMAIN"; then
        echo "[domain] Invalid hostname/FQDN: $DOMAIN"
      fi
      ;;
    s|S)
      configure_http_only_domain "$DOMAIN"
      exit 0
      ;;
    q|Q)
      echo "[domain] Quit requested."
      exit 1
      ;;
    *)
      continue
      ;;
  esac
done

update_nginx_server_name "$DOMAIN"

echo
echo "[domain] HTTP check:"
curl -I "http://$DOMAIN/portal" || true

configure_https_domain "$DOMAIN"

echo
echo "[domain] Final HTTPS check:"
curl -I "https://$DOMAIN/portal" || true
curl -I "https://$DOMAIN/portal/settings" || true
curl -I "https://$DOMAIN/portal/voice-agent" || true

echo
echo "[domain] DNS/HTTPS setup complete."
