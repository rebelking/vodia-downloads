#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-0.2.3}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vodia-pharmacy-ai-demo}"
PORT="${PORT:-3200}"
DOMAIN="${DOMAIN:-localhost}"
APP_NAME="${APP_NAME:-vodia-pharmacy-ai-demo}"
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

echo "Vodia Pharmacy AI installer"
echo "Version: $APP_VERSION"
echo "Install dir: $INSTALL_DIR"
echo "Port: $PORT"
echo "Domain: $DOMAIN"
echo "HTTPS: $ENABLE_HTTPS"
echo ""

if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Run this installer with sudo."
  echo "Example:"
  echo "  curl -fsSL https://get.tryvodia.com/pharmacy-ai/install-ubuntu.sh | sudo bash"
  exit 1
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_public_ip() {
  local ip=""
  ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -4fsSL https://ifconfig.me 2>/dev/null || true)"
  fi
  echo "$ip"
}

resolve_domain_ipv4() {
  local host="$1"

  if command_exists dig; then
    dig +short A "$host" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u || true
    return
  fi

  if command_exists getent; then
    getent ahostsv4 "$host" | awk '{print $1}' | sort -u || true
    return
  fi

  if command_exists host; then
    host "$host" | awk '/has address/ {print $NF}' | sort -u || true
    return
  fi

  echo ""
}

validate_domain_hostname() {
  local host="$1"

  if [ -z "$host" ] || [ "$host" = "localhost" ]; then
    echo "ERROR: HTTPS setup requires a real domain."
    echo "Example:"
    echo "  DOMAIN=pharmacy.example.com ENABLE_HTTPS=true"
    exit 1
  fi

  if echo "$host" | grep -qiE '^https?://'; then
    echo "ERROR: DOMAIN must be only the hostname."
    echo "Use:"
    echo "  DOMAIN=pharmacy.example.com"
    echo "Do not use:"
    echo "  DOMAIN=https://pharmacy.example.com"
    exit 1
  fi

  if echo "$host" | grep -q '/'; then
    echo "ERROR: DOMAIN must not include a path."
    echo "Use only the hostname, for example:"
    echo "  DOMAIN=pharmacy.example.com"
    exit 1
  fi
}

check_dns_ready_for_https() {
  local host="$1"
  local public_ip=""
  local dns_ips=""

  validate_domain_hostname "$host"

  echo "Checking DNS before HTTPS setup..."
  echo "Domain: $host"

  public_ip="$(get_public_ip)"
  if [ -z "$public_ip" ]; then
    echo "ERROR: Could not detect this server public IPv4 address."
    echo "Check outbound internet access and run the installer again."
    exit 1
  fi

  dns_ips="$(resolve_domain_ipv4 "$host")"

  echo "Server public IP:"
  echo "  $public_ip"
  echo "DNS result for $host:"
  if [ -n "$dns_ips" ]; then
    echo "$dns_ips" | sed 's/^/  /'
  else
    echo "  No IPv4 A record found."
  fi
  echo ""

  if ! echo "$dns_ips" | grep -qx "$public_ip"; then
    echo "ERROR: DNS is not ready."
    echo ""
    echo "$host must point to this server public IP before HTTPS setup can continue."
    echo ""
    echo "Create or update this DNS record:"
    echo "  Type:  A"
    echo "  Name:  $host"
    echo "  Value: $public_ip"
    echo ""
    echo "After DNS updates, run the installer again:"
    echo "  curl -fsSL https://get.tryvodia.com/pharmacy-ai/install-ubuntu.sh | sudo env DOMAIN=$host ENABLE_HTTPS=true bash"
    echo ""
    echo "Tip: If DNS was just changed, wait for propagation and try again."
    exit 1
  fi

  echo "DNS check passed."
  echo ""
}

if [ "$ENABLE_HTTPS" = "true" ]; then
  check_dns_ready_for_https "$DOMAIN"
