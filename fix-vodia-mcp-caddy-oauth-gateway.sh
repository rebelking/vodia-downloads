#!/usr/bin/env bash
# Repair/verify the Vodia MCP public OAuth gateway Caddy route.
# Safe for an already-running v0.14.9.28 installation.
set -Eeuo pipefail

CADDY_MAIN="${VODIA_MCP_CADDY_MAIN:-/etc/caddy/Caddyfile}"
SNIPPET="${VODIA_MCP_CADDY_FILE:-/etc/caddy/conf.d/vodia-mcp.caddy}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
CORE_URL="http://127.0.0.1:3100"
GATEWAY_URL="http://127.0.0.1:3113"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${SNIPPET}.before-oauth-gateway-fix-${STAMP}"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in caddy curl grep python3 systemctl cp; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
[[ -f "$CADDY_MAIN" ]] || fail "missing $CADDY_MAIN"
[[ -f "$SNIPPET" ]] || fail "missing $SNIPPET"

echo "[1/7] Validate current Caddyfile and snippet"
caddy validate --config "$CADDY_MAIN" || fail "main Caddyfile is invalid before changes"
caddy validate --adapter caddyfile --config "$SNIPPET" || fail "Vodia Caddy snippet is invalid before changes"
echo PASS

echo "[2/7] Verify MCP services"
curl -fsS "$CORE_URL/health" >/tmp/vodia-caddy-fix-health.json || fail "MCP core health failed"
systemctl is-active --quiet vodia-public-mcp-gateway || fail "vodia-public-mcp-gateway is not active"
echo PASS

echo "[3/7] Backup current snippet"
cp -a "$SNIPPET" "$BACKUP"
echo "PASS: $BACKUP"

echo "[4/7] Ensure public /mcp routes through OAuth gateway"
python3 - "$SNIPPET" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
matcher='@vodiaPublicMcpOAuth path /mcp /mcp/*'
gateway='reverse_proxy @vodiaPublicMcpOAuth 127.0.0.1:3113'
core='reverse_proxy 127.0.0.1:3100'

if matcher in s and gateway in s:
    print("PASS: OAuth gateway route already present")
    raise SystemExit(0)

if core not in s:
    raise SystemExit("PATCH ERROR: core reverse_proxy anchor not found")

new=f'''{matcher}
		reverse_proxy @vodiaPublicMcpOAuth 127.0.0.1:3113
		reverse_proxy 127.0.0.1:3100'''
s=s.replace(core,new,1)
p.write_text(s)
print("PASS: OAuth gateway route added")
PY

echo "[5/7] Validate patched configuration"
if ! caddy validate --adapter caddyfile --config "$SNIPPET"; then
  cp -a "$BACKUP" "$SNIPPET"
  fail "patched snippet invalid; restored backup"
fi
if ! caddy validate --config "$CADDY_MAIN"; then
  cp -a "$BACKUP" "$SNIPPET"
  fail "full Caddy config invalid; restored backup"
fi
echo PASS

echo "[6/7] Reload Caddy and verify route safety"
systemctl reload caddy
systemctl is-active --quiet caddy || fail "caddy is not active after reload"

if [[ -f "$ENV_FILE" ]]; then
  LEGACY_TOKEN="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("MCP_BEARER_TOKEN="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"":
            v=v[1:-1]
        print(v,end="")
        break
PY
)"
  if [[ -n "$LEGACY_TOKEN" ]]; then
    RESP="$(curl -sS -H "Authorization: Bearer $LEGACY_TOKEN" "$GATEWAY_URL/mcp" || true)"
    grep -q 'legacy_static_token_not_allowed' <<<"$RESP" || fail "gateway did not reject legacy static bearer token"
    unset LEGACY_TOKEN RESP
    echo "PASS: gateway rejects legacy static bearer token"
  else
    echo "WARN: MCP_BEARER_TOKEN not found; skipped legacy-token rejection check"
  fi
fi

echo "[7/7] Final checks"
grep -nE 'vodiaPublicMcpOAuth|reverse_proxy .*3113|reverse_proxy .*3100' "$SNIPPET"
curl -fsS "$CORE_URL/health"; echo
echo "PASS: Caddy OAuth gateway route is valid and active."
echo "Backup retained at: $BACKUP"
