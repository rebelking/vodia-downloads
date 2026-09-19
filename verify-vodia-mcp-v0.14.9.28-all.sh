#!/usr/bin/env bash
# Vodia MCP v0.14.9.28 full validation — read-only.
# Verifies version, systemd services, ports, Caddy, OAuth/public auth boundary,
# MSP/customer isolation settings, encrypted-store permissions, and MCP tool registration.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
CADDY_MAIN="${VODIA_MCP_CADDY_MAIN:-/etc/caddy/Caddyfile}"
CADDY_SNIPPET="${VODIA_MCP_CADDY_FILE:-/etc/caddy/conf.d/vodia-mcp.caddy}"
CORE="http://127.0.0.1:3100"
GATEWAY="http://127.0.0.1:3113"
TARGET_VERSION="0.14.9.28"

PASS=0
WARN=0
FAIL=0

ok(){ PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
warn(){ WARN=$((WARN+1)); printf 'WARN  %s\n' "$*" >&2; }
bad(){ FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

env_value(){
  local key="$1"
  python3 - "$ENV_FILE" "$key" <<'PY'
from pathlib import Path
import sys
p,key=Path(sys.argv[1]),sys.argv[2]
if not p.exists(): raise SystemExit
for line in p.read_text().splitlines():
    if line.startswith(key+"="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "'\"": v=v[1:-1]
        print(v,end="")
        break
PY
}

echo "=== Vodia MCP v0.14.9.28 Full Validation ==="
echo "Read-only validation; no configuration changes will be made."
echo

[[ ${EUID} -eq 0 ]] && ok "running as root" || warn "not running as root; some permission/systemd checks may be incomplete"

for c in python3 node curl grep systemctl caddy ss; do
  if have "$c"; then ok "dependency available: $c"; else bad "missing dependency: $c"; fi
done

echo
echo "--- 1. Files and version ---"
for f in   "$APP/version.js"   "$APP/index.js"   "$APP/msp-authz-v1.js"   "$APP/msp-customer-connections-v1.js"   "$APP/aws-marketplace-ec2-deploy-v1.js"   "$APP/public-mcp-auth-gateway-v1.js"   "$ENV_FILE"   "$CADDY_MAIN"   "$CADDY_SNIPPET"; do
  [[ -f "$f" ]] && ok "present: $f" || bad "missing: $f"
done

CURRENT=""
if [[ -f "$APP/version.js" ]]; then
  CURRENT="$(python3 - "$APP/version.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)["\']',s)
print(m.group(1) if m else "",end="")
PY
)"
fi
[[ "$CURRENT" == "$TARGET_VERSION" ]] && ok "connector version $CURRENT" || bad "expected $TARGET_VERSION, found ${CURRENT:-unknown}"

for f in "$APP/index.js" "$APP/msp-authz-v1.js" "$APP/msp-customer-connections-v1.js" "$APP/aws-marketplace-ec2-deploy-v1.js" "$APP/public-mcp-auth-gateway-v1.js"; do
  if [[ -f "$f" ]]; then
    node --check "$f" >/dev/null 2>&1 && ok "JavaScript syntax: $(basename "$f")" || bad "JavaScript syntax failed: $f"
  fi
done

echo
echo "--- 2. Environment and customer isolation ---"
if [[ -f "$ENV_FILE" ]]; then
  [[ "$(env_value VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT)" == "true" ]]     && ok "VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT=true"     || bad "VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT is not true"

  for k in VODIA_MSP_AUTHZ_DB VODIA_MSP_CUSTOMER_CONNECTION_STORE VODIA_MSP_CUSTOMER_CONNECTION_KEY_FILE PUBLIC_BASE_URL DB_PATH SESSION_SECRET; do
    v="$(env_value "$k")"
    [[ -n "$v" ]] && ok "$k configured" || warn "$k is not configured"
  done

  legacy="$(env_value MCP_BEARER_TOKEN)"
  [[ -n "$legacy" ]] && ok "legacy MCP bearer exists for trusted-local compatibility" || warn "MCP_BEARER_TOKEN not found"
else
  bad "environment file missing"
  legacy=""
fi

echo
echo "--- 3. Systemd services ---"
for svc in vodia-mcp vodia-public-mcp-gateway caddy; do
  if systemctl is-enabled --quiet "$svc" 2>/dev/null; then ok "$svc enabled"; else warn "$svc not enabled"; fi
  if systemctl is-active --quiet "$svc"; then ok "$svc active"; else bad "$svc not active"; fi
done

echo
echo "--- 4. Listening sockets ---"
if ss -ltnp 2>/dev/null | grep -qE '127\.0\.0\.1:3100\b'; then ok "MCP core listening on 127.0.0.1:3100"; else bad "MCP core not listening on 127.0.0.1:3100"; fi
if ss -ltnp 2>/dev/null | grep -qE '127\.0\.0\.1:3113\b'; then ok "OAuth gateway listening on 127.0.0.1:3113"; else bad "OAuth gateway not listening on 127.0.0.1:3113"; fi

echo
echo "--- 5. Core health ---"
HEALTH="$(curl -fsS "$CORE/health" 2>/dev/null || true)"
if [[ -n "$HEALTH" ]]; then
  ok "core health endpoint responds"
  grep -q '"ok":true' <<<"$HEALTH" && ok "core reports ok=true" || bad "core health does not report ok=true"
  grep -q '"version":"0.14.9.28"' <<<"$HEALTH" && ok "health reports v0.14.9.28" || bad "health reports unexpected version"
  grep -q '"oauthEnabled":true' <<<"$HEALTH" && ok "health reports oauthEnabled=true" || bad "OAuth is not enabled in health response"
else
  bad "core health endpoint did not respond"
fi

echo
echo "--- 6. Caddy validation and routing ---"
if [[ -f "$CADDY_MAIN" ]]; then
  caddy validate --config "$CADDY_MAIN" >/tmp/vodia-caddy-main-check.log 2>&1     && ok "main Caddy configuration valid"     || { bad "main Caddy configuration invalid"; tail -20 /tmp/vodia-caddy-main-check.log >&2; }
fi
if [[ -f "$CADDY_SNIPPET" ]]; then
  caddy validate --adapter caddyfile --config "$CADDY_SNIPPET" >/tmp/vodia-caddy-snippet-check.log 2>&1     && ok "Vodia Caddy snippet valid with caddyfile adapter"     || { bad "Vodia Caddy snippet invalid"; tail -20 /tmp/vodia-caddy-snippet-check.log >&2; }

  grep -q '@vodiaPublicMcpOAuth path /mcp /mcp/\*' "$CADDY_SNIPPET"     && ok "public MCP matcher present" || bad "public MCP matcher missing"
  grep -q 'reverse_proxy @vodiaPublicMcpOAuth 127.0.0.1:3113' "$CADDY_SNIPPET"     && ok "public /mcp routes to OAuth gateway :3113" || bad "public /mcp does not route to :3113"
  grep -q 'reverse_proxy 127.0.0.1:3100' "$CADDY_SNIPPET"     && ok "fallback/core route to :3100 preserved" || bad "core reverse proxy :3100 missing"
fi

echo
echo "--- 7. Public auth boundary ---"
if [[ -n "${legacy:-}" ]]; then
  LEGACY_RESP="$(curl -sS -H "Authorization: Bearer $legacy" "$GATEWAY/mcp" 2>/dev/null || true)"
  grep -q 'legacy_static_token_not_allowed' <<<"$LEGACY_RESP"     && ok "gateway rejects legacy server-wide bearer token"     || bad "gateway did not reject legacy server-wide bearer token"
fi

NOAUTH_CODE="$(curl -sS -o /tmp/vodia-gateway-noauth.out -w '%{http_code}' "$GATEWAY/mcp" 2>/dev/null || true)"
case "$NOAUTH_CODE" in
  401|403) ok "gateway rejects unauthenticated /mcp (HTTP $NOAUTH_CODE)" ;;
  *) warn "unauthenticated gateway /mcp returned HTTP ${NOAUTH_CODE:-unknown}; inspect /tmp/vodia-gateway-noauth.out" ;;
