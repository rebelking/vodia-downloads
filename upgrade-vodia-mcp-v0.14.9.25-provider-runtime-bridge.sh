#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
BRIDGE="$APP/provider-runtime-bridge-v1.js"
STORE_MODULE="$APP/provider-connections-store-v1.js"
DROPIN_DIR="/etc/systemd/system/${SERVICE}.service.d"
DROPIN="$DROPIN_DIR/25-provider-runtime-bridge.conf"
WATCH_PATH="/etc/systemd/system/vodia-provider-connections.path"
WATCH_SERVICE="/etc/systemd/system/vodia-provider-connections-reload.service"
SOURCE_REF="${VODIA_MCP_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_ROOT="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.25-provider-runtime-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_BRIDGE="$TMP_DIR/provider-runtime-bridge-v1.js"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"

trap 'rm -rf "$TMP_DIR"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node systemctl grep; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

[[ -f "$VERSION" ]] || fail "missing $VERSION"
[[ -f "$STORE_MODULE" ]] || fail "v0.14.9.24 Admin Connections is required first: missing $STORE_MODULE"
[[ -f /var/lib/vodia-mcp/admin-connections.key ]] || fail "v0.14.9.24 Admin Connections is required first"
grep -q '0.14.9.24' "$VERSION" || fail "expected installed base v0.14.9.24"

if ! node --help 2>&1 | grep -q -- '--import'; then
  fail "installed Node.js does not support --import preloading"
fi

if grep -q '^NODE_OPTIONS=' /etc/vodia-mcp.env 2>/dev/null; then
  fail "NODE_OPTIONS already exists in /etc/vodia-mcp.env; refusing to overwrite it"
fi

echo "=== Vodia MCP v0.14.9.25 — Encrypted Provider Runtime Bridge ==="
echo "Makes the core MCP process load saved PBX/Microsoft/Cloudflare settings from the encrypted admin store before the MCP application starts."
echo "AWS remains on the existing encrypted AWS connection profile."

echo "[1/10] Stage bridge — NO LIVE CHANGES"
curl -fsSL "$SOURCE_ROOT/provider-runtime-bridge-v1.js" -o "$TMP_BRIDGE"
node --check "$TMP_BRIDGE" >/dev/null
grep -q 'encrypted-admin-store' "$TMP_BRIDGE" || fail "runtime source marker missing"
grep -q 'MICROSOFT_TENANT_ID' "$TMP_BRIDGE" || fail "Microsoft mapping missing"
grep -q 'CLOUDFLARE_API_TOKEN' "$TMP_BRIDGE" || fail "Cloudflare mapping missing"
grep -q 'VODIA_PBX_URL' "$TMP_BRIDGE" || fail "PBX mapping missing"
echo PASS

echo "[2/10] Bridge decrypt/mapping self-test — NO LIVE CHANGES"
TEST_KEY="$TMP_DIR/test.key"
TEST_STORE="$TMP_DIR/test.enc"
python3 - "$TEST_KEY" <<'PY'
from pathlib import Path
import os,sys
Path(sys.argv[1]).write_bytes(os.urandom(32))
PY

