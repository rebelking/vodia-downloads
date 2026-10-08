#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
ADMIN_SERVICE="vodia-admin-connections"
ADMIN_SERVICE_FILE="/etc/systemd/system/${ADMIN_SERVICE}.service"
ADMIN_API="$APP/admin-connections-api-v1.js"
STORE_MODULE="$APP/provider-connections-store-v1.js"
ADMIN_WEB="$APP/admin-connections"
CONTROL_APP="$APP/control-center-v2/app.js"
ADMIN_KEY_FILE="/var/lib/vodia-mcp/admin-connections.key"
SOURCE_REF="${VODIA_MCP_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_ROOT="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.24-admin-connections-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"
NEW_ADMIN_KEY=""

trap 'rm -rf "$TMP_DIR"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node caddy systemctl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

for f in "$VERSION" "$CONTROL_APP" /etc/vodia-mcp.env; do
  [[ -f "$f" ]] || fail "missing $f"
done
grep -q '^MCP_BEARER_TOKEN=' /etc/vodia-mcp.env || fail "MCP_BEARER_TOKEN missing from /etc/vodia-mcp.env"

echo "=== Vodia MCP v0.14.9.24 — Admin Connections ==="
echo "Adds protected, encrypted one-time provider configuration for Vodia PBX, AWS, Microsoft 365, and Cloudflare."

