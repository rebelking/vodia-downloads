#!/usr/bin/env bash
set -Eeuo pipefail
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
CORE="${VODIA_MCP_CORE_URL:-http://127.0.0.1:3100/mcp}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "PASS: $*"; }

[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE"
TOKEN="$(python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys
for line in Path(sys.argv[1]).read_text().splitlines():
    if line.startswith("MCP_BEARER_TOKEN="):
        v=line.split("=",1)[1].strip()
        if len(v)>=2 and v[0]==v[-1] and v[0] in "\'\\\"": v=v[1:-1]
        print(v,end="")
        break
PY
)"
[[ -n "$TOKEN" ]] || fail "MCP_BEARER_TOKEN missing"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "=== MCP transport diagnostic ==="
INIT_CODE="$(curl -sS -D "$T/init.h" -o "$T/init.b" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"vodia-validator","version":"1.1"}}}' \
  "$CORE" || true)"
echo "initialize HTTP: ${INIT_CODE:-unknown}"
cat "$T/init.b"; echo
[[ "$INIT_CODE" == "200" ]] || fail "initialize did not return HTTP 200"
grep -q 'serverInfo' "$T/init.b" || fail "initialize response has no serverInfo"
ok "initialize succeeded"

SESSION_ID="$(awk 'BEGIN{IGNORECASE=1} /^mcp-session-id:/ {gsub("\\r","",$2); print $2}' "$T/init.h" | tail -1)"
if [[ -n "$SESSION_ID" ]]; then
  ok "stateful MCP session detected"
  curl -sS \
    -H "Authorization: Bearer $TOKEN" \
    -H "mcp-session-id: $SESSION_ID" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
    "$CORE" >/dev/null || true
  curl -sS \
    -H "Authorization: Bearer $TOKEN" \
    -H "mcp-session-id: $SESSION_ID" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    "$CORE" >"$T/tools.b"
else
  echo "INFO: no mcp-session-id returned; testing stateless tools/list"
  curl -sS \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    --data '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
    "$CORE" >"$T/tools.b"
fi

grep -q 'tools' "$T/tools.b" || { cat "$T/tools.b"; fail "tools/list returned no tool inventory"; }
ok "tools/list returned inventory"

for tool in \
  msp_get_my_identity \
  msp_create_organization \
  msp_create_customer \
  msp_grant_membership \
  msp_list_customers \
  msp_get_commercial_audit \
  msp_get_customer_aws_connection \
  msp_save_customer_aws_connection \
  aws_marketplace_present_vodia_offer \
  aws_marketplace_prepare_vodia_purchase \
  aws_marketplace_accept_vodia_purchase
do
  grep -q "$tool" "$T/tools.b" && ok "tool registered: $tool" || fail "tool missing: $tool"
done

echo "RESULT: PASS — local trusted MCP transport and v0.14.9.28 tools are healthy."