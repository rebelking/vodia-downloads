#!/usr/bin/env bash
set -euo pipefail

APP_VERSION="${APP_VERSION:-0.2.3}"
INSTALL_DIR="${INSTALL_DIR:-/opt/vodia-pharmacy-ai-demo}"
PORT="${PORT:-3200}"
DOMAIN="${DOMAIN:-localhost}"
APP_NAME="${APP_NAME:-vodia-pharmacy-ai-demo}"
ENABLE_HTTPS="${ENABLE_HTTPS:-false}"

if [ "$EUID" -ne 0 ]; then
  echo "Please run this installer with sudo:"
  echo "curl -fsSL https://get.vodia.com/pharmacy-ai/install-ubuntu.sh | sudo bash"
  exit 1
fi

echo "Vodia Pharmacy AI Ubuntu installer"
echo "App version: $APP_VERSION"
echo "Install dir: $INSTALL_DIR"
echo "Port: $PORT"
echo "Domain: $DOMAIN"
echo "App name: $APP_NAME"
echo "HTTPS: $ENABLE_HTTPS"
echo

echo "Installing Ubuntu prerequisites..."
apt-get update
apt-get install -y curl ca-certificates gnupg build-essential sqlite3 dnsutils

if ! command -v node >/dev/null 2>&1; then
  echo "Installing Node.js..."
  curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
  apt-get install -y nodejs
else
  echo "Node.js already installed: $(node -v)"
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm was not found after Node.js installation."
  exit 1
fi

echo "npm: $(npm -v)"
echo "npx: $(npx -v)"

if ! command -v pm2 >/dev/null 2>&1; then
  echo "Installing PM2..."
  npm install -g pm2
else
  echo "PM2 already installed: $(pm2 -v)"
fi

INSTALL_ARGS=(
  install
  --demo
  --dir "$INSTALL_DIR"
  --port "$PORT"
  --domain "$DOMAIN"
  --app-name "$APP_NAME"
  --force
)

if [ "$ENABLE_HTTPS" = "true" ] && [ "$DOMAIN" != "localhost" ]; then
  echo "HTTPS requested for $DOMAIN"

  PUBLIC_IP="$(curl -fsSL https://api.ipify.org || true)"
  DNS_IP="$(dig +short "$DOMAIN" A | tail -n1 || true)"

  echo "Server public IP: $PUBLIC_IP"
  echo "DNS IP for $DOMAIN: $DNS_IP"

  if [ -z "$DNS_IP" ]; then
    echo
    echo "DNS does not resolve yet."
    echo "Create this DNS record first:"
    echo "$DOMAIN A $PUBLIC_IP"
    exit 1
  fi

  if [ -n "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "$DNS_IP" ]; then
    echo
    echo "DNS does not point to this server yet."
    echo "Create or update this DNS record:"
    echo "$DOMAIN A $PUBLIC_IP"
    exit 1
  fi

  echo "Installing Caddy..."
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy

  INSTALL_ARGS+=(--caddy)
fi

echo
echo "Installing Vodia Pharmacy AI from npm..."

npx -y "vodia-pharmacy-ai@$APP_VERSION" "${INSTALL_ARGS[@]}"

echo
echo "Restarting app with port preserved..."

PORT="$PORT" pm2 restart "$APP_NAME" --update-env || true
pm2 save || true

sleep 2

echo
echo "Checking PM2..."
pm2 list

echo
echo "Checking port $PORT..."
ss -ltnp | grep ":$PORT" || true

echo
echo "Health check:"
curl -fsS "http://127.0.0.1:$PORT/health" || true

echo
echo
echo "Vodia Pharmacy AI install complete ✅"
echo

echo "Portal:"
if [ "$ENABLE_HTTPS" = "true" ] && [ "$DOMAIN" != "localhost" ]; then
  echo "  https://$DOMAIN/portal/login"
else
  PUBLIC_IP="$(curl -fsSL https://api.ipify.org || true)"
  if [ -n "$PUBLIC_IP" ]; then
    echo "  http://$PUBLIC_IP:$PORT/portal/login"
  else
    echo "  http://SERVER_IP:$PORT/portal/login"
  fi
fi

echo
echo "Health:"
echo "  curl http://127.0.0.1:$PORT/health"

echo
echo "Vodia script values:"
echo "  npx -y vodia-pharmacy-ai@$APP_VERSION vodia-script --dir $INSTALL_DIR"
echo