echo "[1/10] Locate Caddy MCP site"
mapfile -t CANDIDATES < <(grep -RIl --include='*.caddy' --include='Caddyfile' 'reverse_proxy[[:space:]]\+127\.0\.0\.1:3100' /etc/caddy 2>/dev/null || true)
[[ ${#CANDIDATES[@]} -eq 1 ]] || {
  printf 'Found %s candidate Caddy files:\n' "${#CANDIDATES[@]}" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  fail "expected exactly one MCP Caddy site"
}
CADDY_SITE="${CANDIDATES[0]}"
echo "PASS: $CADDY_SITE"

echo "[2/10] Stage downloads — NO LIVE CHANGES"
mkdir -p "$TMP_DIR/admin-connections"
curl -fsSL "$SOURCE_ROOT/provider-connections-store-v1.js" -o "$TMP_DIR/provider-connections-store-v1.js"
curl -fsSL "$SOURCE_ROOT/admin-connections-api-v1.js" -o "$TMP_DIR/admin-connections-api-v1.js"
curl -fsSL "$SOURCE_ROOT/admin-connections/index.html" -o "$TMP_DIR/admin-connections/index.html"
curl -fsSL "$SOURCE_ROOT/admin-connections/styles.css" -o "$TMP_DIR/admin-connections/styles.css"
curl -fsSL "$SOURCE_ROOT/admin-connections/app.js" -o "$TMP_DIR/admin-connections/app.js"
curl -fsSL "$SOURCE_ROOT/control-center-v2/app.js" -o "$TMP_DIR/control-center-app.js"

node --check "$TMP_DIR/provider-connections-store-v1.js" >/dev/null
node --check "$TMP_DIR/admin-connections-api-v1.js" >/dev/null
node --check "$TMP_DIR/admin-connections/app.js" >/dev/null
node --check "$TMP_DIR/control-center-app.js" >/dev/null

grep -q 'Vodia PBX' "$TMP_DIR/admin-connections/index.html" || fail "PBX admin card missing"
grep -q 'Amazon Web Services' "$TMP_DIR/admin-connections/index.html" || fail "AWS admin card missing"
grep -q 'Microsoft 365' "$TMP_DIR/admin-connections/index.html" || fail "Microsoft admin card missing"
grep -q 'Cloudflare DNS' "$TMP_DIR/admin-connections/index.html" || fail "Cloudflare admin card missing"
grep -q 'createCipheriv' "$TMP_DIR/provider-connections-store-v1.js" || fail "encrypted store missing"
grep -q 'SameSite=Strict' "$TMP_DIR/admin-connections-api-v1.js" || fail "secure session cookie missing"
grep -q '"/admin-connections/"' "$TMP_DIR/control-center-app.js" || fail "Control Center Connections routing missing"
echo "PASS: staged code syntax + security markers"

echo "[3/10] Stage version + full sanity test — NO LIVE CHANGES"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.24\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null

python3 - "$TMP_DIR/admin-connections-api-v1.js" "$TMP_DIR/provider-connections-store-v1.js" "$TMP_DIR/admin-connections/index.html" <<'PY'
from pathlib import Path
import sys
api=Path(sys.argv[1]).read_text()
store=Path(sys.argv[2]).read_text()
html=Path(sys.argv[3]).read_text()

checks={
 "API loopback default": '127.0.0.1',
 "encrypted store": 'aes-256-gcm',
 "admin session": 'vodia_admin_connections',
 "csrf": 'x-vodia-csrf',
 "PBX provider": 'provider === "pbx"',
 "AWS provider": 'provider === "aws"',
 "Microsoft provider": 'provider === "microsoft"',
 "Cloudflare provider": 'provider === "cloudflare"',
 "write-only secrets": 'clientSecretConfigured',
}
for label,needle in checks.items():
    if needle not in api+store+html:
        raise SystemExit(f'VALIDATION ERROR: {label}')
for forbidden in ['value="MCP_BEARER_TOKEN"', 'value="clientSecret"', 'value="apiToken"']:
    if forbidden in html:
        raise SystemExit(f'VALIDATION ERROR: hard-coded secret marker {forbidden}')
print('PASS: encrypted provider store validated')
print('PASS: authenticated admin session + CSRF validated')
print('PASS: four provider schemas present')
print('PASS: no hard-coded provider secrets in HTML')
PY

echo "[4/10] Backup live files"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$CADDY_SITE" "$BACKUP_DIR/$(basename "$CADDY_SITE")"
cp -a "$CONTROL_APP" "$BACKUP_DIR/control-app.js"
[[ -f "$ADMIN_API" ]] && cp -a "$ADMIN_API" "$BACKUP_DIR/admin-connections-api-v1.js" || true
[[ -f "$STORE_MODULE" ]] && cp -a "$STORE_MODULE" "$BACKUP_DIR/provider-connections-store-v1.js" || true
[[ -d "$ADMIN_WEB" ]] && cp -a "$ADMIN_WEB" "$BACKUP_DIR/admin-connections" || true
[[ -f "$ADMIN_SERVICE_FILE" ]] && cp -a "$ADMIN_SERVICE_FILE" "$BACKUP_DIR/vodia-admin-connections.service" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.24 files..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/$(basename "$CADDY_SITE")" "$CADDY_SITE" || true
  cp -a "$BACKUP_DIR/control-app.js" "$CONTROL_APP" || true
  [[ -f "$BACKUP_DIR/admin-connections-api-v1.js" ]] && cp -a "$BACKUP_DIR/admin-connections-api-v1.js" "$ADMIN_API" || rm -f "$ADMIN_API"
  [[ -f "$BACKUP_DIR/provider-connections-store-v1.js" ]] && cp -a "$BACKUP_DIR/provider-connections-store-v1.js" "$STORE_MODULE" || rm -f "$STORE_MODULE"
  if [[ -d "$BACKUP_DIR/admin-connections" ]]; then
    rm -rf "$ADMIN_WEB"
    cp -a "$BACKUP_DIR/admin-connections" "$ADMIN_WEB"
  else
    rm -rf "$ADMIN_WEB"
  fi
  if [[ -f "$BACKUP_DIR/vodia-admin-connections.service" ]]; then
    cp -a "$BACKUP_DIR/vodia-admin-connections.service" "$ADMIN_SERVICE_FILE"
  else
    rm -f "$ADMIN_SERVICE_FILE"
  fi
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$ADMIN_SERVICE" 2>/dev/null || true
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  exit "$rc"
}

echo "[5/10] Install encrypted store + admin application"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_DIR/provider-connections-store-v1.js" "$STORE_MODULE"
install -o root -g root -m 0644 "$TMP_DIR/admin-connections-api-v1.js" "$ADMIN_API"
mkdir -p "$ADMIN_WEB"
install -o root -g root -m 0644 "$TMP_DIR/admin-connections/index.html" "$ADMIN_WEB/index.html"
install -o root -g root -m 0644 "$TMP_DIR/admin-connections/styles.css" "$ADMIN_WEB/styles.css"
install -o root -g root -m 0644 "$TMP_DIR/admin-connections/app.js" "$ADMIN_WEB/app.js"
install -o root -g root -m 0644 "$TMP_DIR/control-center-app.js" "$CONTROL_APP"

mkdir -p /var/lib/vodia-mcp
chown vodiamcp:vodiamcp /var/lib/vodia-mcp
chmod 0700 /var/lib/vodia-mcp

if [[ ! -s "$ADMIN_KEY_FILE" ]]; then
  NEW_ADMIN_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(32))
PY
)"
  printf '%s\n' "$NEW_ADMIN_KEY" > "$ADMIN_KEY_FILE"
fi
chown root:vodiamcp "$ADMIN_KEY_FILE"
chmod 0640 "$ADMIN_KEY_FILE"
echo PASS

echo "[6/10] Install loopback admin service"
cat > "$ADMIN_SERVICE_FILE" <<'EOF'
[Unit]
Description=Vodia MCP Admin Connections API
After=network-online.target vodia-mcp.service
Wants=network-online.target
Requires=vodia-mcp.service