fi

echo "Updating apt packages..."
apt-get update -y

echo "Installing required packages..."
apt-get install -y curl ca-certificates gnupg lsb-release unzip

if [ "$ENABLE_HTTPS" = "true" ]; then
  apt-get install -y nginx certbot python3-certbot-nginx dnsutils
else
  apt-get install -y dnsutils || true
fi

if ! command_exists node; then
  echo "Installing Node.js 20..."
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi

if ! command_exists pm2; then
  echo "Installing PM2..."
  npm install -g pm2
fi

echo "Preparing install directory..."
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Installing Vodia Pharmacy AI from NPM..."
npm init -y >/dev/null 2>&1 || true
npm install "vodia-pharmacy-ai@$APP_VERSION"

echo "Writing environment file..."
if [ "$ENABLE_HTTPS" = "true" ]; then
  PUBLIC_URL="https://$DOMAIN"
else
  if [ "$DOMAIN" = "localhost" ]; then
    PUBLIC_URL="http://$(get_public_ip):$PORT"
  else
    PUBLIC_URL="http://$DOMAIN:$PORT"
  fi
fi

EXISTING_SECRET=""
if [ -f "$INSTALL_DIR/.env" ]; then
  EXISTING_SECRET="$(grep '^PHARMACY_API_SECRET=' "$INSTALL_DIR/.env" | cut -d= -f2- || true)"
fi

if [ -z "$EXISTING_SECRET" ]; then
  EXISTING_SECRET="$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")"
fi

cat > "$INSTALL_DIR/.env" <<EOF
NODE_ENV=production
PORT=$PORT
DOMAIN=$DOMAIN
PUBLIC_URL=$PUBLIC_URL
PHARMACY_API_SECRET=$EXISTING_SECRET
DATABASE_PATH=./pharmacy.db
EOF

chmod 600 "$INSTALL_DIR/.env"

echo "Starting app with PM2..."
pm2 stop "$APP_NAME" >/dev/null 2>&1 || true
pm2 delete "$APP_NAME" >/dev/null 2>&1 || true

PORT="$PORT" pm2 start "$INSTALL_DIR/node_modules/.bin/vodia-pharmacy-ai" --name "$APP_NAME" --update-env
pm2 save || true

echo "Waiting for app..."
sleep 4

if [ "$ENABLE_HTTPS" = "true" ]; then
  echo "Configuring nginx reverse proxy..."

  cat > "/etc/nginx/sites-available/$APP_NAME" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/$APP_NAME"
  nginx -t
  systemctl reload nginx

  echo "Requesting Let's Encrypt certificate..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" --redirect || {
    echo ""
    echo "ERROR: Certbot failed."
    echo "DNS passed, but certificate issuance failed."
    echo "Check ports 80/443, firewall, and nginx logs."
    exit 1
  }
fi

echo ""
echo "Checking port $PORT..."
ss -ltnp | grep ":$PORT" || true

echo ""
echo "Health check:"
if [ "$ENABLE_HTTPS" = "true" ]; then
  curl -fsSL "https://$DOMAIN/health" || true
else
  curl -fsSL "http://127.0.0.1:$PORT/health" || true
fi
echo ""

echo ""
echo "Vodia Pharmacy AI install complete ✅"
echo ""

if [ "$ENABLE_HTTPS" = "true" ]; then
  echo "Portal:"
  echo "  https://$DOMAIN/portal"
else
  echo "Portal:"
  echo "  $PUBLIC_URL/portal"
fi

echo ""
echo "Generate Vodia Audio AI script values AFTER this install:"
echo "  sudo npx -y vodia-pharmacy-ai@$APP_VERSION vodia-script --dir $INSTALL_DIR"
echo ""
echo "Important:"
echo "  Paste the generated values into the top customer configuration section of:"
echo "  https://get.tryvodia.com/pharmacy-ai/audio-ai-script.js"
echo ""