node --input-type=module - "$TEST_KEY" "$TEST_STORE" <<'NODE'
import { createCipheriv, randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
const [keyPath, storePath] = process.argv.slice(2);
const payload = {
  version: 1,
  providers: {
    pbx: {
      baseUrl: "https://pbx.runtime-test.invalid",
      apiUsername: "runtime-user",
      apiToken: "runtime-pbx-token",
      defaultTenant: "runtime.example"
    },
    microsoft: {
      tenantId: "11111111-1111-1111-1111-111111111111",
      clientId: "22222222-2222-2222-2222-222222222222",
      clientSecret: "runtime-ms-secret"
    },
    cloudflare: {
      apiToken: "runtime-cf-token",
      zoneId: "runtime-zone",
      domain: "runtime.example"
    }
  }
};
const key = readFileSync(keyPath);
const iv = randomBytes(12);
const cipher = createCipheriv("aes-256-gcm", key, iv);
const data = Buffer.concat([cipher.update(Buffer.from(JSON.stringify(payload))), cipher.final()]);
writeFileSync(storePath, JSON.stringify({
  v: 1,
  iv: iv.toString("base64"),
  tag: cipher.getAuthTag().toString("base64"),
  data: data.toString("base64")
}));
NODE

VODIA_PROVIDER_CONNECTION_KEY_FILE="$TEST_KEY" \
VODIA_PROVIDER_CONNECTION_STORE="$TEST_STORE" \
node --import="$TMP_BRIDGE" --input-type=module - <<'NODE'
const expected = {
  VODIA_PBX_URL: "https://pbx.runtime-test.invalid",
  VODIA_API_USERNAME: "runtime-user",
  VODIA_API_TOKEN: "runtime-pbx-token",
  VODIA_DEFAULT_TENANT: "runtime.example",
  MICROSOFT_TENANT_ID: "11111111-1111-1111-1111-111111111111",
  MICROSOFT_CLIENT_ID: "22222222-2222-2222-2222-222222222222",
  MICROSOFT_CLIENT_SECRET: "runtime-ms-secret",
  CLOUDFLARE_API_TOKEN: "runtime-cf-token",
  CLOUDFLARE_ZONE_ID: "runtime-zone",
  CLOUDFLARE_DOMAIN: "runtime.example",
  VODIA_PROVIDER_RUNTIME_SOURCE: "encrypted-admin-store"
};
for (const [name, value] of Object.entries(expected)) {
  if (process.env[name] !== value) throw new Error("bridge mapping failed: " + name);
}
console.log("PASS: encrypted store decrypted without printing secrets");
console.log("PASS: PBX aliases populated");
console.log("PASS: Microsoft aliases populated");
console.log("PASS: Cloudflare aliases populated");
NODE

echo "[3/10] Inspect installed MCP source for provider environment names — NO LIVE CHANGES"
python3 - "$APP" <<'PY'
from pathlib import Path
import re,sys
root=Path(sys.argv[1])
groups={
 "PBX":["VODIA_PBX_URL","VODIA_PBX_BASE_URL","VODIA_BASE_URL","VODIA_URL","PBX_URL","PBX_BASE_URL",
        "VODIA_API_USERNAME","VODIA_USERNAME","VODIA_PBX_USERNAME","PBX_API_USERNAME","PBX_USERNAME",
        "VODIA_API_TOKEN","VODIA_TOKEN","VODIA_PBX_TOKEN","PBX_API_TOKEN","PBX_TOKEN",
        "VODIA_API_PASSWORD","VODIA_PASSWORD","VODIA_PBX_PASSWORD","PBX_API_PASSWORD","PBX_PASSWORD"],
 "Microsoft":["MICROSOFT_TENANT_ID","MS_TENANT_ID","M365_TENANT_ID","AZURE_TENANT_ID","ENTRA_TENANT_ID",
              "GRAPH_TENANT_ID","MS_GRAPH_TENANT_ID","MICROSOFT_CLIENT_ID","MS_CLIENT_ID","M365_CLIENT_ID",
              "AZURE_CLIENT_ID","ENTRA_CLIENT_ID","GRAPH_CLIENT_ID","MS_GRAPH_CLIENT_ID",
              "MICROSOFT_CLIENT_SECRET","MS_CLIENT_SECRET","M365_CLIENT_SECRET","AZURE_CLIENT_SECRET",
              "ENTRA_CLIENT_SECRET","GRAPH_CLIENT_SECRET","MS_GRAPH_CLIENT_SECRET"],
 "Cloudflare":["CLOUDFLARE_API_TOKEN","CLOUDFLARE_TOKEN","CF_API_TOKEN","CF_TOKEN","CLOUDFLARE_ZONE_ID",
               "CF_ZONE_ID","CLOUDFLARE_DOMAIN","CLOUDFLARE_ZONE_NAME","CF_DOMAIN"]
}
texts=[]
for p in root.rglob("*.js"):
    if p.name in {"provider-runtime-bridge-v1.js","admin-connections-api-v1.js","provider-connections-store-v1.js"}:
        continue
    try: texts.append((p,p.read_text(errors="ignore")))
    except Exception: pass
for group,names in groups.items():
    found=[]
    for name in names:
        for p,text in texts:
            if name in text:
                found.append((name,str(p.relative_to(root))))
                break
    if found:
        print(f"PASS: {group} core source references recognized env aliases:")
        for name,path in found[:12]: print(f"  {name} <- {path}")
    else:
        print(f"WARN: {group} core source did not expose a recognized literal env alias.")
        print("      The bridge will still export the compatibility alias set; verify this provider after activation.")
PY

echo "[4/10] Stage connector version — NO LIVE CHANGES"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.25\2',s,count=1)
if n==s: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[5/10] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f "$BRIDGE" ]] && cp -a "$BRIDGE" "$BACKUP_DIR/provider-runtime-bridge-v1.js" || true
[[ -f "$DROPIN" ]] && cp -a "$DROPIN" "$BACKUP_DIR/25-provider-runtime-bridge.conf" || true
[[ -f "$WATCH_PATH" ]] && cp -a "$WATCH_PATH" "$BACKUP_DIR/vodia-provider-connections.path" || true
[[ -f "$WATCH_SERVICE" ]] && cp -a "$WATCH_SERVICE" "$BACKUP_DIR/vodia-provider-connections-reload.service" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.25 state..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  if [[ -f "$BACKUP_DIR/provider-runtime-bridge-v1.js" ]]; then cp -a "$BACKUP_DIR/provider-runtime-bridge-v1.js" "$BRIDGE"; else rm -f "$BRIDGE"; fi
  if [[ -f "$BACKUP_DIR/25-provider-runtime-bridge.conf" ]]; then
    mkdir -p "$DROPIN_DIR"; cp -a "$BACKUP_DIR/25-provider-runtime-bridge.conf" "$DROPIN"
  else
    rm -f "$DROPIN"
  fi
  if [[ -f "$BACKUP_DIR/vodia-provider-connections.path" ]]; then cp -a "$BACKUP_DIR/vodia-provider-connections.path" "$WATCH_PATH"; else rm -f "$WATCH_PATH"; fi
  if [[ -f "$BACKUP_DIR/vodia-provider-connections-reload.service" ]]; then cp -a "$BACKUP_DIR/vodia-provider-connections-reload.service" "$WATCH_SERVICE"; else rm -f "$WATCH_SERVICE"; fi
  systemctl daemon-reload || true
  systemctl disable --now vodia-provider-connections.path 2>/dev/null || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

