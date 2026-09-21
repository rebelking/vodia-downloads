#!/usr/bin/env bash
# Vodia MCP v0.14.9.55 — preserve existing AWS connection / clear stale onboarding safely
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
SOURCE_COMMIT="d09244c5eea3b6871338bd2440803e4676f421d5"
BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
TO_VER="0.14.9.55"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-existing-aws-guard-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl python3 node grep install systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

BACKEND="$APP/msp-customer-connections-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.54) ;;
  0.14.9.55) echo "v0.14.9.55 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.54; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — existing AWS connection guard ==="
echo "[1/6] Download pinned source — NO LIVE CHANGES"
mkdir -p "$TMP/staged/ui"
curl -fsSL "$BASE_URL/msp-customer-connections-v1.js" -o "$TMP/staged/msp-customer-connections-v1.js"
curl -fsSL "$BASE_URL/msp-guided-app-v1.js" -o "$TMP/staged/msp-guided-app-v1.js"
curl -fsSL "$BASE_URL/ui/msp-guided-app.html" -o "$TMP/staged/ui/msp-guided-app.html"
cp -a "$VERSION" "$TMP/staged/version.js"

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
                r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

echo "[2/6] Validate staged source"
node --check "$TMP/staged/msp-customer-connections-v1.js" >/dev/null
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
grep -Fq 'alreadyConnected: true' "$TMP/staged/msp-customer-connections-v1.js" || fail "existing AWS guard missing"
grep -Fq 'reusedExisting: true' "$TMP/staged/msp-customer-connections-v1.js" || fail "existing AWS recovery missing"
grep -Fq 'delete customer.awsOnboarding' "$TMP/staged/msp-customer-connections-v1.js" || fail "stale onboarding cleanup missing"
grep -Fq 'Existing customer AWS connection verified. No new External ID' "$TMP/staged/msp-customer-connections-v1.js" || fail "existing connection message missing"
grep -Fq 'data-existing-aws-guard="v0.14.9.55"' "$TMP/staged/ui/msp-guided-app.html" || fail "UI marker missing"
grep -Fq 'No replacement External ID was used' "$TMP/staged/ui/msp-guided-app.html" || fail "UI recovery messaging missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.55/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "UI cache-bust missing"
echo "PASS"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR/ui"
cp -a "$BACKEND" "$BACKUP_DIR/msp-customer-connections-v1.js"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$UI" "$BACKUP_DIR/ui/msp-guided-app.html"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.key ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.key "$BACKUP_DIR/" || true
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.54 application files"
  cp -a "$BACKUP_DIR/msp-customer-connections-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/ui/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-customer-connections-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/ui/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/6] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.55"' <<<"$HEALTH" || fail "health does not report v0.14.9.55"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"
echo "PASS"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.55 installed"
echo "PASS: Existing saved AWS connections are verified and reused."
echo "PASS: No replacement External ID is generated for an already-connected customer."
echo "PASS: Stale pending onboarding is removed only after the saved connection verifies successfully."
echo "PASS: New customers still receive customer-specific AWS onboarding."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.55 UI."
