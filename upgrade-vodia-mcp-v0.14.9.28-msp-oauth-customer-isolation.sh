#!/usr/bin/env bash
# Vodia MCP v0.14.9.28 — OAuth MSP/customer isolation foundation
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
GATEWAY_SERVICE="vodia-public-mcp-gateway"
ENV_FILE="/etc/vodia-mcp.env"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
AUTHZ="$APP/msp-authz-v1.js"
CONNECTIONS="$APP/msp-customer-connections-v1.js"
AWS_MODULE="$APP/aws-marketplace-ec2-deploy-v1.js"
GATEWAY="$APP/public-mcp-auth-gateway-v1.js"
FROM_VER="0.14.9.27"
TO_VER="0.14.9.28"
SOURCE_COMMIT="1b05d345ac05907659141d4a9835f4e1cac686c7"
SOURCE_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-msp-auth-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_INDEX="$TMP_DIR/index.js"
TMP_VERSION="$TMP_DIR/version.js"
TMP_AUTHZ="$TMP_DIR/msp-authz-v1.js"
TMP_CONNECTIONS="$TMP_DIR/msp-customer-connections-v1.js"
TMP_AWS="$TMP_DIR/aws-marketplace-ec2-deploy-v1.js"
TMP_GATEWAY="$TMP_DIR/public-mcp-auth-gateway-v1.js"
TMP_ENV="$TMP_DIR/vodia-mcp.env"
TMP_CADDY="$TMP_DIR/caddy"
HEALTH="$TMP_DIR/health.json"
INSTALLED=0
CADDY_FILE="${VODIA_MCP_CADDY_FILE:-}"

trap 'rm -rf "$TMP_DIR"' EXIT

rollback(){
  local rc="${1:-1}"
  trap - ERR
  INSTALLED=0
  echo "Activation failed; restoring pre-v${TO_VER} state from $BACKUP_DIR ..." >&2
  for f in index.js version.js msp-authz-v1.js msp-customer-connections-v1.js aws-marketplace-ec2-deploy-v1.js public-mcp-auth-gateway-v1.js; do
    if [[ -f "$BACKUP_DIR/$f" ]]; then
      cp -a "$BACKUP_DIR/$f" "$APP/$f"
    else
      rm -f "$APP/$f"
    fi
  done
  cp -a "$BACKUP_DIR/vodia-mcp.env" "$ENV_FILE" || true
  if [[ -n "$CADDY_FILE" && -f "$BACKUP_DIR/caddy.conf" ]]; then cp -a "$BACKUP_DIR/caddy.conf" "$CADDY_FILE" || true; fi
  if [[ -f "$BACKUP_DIR/vodia-public-mcp-gateway.service" ]]; then
    cp -a "$BACKUP_DIR/vodia-public-mcp-gateway.service" "/etc/systemd/system/${GATEWAY_SERVICE}.service"
  else
    rm -f "/etc/systemd/system/${GATEWAY_SERVICE}.service"
  fi
  systemctl daemon-reload || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  systemctl restart "$GATEWAY_SERVICE" 2>/dev/null || true
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  echo "ROLLED BACK. Backup kept at: $BACKUP_DIR" >&2
  exit "$rc"
}