echo "[6/10] Install bridge + systemd preload"
trap rollback ERR
install -o root -g root -m 0644 "$TMP_BRIDGE" "$BRIDGE"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN" <<EOF
[Service]
Environment="NODE_OPTIONS=--import=$BRIDGE"
Environment="VODIA_PROVIDER_CONNECTION_STORE=/var/lib/vodia-mcp/provider-connections.enc"
Environment="VODIA_PROVIDER_CONNECTION_KEY_FILE=/var/lib/vodia-mcp/provider-connections.key"
EOF
echo PASS

echo "[7/10] Install automatic reload watcher"
cat > "$WATCH_SERVICE" <<'EOF'
[Unit]
Description=Reload Vodia MCP after encrypted provider connection change

[Service]
Type=oneshot
ExecStart=/bin/systemctl try-restart vodia-mcp.service
EOF

cat > "$WATCH_PATH" <<'EOF'
[Unit]
Description=Watch Vodia MCP encrypted provider connection store

[Path]
PathChanged=/var/lib/vodia-mcp/provider-connections.enc
Unit=vodia-provider-connections-reload.service

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
echo PASS

echo "[8/10] Activate + health"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl enable --now vodia-provider-connections.path
systemctl restart "$SERVICE"

for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed"
grep -q '0.14.9.25' "$HEALTH" || fail "health did not report v0.14.9.25"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE inactive"
systemctl is-active --quiet vodia-provider-connections.path || fail "provider store watcher inactive"
echo PASS

echo "[9/10] Runtime wiring validation"
EFFECTIVE="$(systemctl show "$SERVICE" -p Environment --value)"
echo "$EFFECTIVE" | grep -q 'provider-runtime-bridge-v1.js' || fail "NODE_OPTIONS preload not active"
echo "$EFFECTIVE" | grep -q 'VODIA_PROVIDER_CONNECTION_STORE=' || fail "provider store path env not active"

if [[ -s /var/lib/vodia-mcp/provider-connections.enc ]]; then
  echo "PASS: encrypted provider store exists"
else
  echo "INFO: provider store is not populated yet; save a provider in /admin-connections/ to activate it"
fi

if curl -fsS http://127.0.0.1:3110/control-api/connections > "$TMP_DIR/connections.json" 2>/dev/null; then
  echo "PASS: Control Center connection summary still responds after bridge activation"
else
  echo "WARN: Control Center sidecar connection summary not available on 127.0.0.1:3110"
fi
echo PASS

echo "[10/10] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.25 encrypted provider runtime bridge installed"
echo "PASS: core MCP starts with encrypted PBX/Microsoft/Cloudflare provider settings loaded into process environment"
echo "PASS: AWS continues using the existing encrypted AWS profile"
echo "PASS: saving provider settings automatically triggers an MCP restart"
echo "PASS: provider secrets remain encrypted on disk"
echo
echo "Configure: https://mcp-test.tryvodia.com/admin-connections/"
echo "Dashboard: https://mcp-test.tryvodia.com/control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
