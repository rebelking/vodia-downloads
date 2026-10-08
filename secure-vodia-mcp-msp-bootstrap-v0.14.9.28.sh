#!/usr/bin/env bash
# Secure v0.14.9.28 MSP bootstrap.
# Usage:
#   ./secure-vodia-mcp-msp-bootstrap-v0.14.9.28.sh 'user_id:<stable-oauth-user-id>'
#
# This:
# 1) pins an explicit bootstrap OAuth subject in /etc/vodia-mcp.env
# 2) disables unrestricted "first OAuth user claims first MSP org"
# 3) validates JS, restarts, and checks health
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
AUTHZ="$APP/msp-authz-v1.js"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="/var/backups/vodia-mcp-v0.14.9.28-secure-bootstrap-$STAMP"
SUBJECT="${1:-}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc="${1:-1}"
  echo "Rolling back secure-bootstrap change..." >&2
  cp -a "$BACKUP/msp-authz-v1.js" "$AUTHZ" 2>/dev/null || true
  cp -a "$BACKUP/vodia-mcp.env" "$ENV_FILE" 2>/dev/null || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
[[ -n "$SUBJECT" ]] || fail "usage: $0 'user_id:<stable-oauth-user-id>'"
[[ "$SUBJECT" =~ ^(user_id|userId|sub|user\.id|email|user\.email):.+$ ]] || fail "unexpected subject format"
[[ -f "$AUTHZ" ]] || fail "missing $AUTHZ"
[[ -f "$ENV_FILE" ]] || fail "missing $ENV_FILE"

echo "[1/7] Backup current authz module and environment"
mkdir -p "$BACKUP"
cp -a "$AUTHZ" "$BACKUP/msp-authz-v1.js"
cp -a "$ENV_FILE" "$BACKUP/vodia-mcp.env"
echo "PASS: $BACKUP"

echo "[2/7] Pin explicit bootstrap subject"
python3 - "$ENV_FILE" "$SUBJECT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); subject=sys.argv[2]
lines=p.read_text().splitlines()
key="VODIA_MSP_BOOTSTRAP_SUBJECTS"
new=f'{key}="{subject}"'
out=[]
seen=False
for line in lines:
    if line.startswith(key+"="):
        if not seen:
            out.append(new)
            seen=True
    else:
        out.append(line)
if not seen:
    out.append(new)
p.write_text("\n".join(out)+"\n")
PY
grep -q '^VODIA_MSP_BOOTSTRAP_SUBJECTS=' "$ENV_FILE" || fail "bootstrap env was not written"
echo PASS

echo "[3/7] Disable unrestricted first-user organization claim"
python3 - "$AUTHZ" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''  const organizationCount = Number(db.prepare("SELECT COUNT(*) AS n FROM organizations").get()?.n || 0);
  if (organizationCount === 0) return { identity, bootstrap: true, firstOrganizationClaim: true };
  if (isBootstrap(identity.subject)) return { identity, bootstrap: true };
'''
new='''  const organizationCount = Number(db.prepare("SELECT COUNT(*) AS n FROM organizations").get()?.n || 0);
  if (organizationCount === 0) {
    if (isBootstrap(identity.subject)) {
      return { identity, bootstrap: true, firstOrganizationClaim: true };
    }
    throw new Error("MSP_BOOTSTRAP_REQUIRED: first organization creation requires an explicitly configured bootstrap OAuth subject.");
  }
  if (isBootstrap(identity.subject)) return { identity, bootstrap: true };
'''
if new in s:
    print("PASS: strict bootstrap guard already present")
elif old in s:
    p.write_text(s.replace(old,new,1))
    print("PASS: strict bootstrap guard installed")
else:
    raise SystemExit("PATCH ERROR: expected requireMspAdmin bootstrap block not found")
PY

echo "[4/7] Validate JavaScript"
node --check "$AUTHZ"
echo PASS

echo "[5/7] Restart Vodia MCP"
trap 'rollback $?' ERR
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health >/tmp/vodia-secure-bootstrap-health.json 2>/dev/null; then
    break
  fi
  sleep 1
done
[[ -s /tmp/vodia-secure-bootstrap-health.json ]] || fail "health did not recover"
grep -q '"version":"0.14.9.28"' /tmp/vodia-secure-bootstrap-health.json || fail "unexpected MCP version"
cat /tmp/vodia-secure-bootstrap-health.json; echo
echo PASS

echo "[6/7] Verify environment and strict guard"
grep '^VODIA_MSP_BOOTSTRAP_SUBJECTS=' "$ENV_FILE" | sed 's/=.*/="[REDACTED]"/'
grep -q 'MSP_BOOTSTRAP_REQUIRED: first organization creation requires an explicitly configured bootstrap OAuth subject' "$AUTHZ"   || fail "strict bootstrap guard missing"
echo PASS

echo "[7/7] Complete"
trap - ERR
echo "PASS: explicit MSP bootstrap subject pinned and unrestricted first-user bootstrap disabled."
echo "Backup retained at: $BACKUP"
echo "Next: reconnect OAuth client if needed, call msp_get_my_identity, then msp_create_organization."
