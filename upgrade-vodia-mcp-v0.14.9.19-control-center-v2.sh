#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
VERSION="$APP/version.js"
SERVICE="vodia-mcp"
WEB_DIR="$APP/control-center-v2"
SOURCE_REF="${VODIA_MCP_CONTROL_CENTER_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}/control-center-v2"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.19-control-center-v2-$STAMP"
TMP_VERSION="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_VERSION" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node caddy; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
[[ -f "$VERSION" ]] || fail "missing $VERSION"
grep -q '0.14.9.18' "$VERSION" || fail "expected installed base v0.14.9.18"

echo "=== Vodia MCP v0.14.9.19 — Unified Control Center v2 ==="
echo "Installs the customer-facing full-width control center at /control/."
echo "The existing /admin/ page remains unchanged as the protected advanced/admin fallback."

echo "[1/8] Locate Caddy MCP site"
mapfile -t CANDIDATES < <(grep -RIl --include='*.caddy' --include='Caddyfile' 'reverse_proxy[[:space:]]\+127\.0\.0\.1:3100' /etc/caddy 2>/dev/null || true)
[[ ${#CANDIDATES[@]} -eq 1 ]] || {
  printf 'Found %s candidate Caddy files:\n' "${#CANDIDATES[@]}" >&2
  printf '  %s\n' "${CANDIDATES[@]}" >&2
  fail "expected exactly one MCP Caddy site containing reverse_proxy 127.0.0.1:3100"
}
CADDY_SITE="${CANDIDATES[0]}"
echo "PASS: $CADDY_SITE"

echo "[2/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
cp -a "$CADDY_SITE" "$BACKUP_DIR/$(basename "$CADDY_SITE")"
[[ -d "$WEB_DIR" ]] && cp -a "$WEB_DIR" "$BACKUP_DIR/control-center-v2" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-v0.14.9.19 files..."
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  cp -a "$BACKUP_DIR/$(basename "$CADDY_SITE")" "$CADDY_SITE" || true
  if [[ -d "$BACKUP_DIR/control-center-v2" ]]; then
    rm -rf "$WEB_DIR"
    cp -a "$BACKUP_DIR/control-center-v2" "$WEB_DIR"
  else
    rm -rf "$WEB_DIR"
  fi
  caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 && systemctl reload caddy || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

echo "[3/8] Install frontend assets"
mkdir -p "$WEB_DIR"
curl -fsSL "$SOURCE_BASE/index.html" -o "$WEB_DIR/index.html"
curl -fsSL "$SOURCE_BASE/styles.css" -o "$WEB_DIR/styles.css"
curl -fsSL "$SOURCE_BASE/app.js" -o "$WEB_DIR/app.js"
chmod 0755 "$WEB_DIR"
chmod 0644 "$WEB_DIR/index.html" "$WEB_DIR/styles.css" "$WEB_DIR/app.js"
for marker in   'Vodia MCP Control Center'   'Connected services'   'What do you want to do?'   'Advanced administration'; do
  grep -q "$marker" "$WEB_DIR/index.html" || fail "frontend marker missing: $marker"
done
if grep -Eq '<input|<textarea|contenteditable=' "$WEB_DIR/index.html"; then
  fail "customer frontend contains a text-entry control"
fi
echo "PASS: customer dashboard has no text-entry fields"

echo "[4/8] Add /control/ static route"
python3 - "$CADDY_SITE" "$WEB_DIR" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); web=sys.argv[2]
s=p.read_text()
marker='# v0.14.9.19 unified customer control center'
if marker in s:
    print('Route already present')
    raise SystemExit(0)
needle='reverse_proxy 127.0.0.1:3100'
if s.count(needle) != 1:
    raise SystemExit(f'PATCH ERROR: expected one reverse_proxy anchor, found {s.count(needle)}')
replacement=f'''# v0.14.9.19 unified customer control center
    handle_path /control/* {{
        root * {web}
        file_server
    }}

    handle {{
        reverse_proxy 127.0.0.1:3100
    }}'''
s=s.replace(needle,replacement,1)
p.write_text(s)
PY
caddy fmt --overwrite "$CADDY_SITE" >/dev/null
caddy validate --config /etc/caddy/Caddyfile >/dev/null
echo PASS

echo "[5/8] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.19\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null
echo PASS

echo "[6/8] Activate"
trap rollback ERR
cp -a "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
systemctl reload caddy
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health check failed"
grep -q '0.14.9.19' "$HEALTH" || fail "health did not report v0.14.9.19"
echo PASS

echo "[7/8] Local route validation"
HOST_HEADER="$(awk '/^[[:space:]]*[A-Za-z0-9.-]+[[:space:]]*\{/ {gsub(/[[:space:]{]/,"",$1); print $1; exit}' "$CADDY_SITE")"
if [[ -n "$HOST_HEADER" ]]; then
  curl -ksS --resolve "$HOST_HEADER:443:127.0.0.1" "https://$HOST_HEADER/control/" | grep -q 'Vodia MCP Control Center'     || fail "Caddy /control/ route did not return the new frontend"
  echo "PASS: https://$HOST_HEADER/control/"
else
  echo "WARN: could not derive host name for local HTTPS route test"
fi

echo "[8/8] Complete"
cat "$HEALTH"; echo
echo "PASS: v0.14.9.19 Unified Control Center v2 installed"
echo "PASS: no raw token/Role ARN/External ID/API-token input fields on the main customer dashboard"
echo "PASS: old /admin/ remains available for advanced administration"
echo "PASS: new frontend is served at /control/"
echo "Backup: $BACKUP_DIR"
trap - ERR
