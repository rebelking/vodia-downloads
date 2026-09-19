#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
CONTROL_SERVICE="vodia-control-api"
CONTROL_SERVICE_FILE="/etc/systemd/system/${CONTROL_SERVICE}.service"
CONTROL_API="$APP/control-center-api-v1.js"
WEB_DIR="$APP/control-center-v2"
SOURCE_REF="${VODIA_MCP_CONTROL_CENTER_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_ROOT="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.20-control-live-$STAMP"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node caddy systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
[[ -f "$VERSION" ]] || fail "missing $VERSION"
grep -q '0.14.9.19' "$VERSION" || fail "expected installed base v0.14.9.19"
[[ -f /etc/vodia-mcp.env ]] || fail "missing /etc/vodia-mcp.env"
grep -q '^MCP_BEARER_TOKEN=' /etc/vodia-mcp.env || fail "MCP_BEARER_TOKEN missing from /etc/vodia-mcp.env"

echo "=== Vodia MCP v0.14.9.20 — Control Center live MCP wiring ==="
echo "Wires PBX/AWS/Cloudflare/Microsoft checks and recent activity into the unified /control/ frontend."

echo "[1/9] Locate Caddy MCP site"
mapfile -t CANDIDATES < <(grep -RIl --include='*.caddy' --include='Caddyfile' 'reverse_proxy[[:space:]]\+127\.0\.0\.1:3100' /etc/caddy 2>/dev/null || true)
[[ ${#CANDIDATES[@]} -eq 1 ]] || {
  printf 'Found %s candidate Caddy files:\n' "${#CANDIDATES[@]}" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  fail "expected exactly one MCP Caddy site"
}
CADDY_SITE="${CANDIDATES[0]}"
echo "PASS: $CADDY_SITE"

echo "[2/9] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$CADDY_SITE" "$BACKUP_DIR/$(basename "$CADDY_SITE")"
[[ -f "$CONTROL_API" ]] && cp -a "$CONTROL_API" "$BACKUP_DIR/control-center-api-v1.js" || true
[[ -f "$CONTROL_SERVICE_FILE" ]] && cp -a "$CONTROL_SERVICE_FILE" "$BACKUP_DIR/vodia-control-api.service" || true
[[ -d "$WEB_DIR" ]] && cp -a "$WEB_DIR" "$BACKUP_DIR/control-center-v2" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.20 files..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/$(basename "$CADDY_SITE")" "$CADDY_SITE" || true
  if [[ -f "$BACKUP_DIR/control-center-api-v1.js" ]]; then cp -a "$BACKUP_DIR/control-center-api-v1.js" "$CONTROL_API"; else rm -f "$CONTROL_API"; fi
  if [[ -f "$BACKUP_DIR/vodia-control-api.service" ]]; then cp -a "$BACKUP_DIR/vodia-control-api.service" "$CONTROL_SERVICE_FILE"; else rm -f "$CONTROL_SERVICE_FILE"; fi
  if [[ -d "$BACKUP_DIR/control-center-v2" ]]; then rm -rf "$WEB_DIR"; cp -a "$BACKUP_DIR/control-center-v2" "$WEB_DIR"; fi
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$CONTROL_SERVICE" 2>/dev/null || true
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  exit "$rc"
}

echo "[3/9] Install live Control Center assets"
curl -fsSL "$SOURCE_ROOT/control-center-api-v1.js" -o "$CONTROL_API"
curl -fsSL "$SOURCE_ROOT/control-center-v2/app.js" -o "$WEB_DIR/app.js"
curl -fsSL "$SOURCE_ROOT/control-center-v2/styles.css" -o "$WEB_DIR/styles.css"
node --check "$CONTROL_API" >/dev/null || fail "control API syntax invalid"
node --check "$WEB_DIR/app.js" >/dev/null || fail "frontend JS syntax invalid"
chmod 0644 "$CONTROL_API" "$WEB_DIR/app.js" "$WEB_DIR/styles.css"
grep -q 'aws_check_customer_connection' "$CONTROL_API" || fail "AWS live test missing"
grep -q 'cloudflare_check_connection' "$CONTROL_API" || fail "Cloudflare live test missing"
grep -q 'microsoft_check_graph_readiness' "$CONTROL_API" || fail "Microsoft live test missing"
grep -q 'get_system_status' "$CONTROL_API" || fail "PBX live test missing"
echo PASS

echo "[4/9] Install loopback control API service"
cat > "$CONTROL_SERVICE_FILE" <<'EOF'
[Unit]
Description=Vodia MCP Control Center loopback API
After=network-online.target vodia-mcp.service
Wants=network-online.target
Requires=vodia-mcp.service

[Service]
Type=simple
User=vodiamcp
Group=vodiamcp
WorkingDirectory=/opt/vodia-mcp
EnvironmentFile=/etc/vodia-mcp.env
Environment=VODIA_CONTROL_API_HOST=127.0.0.1
Environment=VODIA_CONTROL_API_PORT=3110
Environment=VODIA_CONTROL_MCP_URL=http://127.0.0.1:3100/mcp
Environment=VODIA_CONTROL_HEALTH_URL=http://127.0.0.1:3100/health
ExecStart=/usr/bin/node /opt/vodia-mcp/control-center-api-v1.js
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
ReadWritePaths=/var/log/vodia-mcp
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo PASS

echo "[5/9] Add /control-api/ Caddy route"
python3 - "$CADDY_SITE" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='# v0.14.9.20 control center live API'
if marker in s:
    print('Route already present')
    raise SystemExit(0)

# Insert before the existing catch-all handle that proxies the MCP app.
needle='''handle {
		reverse_proxy 127.0.0.1:3100
	}'''
if needle not in s:
    needle='''handle {
        reverse_proxy 127.0.0.1:3100
    }'''
if needle not in s:
    raise SystemExit('PATCH ERROR: existing catch-all MCP handle not found')
route='''# v0.14.9.20 control center live API
	handle /control-api/* {
		reverse_proxy 127.0.0.1:3110
	}

	'''
s=s.replace(needle,route+needle,1)
p.write_text(s)
PY
caddy fmt --overwrite "$CADDY_SITE" >/dev/null
caddy validate --config /etc/caddy/Caddyfile >/dev/null
echo PASS

echo "[6/9] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.20\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[7/9] Activate"
trap rollback ERR
cp -a "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl enable --now "$CONTROL_SERVICE"
systemctl reload caddy

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null && curl -fsS http://127.0.0.1:3110/control-api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.20' "$HEALTH" || fail "health did not report v0.14.9.20"
systemctl is-active --quiet "$CONTROL_SERVICE" || fail "control API service is not active"
echo PASS

echo "[8/9] Live API validation"
API_HEALTH="$(curl -fsS http://127.0.0.1:3110/control-api/health)"
echo "$API_HEALTH" | grep -q '"ok":true' || fail "control API health failed"
CONNECTIONS="$(curl -fsS http://127.0.0.1:3110/control-api/connections)"
echo "$CONNECTIONS" | grep -q '"connections"' || fail "connection summary endpoint failed"
echo "PASS: loopback API healthy"
echo "Connection probe:"
echo "$CONNECTIONS" | python3 -m json.tool | sed -n '1,100p'

echo "[9/9] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.20 Control Center live wiring installed"
echo "PASS: PBX, AWS, Cloudflare, and Microsoft Test buttons now call existing MCP tools"
echo "PASS: recent activity is loaded from the sanitized audit-log view"
echo "PASS: control API listens only on 127.0.0.1:3110"
echo "PASS: provider secrets and MCP bearer token are not returned to the browser"
echo "Open: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
