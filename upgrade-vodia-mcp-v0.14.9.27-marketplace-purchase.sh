#!/usr/bin/env bash
# Vodia MCP v0.14.9.27 — In-chat AWS Marketplace quote + acceptance flow
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="vodia-mcp"
VERSION="$APP/version.js"
MODULE="$APP/aws-marketplace-ec2-deploy-v1.js"
FROM_VER="0.14.9.26"
TO_VER="0.14.9.27"
SOURCE_COMMIT="c3f1d4ac77c80e4cf6744dc3f267ae92a3a431f1"
SOURCE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_COMMIT}/aws-marketplace-ec2-deploy-v1.js"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-marketplace-purchase-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_MODULE="$TMP_DIR/aws-marketplace-ec2-deploy-v1.js"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"
INSTALLED=0

trap 'rm -rf "$TMP_DIR"' EXIT

rollback(){
  local rc="${1:-1}"
  trap - ERR
  INSTALLED=0
  echo "Activation failed; restoring pre-v${TO_VER} state from $BACKUP_DIR ..." >&2
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$MODULE" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  echo "ROLLED BACK. Backup kept at: $BACKUP_DIR" >&2
  exit "$rc"
}

fail(){
  echo "FAIL: $*" >&2
  if (( INSTALLED )); then rollback 1; fi
  exit 1
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node curl grep install systemctl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
[[ -f "$VERSION" ]] || fail "missing $VERSION"
[[ -f "$MODULE" ]] || fail "missing $MODULE"

grep -Eq "CONNECTOR_VERSION[[:space:]]*=[[:space:]]*[\"']${FROM_VER//./\\.}[\"']" "$VERSION" \
  || fail "expected installed base v${FROM_VER}"

echo "=== Vodia MCP v${TO_VER} — AWS Marketplace in-chat purchase flow ==="

echo "[1/7] Verify installed AWS SDK supports Agreement purchase APIs"
(
  cd "$APP"
  node --input-type=module - <<'NODE'
import {
  CreateAgreementRequestCommand,
  AcceptAgreementRequestCommand
} from "@aws-sdk/client-marketplace-agreement";
if (!CreateAgreementRequestCommand || !AcceptAgreementRequestCommand) {
  throw new Error("installed @aws-sdk/client-marketplace-agreement is too old");
}
console.log("PASS: Agreement purchase commands available");
NODE
) || fail "AWS SDK package does not expose CreateAgreementRequestCommand/AcceptAgreementRequestCommand"

echo "[2/7] Download staged module — NO LIVE CHANGES"
curl -fsSL "$SOURCE_URL" -o "$TMP_MODULE"
node --check "$TMP_MODULE" >/dev/null || fail "staged Marketplace module failed node --check"
if grep -Fq '\\`' "$TMP_MODULE" || grep -Fq '\\${' "$TMP_MODULE"; then
  fail "staged Marketplace module contains escaped JavaScript template literals"
fi
for tool in \
  aws_marketplace_present_vodia_offer \
  aws_marketplace_prepare_vodia_purchase \
  aws_marketplace_accept_vodia_purchase; do
  grep -q "\"$tool\"" "$TMP_MODULE" || fail "staged module missing $tool"
done
grep -q 'iamInstanceProfileName: z.string().min(1).optional()' "$TMP_MODULE" \
  || fail "instance profile was not made optional"
echo PASS

echo "[3/7] Stage version — NO LIVE CHANGES"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" "$TO_VER" <<'PY'
from pathlib import Path
import re, sys
p, to = Path(sys.argv[1]), sys.argv[2]
s = p.read_text()
n = re.sub(
    r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
    r'\g<1>' + to + r'\2',
    s,
    count=1
)
if n == s:
    raise SystemExit("CONNECTOR_VERSION assignment not found")
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "staged version.js failed node --check"
echo PASS

echo "[4/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$MODULE" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[5/7] Install"
INSTALLED=1
trap 'rollback $?' ERR
install -o root -g root -m 0644 "$TMP_MODULE" "$MODULE"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
systemctl restart "$SERVICE"
echo PASS

echo "[6/7] Health validation"
rm -f "$HEALTH"
for _ in {1..30}; do
  if curl -fsS -o "$HEALTH" http://127.0.0.1:3100/health 2>/dev/null && [[ -s "$HEALTH" ]]; then
    break
  fi
  rm -f "$HEALTH"
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health failed after 30s"
grep -Eq "(^|[^0-9.])${TO_VER//./\\.}([^0-9.]|$)" "$HEALTH" \
  || fail "health did not report v${TO_VER}"
systemctl is-active --quiet "$SERVICE" || fail "MCP service inactive"
echo PASS

echo "[7/7] Complete"
trap - ERR
INSTALLED=0
cat "$HEALTH"
echo
echo "PASS: v${TO_VER} installed"
echo "New tools:"
echo "  aws_marketplace_present_vodia_offer"
echo "  aws_marketplace_prepare_vodia_purchase"
echo "  aws_marketplace_accept_vodia_purchase"
echo
echo "Important: the customer VodiaMCPDeploymentRole must allow:"
echo "  aws-marketplace:CreateAgreementRequest"
echo "  aws-marketplace:AcceptAgreementRequest"
echo "for the Vodia Marketplace product before quote/accept will succeed."
echo "Backup: $BACKUP_DIR"