esac

echo
echo "--- 8. OAuth public metadata ---"
PUBLIC_BASE="$(env_value PUBLIC_BASE_URL)"
if [[ -n "$PUBLIC_BASE" ]]; then
  PUBLIC_BASE="${PUBLIC_BASE%/}"
  found_meta=0
  for p in     "/.well-known/oauth-authorization-server"     "/.well-known/openid-configuration"     "/.well-known/oauth-protected-resource"; do
    code="$(curl -sS -o /tmp/vodia-oauth-meta.json -w '%{http_code}' "$PUBLIC_BASE$p" 2>/dev/null || true)"
    if [[ "$code" == "200" ]]; then
      ok "OAuth metadata endpoint responds: $p"
      found_meta=1
      break
    fi
  done
  [[ "$found_meta" == "1" ]] || warn "no standard OAuth metadata endpoint returned HTTP 200 at PUBLIC_BASE_URL"
else
  warn "PUBLIC_BASE_URL unavailable; skipped external OAuth metadata check"
fi

echo
echo "--- 9. MSP/customer data stores and permissions ---"
AUTHZ_DB="$(env_value VODIA_MSP_AUTHZ_DB)"
CONN_STORE="$(env_value VODIA_MSP_CUSTOMER_CONNECTION_STORE)"
CONN_KEY="$(env_value VODIA_MSP_CUSTOMER_CONNECTION_KEY_FILE)"

