#!/usr/bin/env bash
set -u

# Vodia tenant creation smoke test
#
# Required environment variables:
#   PBX_BASE_URL   e.g. https://pbx.example.com
#   PBX_USERNAME   e.g. admin
#   PBX_PASSWORD   system admin password
#
# Usage:
#   ./test-create-tenant.sh test123.tryvodia.com
#
# Optional:
#   PBX_INSECURE=0   # default is 1, which uses curl -k

TENANT="${1:-}"

fail() {
  echo
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo
  echo "PASS: Tenant '$TENANT' was created and independently verified."
  exit 0
}

if [[ -z "$TENANT" ]]; then
  fail "Usage: $0 <tenant-domain>"
fi

: "${PBX_BASE_URL:?PBX_BASE_URL is not set}"
: "${PBX_USERNAME:?PBX_USERNAME is not set}"
: "${PBX_PASSWORD:?PBX_PASSWORD is not set}"

PBX_BASE_URL="${PBX_BASE_URL%/}"

CURL_TLS=()
if [[ "${PBX_INSECURE:-1}" == "1" ]]; then
  CURL_TLS=(-k)
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

before_body="$tmpdir/before.json"
create_body="$tmpdir/create.out"
after_body="$tmpdir/after.json"

echo "========================================"
echo "VODIA TENANT CREATION TEST"
echo "========================================"
echo "PBX:    $PBX_BASE_URL"
echo "Tenant: $TENANT"
echo

echo "[1/3] Checking that the tenant does not already exist..."

before_code="$(
  curl "${CURL_TLS[@]}" -sS \
    -u "$PBX_USERNAME:$PBX_PASSWORD" \
    -o "$before_body" \
    -w '%{http_code}' \
    "$PBX_BASE_URL/rest/system/domains"
)" || fail "Could not reach PBX tenant-list endpoint."

[[ "$before_code" == "200" ]] || fail \
  "Pre-check GET /rest/system/domains returned HTTP $before_code. Response: $(cat "$before_body" 2>/dev/null)"

if python3 - "$before_body" "$TENANT" <<'PY'
import json, sys
path, tenant = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(2)

found = False
if isinstance(data, dict):
    for value in data.values():
        if isinstance(value, dict) and value.get("name") == tenant:
            found = True
            break
elif isinstance(data, list):
    for value in data:
        if isinstance(value, dict) and value.get("name") == tenant:
            found = True
            break

sys.exit(0 if found else 1)
PY
then
  fail "Tenant already exists. Use a new test tenant name so creation can be proven."
else
  rc=$?
  [[ "$rc" == "1" ]] || fail "Could not parse the PBX tenant-list response as JSON."
fi

echo "OK: tenant does not exist yet."
echo

echo "[2/3] Creating tenant with POST /rest/system/domain..."

payload="$(python3 - "$TENANT" <<'PY'
import json, sys
print(json.dumps([sys.argv[1]]))
PY
)"

create_code="$(
  curl "${CURL_TLS[@]}" -sS \
    -u "$PBX_USERNAME:$PBX_PASSWORD" \
    -X POST \
    -H 'Content-Type: application/json' \
    --data "$payload" \
    -o "$create_body" \
    -w '%{http_code}' \
    "$PBX_BASE_URL/rest/system/domain"
)" || fail "Tenant creation request could not be sent."

echo "Create HTTP status: $create_code"

if [[ -s "$create_body" ]]; then
  echo "Create response:"
  cat "$create_body"
  echo
fi

if [[ ! "$create_code" =~ ^2[0-9][0-9]$ ]]; then
  fail "Create endpoint returned HTTP $create_code."
fi

echo
echo "[3/3] Independently verifying tenant creation..."

# Small retry loop because the PBX may need a moment to expose the new tenant.
verified=0
for attempt in 1 2 3 4 5; do
  after_code="$(
    curl "${CURL_TLS[@]}" -sS \
      -u "$PBX_USERNAME:$PBX_PASSWORD" \
      -o "$after_body" \
      -w '%{http_code}' \
      "$PBX_BASE_URL/rest/system/domains"
  )" || after_code="000"

  if [[ "$after_code" == "200" ]]; then
    if python3 - "$after_body" "$TENANT" <<'PY'
import json, sys
path, tenant = sys.argv[1], sys.argv[2]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    sys.exit(2)

found = False
if isinstance(data, dict):
    for value in data.values():
        if isinstance(value, dict) and value.get("name") == tenant:
            found = True
            break
elif isinstance(data, list):
    for value in data:
        if isinstance(value, dict) and value.get("name") == tenant:
            found = True
            break

sys.exit(0 if found else 1)
PY
    then
      verified=1
      break
    fi
  fi

  sleep 1
done

if [[ "$verified" == "1" ]]; then
  pass
fi

echo
echo "Last tenant-list HTTP status: ${after_code:-unknown}"
echo "Creation request returned HTTP $create_code, but the tenant was not found by a separate read."
if [[ -s "$create_body" ]]; then
  echo "Creation response was:"
  cat "$create_body"
  echo
fi

fail "PBX did not verify creation of '$TENANT'. HTTP success alone is NOT considered a pass."
