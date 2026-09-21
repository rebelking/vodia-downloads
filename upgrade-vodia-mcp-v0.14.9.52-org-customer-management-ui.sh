#!/usr/bin/env bash
# Vodia MCP v0.14.9.52 — organization/customer management UI
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
AUTHZ="$APP/msp-authz-v1.js"
CONNECTIONS="$APP/msp-customer-connections-v1.js"
GUIDED="$APP/msp-guided-app-v1.js"
UI="$APP/ui/msp-guided-app.html"
VERSION="$APP/version.js"
FROM_VER="0.14.9.51"
TO_VER="0.14.9.52"
SOURCE_COMMIT="9a0e7a829126faabfe222bd204662b5fda7b2f2a"
RAW_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-org-customer-ui-$STAMP"
TMP_DIR="$(mktemp -d)"
HEALTH="$TMP_DIR/health.json"
INSTALLED=0

trap 'rm -rf "$TMP_DIR"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

rollback(){
  local rc="${1:-1}"
  trap - ERR
  echo "Activation failed; restoring backup: $BACKUP_DIR" >&2
  cp -a "$BACKUP_DIR/msp-authz-v1.js" "$AUTHZ" || true
  cp -a "$BACKUP_DIR/msp-customer-connections-v1.js" "$CONNECTIONS" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  echo "ROLLED BACK" >&2
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in curl node python3 grep install systemctl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$AUTHZ" "$CONNECTIONS" "$GUIDED" "$UI" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
[[ "$CURRENT" == "$FROM_VER" ]] || fail "expected installed base v${FROM_VER}; found ${CURRENT:-unknown}"

echo "=== Vodia MCP v${TO_VER} — organization/customer management UI ==="

echo "[1/7] Download pinned v0.14.9.52 sources — NO LIVE CHANGES"
mkdir -p "$TMP_DIR/staged/ui"
curl -fsSL "$RAW_BASE/msp-authz-v1.js" -o "$TMP_DIR/staged/msp-authz-v1.js"
curl -fsSL "$RAW_BASE/msp-customer-connections-v1.js" -o "$TMP_DIR/staged/msp-customer-connections-v1.js"
curl -fsSL "$RAW_BASE/msp-guided-app-v1.js" -o "$TMP_DIR/staged/msp-guided-app-v1.js"
curl -fsSL "$RAW_BASE/ui/msp-guided-app.html" -o "$TMP_DIR/staged/ui/msp-guided-app.html"
cp -a "$VERSION" "$TMP_DIR/staged/version.js"

python3 - "$TMP_DIR/staged/version.js" "$FROM_VER" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); old=sys.argv[2]; new=sys.argv[3]
s=p.read_text()
n,count=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])'+re.escape(old)+r'(["\'])',
    r'\g<1>'+new+r'\2',
    s,
    count=1
)
if count != 1:
    raise SystemExit("connector version anchor missing")
p.write_text(n)
PY

echo "[2/7] Static validation — NO LIVE CHANGES"
node --check "$TMP_DIR/staged/msp-authz-v1.js" >/dev/null
node --check "$TMP_DIR/staged/msp-customer-connections-v1.js" >/dev/null
node --check "$TMP_DIR/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP_DIR/staged/version.js" >/dev/null

for name in msp_rename_organization msp_rename_customer; do
  grep -q "$name" "$TMP_DIR/staged/msp-authz-v1.js" || fail "missing tool $name"
done
for name in msp_plan_delete_customer msp_apply_delete_customer msp_plan_delete_organization msp_apply_delete_organization; do
  grep -q "$name" "$TMP_DIR/staged/msp-customer-connections-v1.js" || fail "missing tool $name"
done
for id in manageOrg deleteOrg applyOrgDelete manageCustomer deleteCustomer applyCustomerDelete; do
  grep -q "id=\"$id\"" "$TMP_DIR/staged/ui/msp-guided-app.html" || fail "guided UI missing #$id"
done
grep -q 'ui://vodia/msp-guided/v0.14.9.52/mcp-app.html' "$TMP_DIR/staged/msp-guided-app-v1.js" || fail "guided UI cache-bust URI missing"
grep -q 'externalCloudResourcesDeleted: false' "$TMP_DIR/staged/msp-customer-connections-v1.js" || fail "external-resource safety marker missing"
echo "PASS: source and UI checks"

echo "[3/7] Backup live files"
mkdir -p "$BACKUP_DIR"
cp -a "$AUTHZ" "$BACKUP_DIR/msp-authz-v1.js"
cp -a "$CONNECTIONS" "$BACKUP_DIR/msp-customer-connections-v1.js"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f /var/lib/vodia-mcp/msp-authz.db ]] && cp -a /var/lib/vodia-mcp/msp-authz.db "$BACKUP_DIR/msp-authz.db" || true
[[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]] && cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/msp-customer-connections.enc" || true
echo "PASS: $BACKUP_DIR"

echo "[4/7] Install staged v0.14.9.52 files"
INSTALLED=1
trap 'rollback $?' ERR
install -o root -g root -m 0644 "$TMP_DIR/staged/msp-authz-v1.js" "$AUTHZ"
install -o root -g root -m 0644 "$TMP_DIR/staged/msp-customer-connections-v1.js" "$CONNECTIONS"
install -o root -g root -m 0644 "$TMP_DIR/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP_DIR/staged/ui/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP_DIR/staged/version.js" "$VERSION"
echo "PASS"

echo "[5/7] Restart MCP"
systemctl restart "$SERVICE"
echo "PASS"

echo "[6/7] Health + live verification"
for _ in {1..30}; do
  if curl -fsS -o "$HEALTH" http://127.0.0.1:3100/health 2>/dev/null && [[ -s "$HEALTH" ]]; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 120 --no-pager >&2 || true; fail "MCP health failed"; }
grep -q '"version":"0.14.9.52"' "$HEALTH" || fail "health does not report v0.14.9.52"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
for name in msp_rename_organization msp_rename_customer; do grep -q "$name" "$AUTHZ" || fail "live authz missing $name"; done
for name in msp_plan_delete_customer msp_apply_delete_customer msp_plan_delete_organization msp_apply_delete_organization; do grep -q "$name" "$CONNECTIONS" || fail "live connection module missing $name"; done
for id in manageOrg deleteOrg applyOrgDelete manageCustomer deleteCustomer applyCustomerDelete; do grep -q "id=\"$id\"" "$UI" || fail "live guided UI missing #$id"; done
grep -q 'ui://vodia/msp-guided/v0.14.9.52/mcp-app.html' "$GUIDED" || fail "live guided UI URI is not v0.14.9.52"
echo "PASS"
cat "$HEALTH"; echo

echo "[7/7] Complete"
trap - ERR
INSTALLED=0
echo "PASS: Vodia MCP v${TO_VER} installed"
echo
echo "Vodia Setup now includes:"
echo "  - Manage organization"
echo "  - Rename organization"
echo "  - Delete organization from the UI"
echo "  - Manage customer"
echo "  - Rename customer"
echo "  - Delete customer from the UI"
echo "  - Read-only dependency preview before deletion"
echo "  - Exact confirmation before permanent deletion"
echo "  - Explicit AWS metadata detach when a saved AWS connection exists"
echo "  - External AWS infrastructure is never deleted by these actions"
echo
echo "Backup: $BACKUP_DIR"
echo "Reconnect the MCP client or open Vodia Setup in a fresh message to load the v0.14.9.52 UI."