fail(){
  echo "FAIL: $*" >&2
  if (( INSTALLED )); then rollback 1; fi
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node curl grep install systemctl caddy; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$INDEX" "$VERSION" "$ENV_FILE" "$AWS_MODULE"; do [[ -f "$f" ]] || fail "missing $f"; done
grep -Eq "CONNECTOR_VERSION[[:space:]]*=[[:space:]]*[\"']${FROM_VER//./\\.}[\"']" "$VERSION" || fail "expected installed base v${FROM_VER}"

echo "=== Vodia MCP v${TO_VER} — OAuth MSP/customer isolation ==="

echo "[1/10] Resolve Caddy public MCP config — NO LIVE CHANGES"
if [[ -z "$CADDY_FILE" ]]; then
  mapfile -t CANDIDATES < <(grep -rl --include='*.caddy' --include='Caddyfile' 'reverse_proxy 127.0.0.1:3100' /etc/caddy 2>/dev/null || true)
  [[ ${#CANDIDATES[@]} -eq 1 ]] || fail "expected exactly one Caddy file proxying 127.0.0.1:3100; found ${#CANDIDATES[@]}. Set VODIA_MCP_CADDY_FILE explicitly."
  CADDY_FILE="${CANDIDATES[0]}"
fi
[[ -f "$CADDY_FILE" ]] || fail "Caddy file not found: $CADDY_FILE"
grep -q 'reverse_proxy 127.0.0.1:3100' "$CADDY_FILE" || fail "Caddy file does not proxy MCP core"
echo "PASS: $CADDY_FILE"

echo "[2/10] Download and validate staged modules — NO LIVE CHANGES"
curl -fsSL "$SOURCE_BASE/msp-authz-v1.js" -o "$TMP_AUTHZ"
curl -fsSL "$SOURCE_BASE/msp-customer-connections-v1.js" -o "$TMP_CONNECTIONS"
curl -fsSL "$SOURCE_BASE/aws-marketplace-ec2-deploy-v1.js" -o "$TMP_AWS"
curl -fsSL "$SOURCE_BASE/public-mcp-auth-gateway-v1.js" -o "$TMP_GATEWAY"
for f in "$TMP_AUTHZ" "$TMP_CONNECTIONS" "$TMP_AWS" "$TMP_GATEWAY"; do node --check "$f" >/dev/null || fail "syntax check failed: $f"; done
grep -q 'msp_get_my_identity' "$TMP_AUTHZ" || fail "MSP auth module missing identity tool"
grep -q 'msp_save_customer_aws_connection' "$TMP_CONNECTIONS" || fail "customer connection module missing AWS save tool"
grep -q 'CUSTOMER_CONTEXT_REQUIRED' "$TMP_AWS" || fail "AWS module missing customer-context enforcement"
grep -q 'legacy_static_token_not_allowed' "$TMP_GATEWAY" || fail "public gateway missing legacy token rejection"
echo PASS

echo "[3/10] Stage index/version/env/Caddy — NO LIVE CHANGES"
cp -a "$INDEX" "$TMP_INDEX"
cp -a "$VERSION" "$TMP_VERSION"
cp -a "$ENV_FILE" "$TMP_ENV"
cp -a "$CADDY_FILE" "$TMP_CADDY"

python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker="v0.14.9.28 MSP OAuth customer isolation"
if marker in s:
    raise SystemExit("already patched")
imports=[
'import { registerMspAuthzTools } from "./msp-authz-v1.js";\n',
'import { registerMspCustomerConnectionTools } from "./msp-customer-connections-v1.js";\n',
]
lines=s.splitlines(True)
at=0
for i,line in enumerate(lines):
    if line.startswith("import "): at=i+1
if not at: raise SystemExit("no ESM import block")
for line in reversed(imports): lines.insert(at,line)
s=''.join(lines)
factory=s.find("export function createVodiaServer")
if factory<0: raise SystemExit("createVodiaServer missing")
reg=s.find("server.registerTool(",factory)
if reg<0: raise SystemExit("tool registration anchor missing")
block='''  // v0.14.9.28 MSP OAuth customer isolation
  registerMspAuthzTools(server, {
    z, toolOutputSchema, scopedAudit, scopedSuccess, failure,
  });
  registerMspCustomerConnectionTools(server, {
    z, toolOutputSchema, scopedAudit, scopedSuccess, failure,
  });

'''
s=s[:reg]+block+s[reg:]
p.write_text(s)
PY

python3 - "$TMP_VERSION" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p,to=Path(sys.argv[1]),sys.argv[2]
s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>'+to+r'\2',s,count=1)
if n==s: raise SystemExit("CONNECTOR_VERSION missing")
p.write_text(n)
PY

python3 - "$TMP_ENV" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
updates={
 "VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT":"true",
 "VODIA_MSP_AUTHZ_DB":"/var/lib/vodia-mcp/msp-authz.db",
 "VODIA_MSP_CUSTOMER_CONNECTION_STORE":"/var/lib/vodia-mcp/msp-customer-connections.enc",
 "VODIA_MSP_CUSTOMER_CONNECTION_KEY_FILE":"/var/lib/vodia-mcp/msp-customer-connections.key",
}
for k,v in updates.items():
    pat=rf'^{re.escape(k)}=.*$'
    line=f'{k}="{v}"'
    if re.search(pat,s,re.M): s=re.sub(pat,line,s,flags=re.M)
    else: s += ("\n" if s and not s.endswith("\n") else "") + line + "\n"
p.write_text(s)
PY

python3 - "$TMP_CADDY" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if "vodiaPublicMcpOAuth" in s:
    raise SystemExit("Caddy already contains v0.14.9.28 matcher")
old="reverse_proxy 127.0.0.1:3100"
if old not in s: raise SystemExit("core reverse_proxy anchor missing")
new="""@vodiaPublicMcpOAuth path /mcp /mcp/*
    reverse_proxy @vodiaPublicMcpOAuth 127.0.0.1:3113
    reverse_proxy 127.0.0.1:3100"""
s=s.replace(old,new,1)
p.write_text(s)
PY

node --check "$TMP_INDEX" >/dev/null || fail "patched index syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version syntax invalid"
caddy validate --adapter caddyfile --config "$TMP_CADDY" || fail "staged Caddy config invalid"
echo PASS

echo "[4/10] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$ENV_FILE" "$BACKUP_DIR/vodia-mcp.env"
cp -a "$CADDY_FILE" "$BACKUP_DIR/caddy.conf"
cp -a "$AWS_MODULE" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
[[ -f "$AUTHZ" ]] && cp -a "$AUTHZ" "$BACKUP_DIR/msp-authz-v1.js" || true
[[ -f "$CONNECTIONS" ]] && cp -a "$CONNECTIONS" "$BACKUP_DIR/msp-customer-connections-v1.js" || true
[[ -f "$GATEWAY" ]] && cp -a "$GATEWAY" "$BACKUP_DIR/public-mcp-auth-gateway-v1.js" || true
[[ -f "/etc/systemd/system/${GATEWAY_SERVICE}.service" ]] && cp -a "/etc/systemd/system/${GATEWAY_SERVICE}.service" "$BACKUP_DIR/vodia-public-mcp-gateway.service" || true
echo "PASS: $BACKUP_DIR"

echo "[5/10] Install application modules"
INSTALLED=1
trap 'rollback $?' ERR
install -o root -g root -m 0644 "$TMP_AUTHZ" "$AUTHZ"
install -o root -g root -m 0644 "$TMP_CONNECTIONS" "$CONNECTIONS"
install -o root -g root -m 0644 "$TMP_AWS" "$AWS_MODULE"
install -o root -g root -m 0644 "$TMP_GATEWAY" "$GATEWAY"
install -o root -g root -m 0644 "$TMP_INDEX" "$INDEX"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
install -o root -g root -m 0600 "$TMP_ENV" "$ENV_FILE"
echo PASS

echo "[6/10] Install public MCP OAuth gateway"
cat > "/etc/systemd/system/${GATEWAY_SERVICE}.service" <<'EOF'
[Unit]
Description=Vodia public MCP OAuth gateway
After=network-online.target vodia-mcp.service
Wants=network-online.target
Requires=vodia-mcp.service

[Service]
Type=simple
User=vodiamcp
Group=vodiamcp
WorkingDirectory=/opt/vodia-mcp
EnvironmentFile=/etc/vodia-mcp.env
ExecStart=/usr/bin/node /opt/vodia-mcp/public-mcp-auth-gateway-v1.js
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemd-analyze verify "/etc/systemd/system/${GATEWAY_SERVICE}.service" >/dev/null 2>&1 || fail "gateway systemd unit invalid"
systemctl daemon-reload
systemctl enable "$GATEWAY_SERVICE" >/dev/null
echo PASS

echo "[7/10] Activate services before public route"
systemctl restart "$SERVICE"
systemctl restart "$GATEWAY_SERVICE"
for _ in {1..30}; do
  if curl -fsS -o "$HEALTH" http://127.0.0.1:3100/health 2>/dev/null && [[ -s "$HEALTH" ]]; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed"
grep -Eq "(^|[^0-9.])${TO_VER//./\\.}([^0-9.]|$)" "$HEALTH" || fail "health did not report v${TO_VER}"
systemctl is-active --quiet "$GATEWAY_SERVICE" || fail "public MCP gateway inactive"
echo PASS

echo "[8/10] Verify public gateway blocks legacy token"
LEGACY_TOKEN="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("MCP_BEARER_TOKEN="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"": v=v[1:-1]
        print(v,end="")
        break
PY
)"
[[ -n "$LEGACY_TOKEN" ]] || fail "MCP_BEARER_TOKEN not found for gateway verification"
RESP="$(curl -sS -H "Authorization: Bearer $LEGACY_TOKEN" http://127.0.0.1:3113/mcp || true)"
grep -q 'legacy_static_token_not_allowed' <<<"$RESP" || fail "gateway did not reject legacy static token"
unset LEGACY_TOKEN RESP
echo "PASS: legacy static token rejected on public-gateway path"

echo "[9/10] Activate Caddy public /mcp route"
install -o root -g root -m 0644 "$TMP_CADDY" "$CADDY_FILE"
caddy validate --config /etc/caddy/Caddyfile || fail "live Caddy validation failed"
systemctl reload caddy
echo PASS

echo "[10/10] Complete"
trap - ERR
INSTALLED=0
cat "$HEALTH"; echo
echo "PASS: v${TO_VER} installed"
echo "PASS: public /mcp blocks the legacy server-wide bearer token"
echo "PASS: core 127.0.0.1:3100 remains available to local trusted sidecars"
echo "PASS: AWS customer context is OAuth + customer scoped"
echo
echo "Next external OAuth test:"
echo "  1. Connect to the Vodia MCP normally through the MCP client OAuth flow."
echo "  2. Call msp_get_my_identity."
echo "  3. The first stable OAuth identity may create the first MSP organization."
echo "  4. Create a customer and save that customer's AWS connection."
echo "Backup: $BACKUP_DIR"
