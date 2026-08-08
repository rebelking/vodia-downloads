#!/usr/bin/env bash
set -Eeuo pipefail

APP_VERSION="0.5.0"
APP_DIR="/opt/vodia-mcp"
ENV_FILE="/etc/vodia-mcp.env"
SERVICE_FILE="/etc/systemd/system/vodia-mcp.service"
CADDY_SNIPPET="/etc/caddy/conf.d/vodia-mcp.caddy"
PACKAGE_URL_DEFAULT="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/vodia-mcp-v${APP_VERSION}.zip"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this installer with sudo: sudo bash install-vodia-mcp.sh"
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This installer supports Ubuntu/Debian systems that use apt."
  exit 1
fi

prompt_required() {
  local label="$1" value=""
  while [[ -z "$value" ]]; do
    read -r -p "$label: " value </dev/tty
  done
  printf '%s' "$value"
}

escape_env() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

existing_hex_token() {
  local key="$1"
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^${key}=\"\([0-9a-f]\{64\}\)\"$/\1/p" "$ENV_FILE" | head -n1
}

echo
echo "Vodia PBX MCP ${APP_VERSION} — Caddy HTTPS installer"
echo "----------------------------------------------------"
echo "Before continuing, create an A/AAAA DNS record pointing to this EC2 instance."
echo "AWS Security Group inbound ports 80 and 443 must be open."
echo

MCP_DOMAIN="$(prompt_required "Public MCP domain (example: mcp.tryvodia.com)")"
VODIA_URL="$(prompt_required "Vodia PBX URL (example: https://pbx.example.com)")"
VODIA_USER="$(prompt_required "Dedicated Vodia API username")"
read -r -s -p "Vodia API password: " VODIA_PASS </dev/tty
echo
[[ -n "$VODIA_PASS" ]] || { echo "Vodia API password cannot be empty."; exit 1; }

if [[ ! "$MCP_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || [[ "$MCP_DOMAIN" != *.* ]]; then
  echo "The MCP domain is not valid: $MCP_DOMAIN"
  exit 1
fi
if [[ ! "$VODIA_URL" =~ ^https:// ]]; then
  echo "Use an HTTPS Vodia PBX URL."
  exit 1
fi

MCP_TOKEN="$(existing_hex_token MCP_BEARER_TOKEN)"
ADMIN_TOKEN="$(existing_hex_token ADMIN_TOKEN)"
MCP_TOKEN="${MCP_TOKEN:-$(openssl rand -hex 32)}"
ADMIN_TOKEN="${ADMIN_TOKEN:-$(openssl rand -hex 32)}"
PACKAGE_URL="${VODIA_MCP_PACKAGE_URL:-$PACKAGE_URL_DEFAULT}"
TEMP_DIR="$(mktemp -d)"
trap 'find "$TEMP_DIR" -mindepth 1 -delete 2>/dev/null || true; rmdir "$TEMP_DIR" 2>/dev/null || true' EXIT

echo
echo "[1/7] Installing operating-system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget unzip openssl debian-keyring debian-archive-keyring apt-transport-https

if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)" -lt 18 ]]; then
  echo "Installing Node.js 22 because Node.js 18+ is required..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
fi

if ! command -v caddy >/dev/null 2>&1; then
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y caddy
fi

echo "[2/7] Downloading Vodia MCP package with wget..."
wget --https-only --secure-protocol=TLSv1_2 -O "$TEMP_DIR/vodia-mcp.zip" "$PACKAGE_URL"
unzip -q "$TEMP_DIR/vodia-mcp.zip" -d "$TEMP_DIR/release"
[[ -f "$TEMP_DIR/release/vodia-mcp/http.js" ]] || { echo "Downloaded package is missing vodia-mcp/http.js"; exit 1; }

echo "[3/7] Installing application files..."
install -d -m 0755 "$APP_DIR"
cp -a "$TEMP_DIR/release/vodia-mcp/." "$APP_DIR/"
cd "$APP_DIR"
npm ci --omit=dev
npm run check
npm test

if ! id -u vodiamcp >/dev/null 2>&1; then
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin vodiamcp
fi
chown -R root:root "$APP_DIR"
chmod -R a+rX "$APP_DIR"

echo "[4/7] Writing protected service configuration..."
install -m 0600 /dev/null "$ENV_FILE"
cat > "$ENV_FILE" <<EOF
VODIA_URL="$(escape_env "${VODIA_URL%/}")"
VODIA_USER="$(escape_env "$VODIA_USER")"
VODIA_PASS="$(escape_env "$VODIA_PASS")"
MCP_BEARER_TOKEN="$MCP_TOKEN"
ADMIN_TOKEN="$ADMIN_TOKEN"
HOST="127.0.0.1"
PORT="3100"
NODE_ENV="production"
EOF

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Vodia PBX read-only MCP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=vodiamcp
Group=vodiamcp
WorkingDirectory=/opt/vodia-mcp
EnvironmentFile=/etc/vodia-mcp.env
ExecStart=/usr/bin/node /opt/vodia-mcp/http.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

echo "[5/7] Configuring Caddy automatic HTTPS..."
install -d -m 0755 /etc/caddy/conf.d
cat > "$CADDY_SNIPPET" <<EOF
$MCP_DOMAIN {
    encode zstd gzip
    reverse_proxy 127.0.0.1:3100
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "no-referrer"
    }
}
EOF

if ! grep -Fq 'import /etc/caddy/conf.d/*.caddy' /etc/caddy/Caddyfile; then
  printf '\nimport /etc/caddy/conf.d/*.caddy\n' >> /etc/caddy/Caddyfile
fi
caddy fmt --overwrite /etc/caddy/Caddyfile "$CADDY_SNIPPET"
caddy validate --config /etc/caddy/Caddyfile

echo "[6/7] Starting services..."
systemctl daemon-reload
systemctl enable --now vodia-mcp
systemctl reload caddy

echo "[7/7] Running local health check..."
for _ in {1..15}; do
  if curl -fsS http://127.0.0.1:3100/health >/dev/null; then break; fi
  sleep 1
done
curl -fsS http://127.0.0.1:3100/health >/dev/null || {
  echo "MCP service did not become healthy. Run: journalctl -u vodia-mcp -n 100 --no-pager"
  exit 1
}

install -m 0600 /dev/null /root/vodia-mcp-credentials.txt
cat > /root/vodia-mcp-credentials.txt <<EOF
Admin dashboard: https://$MCP_DOMAIN/admin/
MCP endpoint: https://$MCP_DOMAIN/mcp
Admin token: $ADMIN_TOKEN
MCP bearer token: $MCP_TOKEN
EOF

echo
echo "Installation complete."
echo "Admin dashboard: https://$MCP_DOMAIN/admin/"
echo "MCP endpoint:    https://$MCP_DOMAIN/mcp"
echo "Admin token:     $ADMIN_TOKEN"
echo "MCP token:       $MCP_TOKEN"
echo
echo "A root-only copy was saved to /root/vodia-mcp-credentials.txt"
echo "If HTTPS is not ready, verify DNS and AWS Security Group ports 80/443."
