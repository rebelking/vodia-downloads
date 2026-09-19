#!/usr/bin/env bash
# Stable entry point for the Vodia MCP MSP/OAuth customer-isolation phase.
# Installs v0.14.9.28 from v0.14.9.27, or verifies an existing v0.14.9.28 installation.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION_FILE="$APP/version.js"
TARGET="0.14.9.28"
INSTALLER_COMMIT="7ce2b121e2749a1a9a34851a8b5ee72c63d11a2d"
INSTALLER_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${INSTALLER_COMMIT}/upgrade-vodia-mcp-v0.14.9.28-msp-oauth-customer-isolation.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ -f "$VERSION_FILE" ]] || fail "missing $VERSION_FILE"
for c in node curl systemctl grep; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

CURRENT="$(python3 - "$VERSION_FILE" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "")
PY
)"

echo "Vodia MCP current version: ${CURRENT:-unknown}"

if [[ "$CURRENT" == "$TARGET" ]]; then
  echo "Target v$TARGET is already installed. Running verification only."
  curl -fsS http://127.0.0.1:3100/health | tee /tmp/vodia-msp-health.json
  grep -q '"version":"0.14.9.28"' /tmp/vodia-msp-health.json || fail "health endpoint does not report v0.14.9.28"
  systemctl is-active --quiet vodia-public-mcp-gateway || fail "vodia-public-mcp-gateway is not active"
  curl -fsS http://127.0.0.1:3113/health >/dev/null 2>&1 || true
  grep -q '^VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT="true"' /etc/vodia-mcp.env || fail "customer context enforcement is not enabled"
  grep -q '127.0.0.1:3113' /etc/caddy/conf.d/vodia-mcp.caddy || fail "Caddy public MCP route is not pointed at the OAuth gateway"
  caddy validate --config /etc/caddy/Caddyfile >/dev/null || fail "live Caddy config invalid"
  echo "PASS: v0.14.9.28 MSP/OAuth customer isolation is active."
  exit 0
fi

[[ "$CURRENT" == "0.14.9.27" ]] || fail "supported upgrade path is v0.14.9.27 -> v0.14.9.28; found ${CURRENT:-unknown}"

echo "Downloading immutable v0.14.9.28 installer..."
curl -fsSL "$INSTALLER_URL" -o "$TMP"
bash -n "$TMP" || fail "installer syntax invalid"

echo "Installing v$TARGET..."
bash "$TMP"

echo "Post-install verification..."
curl -fsS http://127.0.0.1:3100/health | tee /tmp/vodia-msp-health.json
grep -q '"version":"0.14.9.28"' /tmp/vodia-msp-health.json || fail "health endpoint does not report v0.14.9.28"
systemctl is-active --quiet vodia-public-mcp-gateway || fail "public MCP OAuth gateway is not active"
grep -q '^VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT="true"' /etc/vodia-mcp.env || fail "customer context enforcement is not enabled"
grep -q '127.0.0.1:3113' /etc/caddy/conf.d/vodia-mcp.caddy || fail "Caddy public MCP route is not pointed at OAuth gateway"

echo "PASS: Vodia MCP MSP/OAuth customer isolation installed and verified."
echo "Next: connect through public MCP OAuth and call msp_get_my_identity."