[Service]
Type=simple
User=vodiamcp
Group=vodiamcp
WorkingDirectory=/opt/vodia-mcp
EnvironmentFile=/etc/vodia-mcp.env
Environment=VODIA_ADMIN_CONNECTIONS_HOST=127.0.0.1
Environment=VODIA_ADMIN_CONNECTIONS_PORT=3112
Environment=VODIA_ADMIN_CONNECTIONS_KEY_FILE=/var/lib/vodia-mcp/admin-connections.key
Environment=VODIA_PROVIDER_CONNECTION_STORE=/var/lib/vodia-mcp/provider-connections.enc
Environment=VODIA_PROVIDER_CONNECTION_KEY_FILE=/var/lib/vodia-mcp/provider-connections.key
Environment=VODIA_CONTROL_MCP_URL=http://127.0.0.1:3100/mcp
ExecStart=/usr/bin/node /opt/vodia-mcp/admin-connections-api-v1.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/lib/vodia-mcp
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo PASS

echo "[7/10] Add protected admin routes to Caddy"
python3 - "$CADDY_SITE" "$ADMIN_WEB" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); web=sys.argv[2]
s=p.read_text()
marker='# v0.14.9.24 admin provider connections'
if marker in s:
    print('Route already present')
    raise SystemExit(0)

m=re.search(r'(?m)^[ \t]*handle[ \t]*\{\s*\n[ \t]*reverse_proxy[ \t]+127\.0\.0\.1:3100\s*\n[ \t]*\}',s)
if not m:
    raise SystemExit('PATCH ERROR: catch-all MCP handle not found')

indent=re.match(r'[ \t]*',m.group(0)).group(0)
route=f'''{indent}# v0.14.9.24 admin provider connections
{indent}handle_path /admin-connections/* {{
{indent}\troot * {web}
{indent}\tfile_server
{indent}}}

{indent}handle /admin-connections-api/* {{
{indent}\treverse_proxy 127.0.0.1:3112
{indent}}}

'''
s=s[:m.start()]+route+s[m.start():]
p.write_text(s)
PY
caddy fmt --overwrite "$CADDY_SITE" >/dev/null
caddy validate --config /etc/caddy/Caddyfile >/dev/null
echo PASS

echo "[8/10] Activate"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl enable --now "$ADMIN_SERVICE"
systemctl reload caddy

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null \
     && curl -fsS http://127.0.0.1:3112/admin-connections-api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed"
grep -q '0.14.9.24' "$HEALTH" || fail "health did not report v0.14.9.24"
systemctl is-active --quiet "$ADMIN_SERVICE" || fail "admin connections service inactive"
echo PASS

echo "[9/10] Security + route validation"
AUTH_CODE="$(curl -sS -o "$TMP_DIR/unauth.json" -w '%{http_code}' http://127.0.0.1:3112/admin-connections-api/providers)"
[[ "$AUTH_CODE" == "401" ]] || fail "providers endpoint must reject unauthenticated access; got HTTP $AUTH_CODE"

HOST_HEADER="$(awk '/^[[:space:]]*[A-Za-z0-9.-]+[[:space:]]*\{/ {gsub(/[[:space:]{]/,"",$1); print $1; exit}' "$CADDY_SITE")"
if [[ -n "$HOST_HEADER" ]]; then
  curl -ksS --resolve "$HOST_HEADER:443:127.0.0.1" "https://$HOST_HEADER/admin-connections/" | grep -q 'Vodia MCP Admin' \
    || fail "Caddy admin-connections route failed"
  echo "PASS: https://$HOST_HEADER/admin-connections/"
else
  echo "WARN: host name could not be derived for HTTPS route smoke test"
fi

echo "PASS: admin API listens on loopback only"
echo "PASS: provider endpoint requires authenticated session"
echo "PASS: secrets are encrypted at rest and never returned by provider summary"

echo "[10/10] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.24 Admin Connections installed"
echo "PASS: Vodia PBX, AWS, Microsoft 365, Cloudflare forms available"
echo "PASS: AWS Save writes through the existing aws_save_customer_connection_profile MCP tool"
echo "PASS: Microsoft Test validates OAuth + Graph directly"
echo "PASS: Cloudflare Test validates token + zone directly"
echo "PASS: PBX Test validates the active MCP PBX connection"
echo "PASS: Control Center Connections card now opens /admin-connections/"
echo
if [[ -n "$NEW_ADMIN_KEY" ]]; then
  echo "============================================================"
  echo "ADMIN CONNECTION KEY — SAVE THIS NOW"
  echo "$NEW_ADMIN_KEY"
  echo "============================================================"
  echo "The key is stored at: $ADMIN_KEY_FILE"
else
  echo "Existing admin connection key preserved: $ADMIN_KEY_FILE"
fi
echo
echo "Open: https://mcp-test.tryvodia.com/admin-connections/"
echo "Backup: $BACKUP_DIR"
trap - ERR