if [[ -n "$AUTHZ_DB" ]]; then
  if [[ -e "$AUTHZ_DB" ]]; then
    ok "MSP authz database exists"
    mode="$(stat -c '%a' "$AUTHZ_DB" 2>/dev/null || true)"
    case "$mode" in 600|640|660) ok "MSP authz DB permissions $mode" ;; *) warn "MSP authz DB permissions are ${mode:-unknown}" ;; esac
  else
    warn "MSP authz database does not exist yet; expected before/after first MSP tool use depending on initialization"
  fi
fi

if [[ -n "$CONN_STORE" ]]; then
  if [[ -e "$CONN_STORE" ]]; then
    [[ "$(stat -c '%a' "$CONN_STORE")" == "600" ]] && ok "customer connection store mode 600" || warn "customer connection store is not mode 600"
  else
    warn "customer connection store not created yet (normal before first saved customer AWS connection)"
  fi
fi

if [[ -n "$CONN_KEY" ]]; then
  if [[ -e "$CONN_KEY" ]]; then
    [[ "$(stat -c '%a' "$CONN_KEY")" == "600" ]] && ok "customer connection encryption key mode 600" || bad "customer connection key is not mode 600"
  else
    warn "customer connection key not created yet (normal before first saved customer AWS connection)"
  fi
fi

echo
echo "--- 10. Local MCP initialize and tool registration ---"
if [[ -n "${legacy:-}" ]]; then
  INIT_HEADERS="$(mktemp)"
  INIT_BODY="$(mktemp)"
  trap 'rm -f "$INIT_HEADERS" "$INIT_BODY"' EXIT
  curl -sS -D "$INIT_HEADERS" -o "$INIT_BODY"     -H "Authorization: Bearer $legacy"     -H 'Content-Type: application/json'     -H 'Accept: application/json, text/event-stream'     --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vodia-validator","version":"1.0"}}}'     "$CORE/mcp" || true

  SESSION_ID="$(awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {gsub("\r","",$2); print $2}' "$INIT_HEADERS" | tail -1)"
  if grep -q '"serverInfo"' "$INIT_BODY" || grep -q 'serverInfo' "$INIT_BODY"; then
    ok "local MCP initialize succeeds with trusted-local legacy token"
  else
    bad "local MCP initialize failed; inspect $INIT_BODY"
  fi

  if [[ -n "$SESSION_ID" ]]; then
    curl -sS       -H "Authorization: Bearer $legacy"       -H "mcp-session-id: $SESSION_ID"       -H 'Content-Type: application/json'       -H 'Accept: application/json, text/event-stream'       --data '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'       "$CORE/mcp" >/dev/null || true

    TOOLS_OUT="$(mktemp)"
    curl -sS       -H "Authorization: Bearer $legacy"       -H "mcp-session-id: $SESSION_ID"       -H 'Content-Type: application/json'       -H 'Accept: application/json, text/event-stream'       --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'       "$CORE/mcp" >"$TOOLS_OUT" || true

    for tool in       msp_get_my_identity       msp_create_organization       msp_create_customer       msp_grant_membership       msp_list_customers       msp_get_commercial_audit       msp_get_customer_aws_connection       msp_save_customer_aws_connection       aws_marketplace_present_vodia_offer       aws_marketplace_prepare_vodia_purchase       aws_marketplace_accept_vodia_purchase; do
      grep -q "\"name\":\"$tool\"" "$TOOLS_OUT"         && ok "tool registered: $tool"         || bad "tool missing: $tool"
    done
    rm -f "$TOOLS_OUT"
  else
    bad "MCP initialize returned no mcp-session-id"
  fi
else
  warn "legacy token unavailable; skipped local MCP tool registration check"
fi

echo
echo "=== SUMMARY ==="
echo "PASS: $PASS"
echo "WARN: $WARN"
echo "FAIL: $FAIL"

if (( FAIL > 0 )); then
  echo "RESULT: FAIL — correct the failed checks before customer OAuth/MSP testing."
  exit 1
fi

if (( WARN > 0 )); then
  echo "RESULT: PASS WITH WARNINGS — core safety checks passed; review warnings."
  exit 0
fi

echo "RESULT: PASS — v0.14.9.28 parameters are consistent."
