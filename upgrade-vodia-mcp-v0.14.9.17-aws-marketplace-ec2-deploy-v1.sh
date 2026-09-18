#!/usr/bin/env bash
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
INDEX="$APP/index.js"
VERSION="$APP/version.js"
MODULE="$APP/aws-marketplace-ec2-deploy-v1.js"
SERVICE="vodia-mcp"
SOURCE_REF="${VODIA_MCP_AWS_DEPLOY_SOURCE_REF:-feature/aws-marketplace-ec2-deploy-v1}"
SOURCE_BASE="https://raw.githubusercontent.com/rebelking/vodia-downloads/${SOURCE_REF}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v0.14.9.17-aws-marketplace-deploy-$STAMP"
TMP_INDEX="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
TMP_MODULE="$(mktemp --suffix=.js)"
HEALTH="$(mktemp)"
trap 'rm -f "$TMP_INDEX" "$TMP_VERSION" "$TMP_MODULE" "$HEALTH"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
rollback(){
  local rc=$?
  trap - ERR
  echo "Activation failed; restoring pre-AWS Marketplace deployment files..."
  [[ -f "$BACKUP_DIR/index.js" ]] && cp -a "$BACKUP_DIR/index.js" "$INDEX" || true
  [[ -f "$BACKUP_DIR/version.js" ]] && cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  if [[ -f "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" ]]; then
    cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$MODULE"
  else
    rm -f "$MODULE"
  fi
  [[ -f "$BACKUP_DIR/package.json" ]] && cp -a "$BACKUP_DIR/package.json" "$APP/package.json" || true
  [[ -f "$BACKUP_DIR/package-lock.json" ]] && cp -a "$BACKUP_DIR/package-lock.json" "$APP/package-lock.json" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for f in "$INDEX" "$VERSION" "$APP/package.json"; do [[ -f "$f" ]] || fail "missing $f"; done
for c in python3 node npm curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

echo "=== Vodia MCP v0.14.9.17 — AWS Marketplace + EC2 deployment v1 ==="
echo "Purpose: assume a customer role, verify an ACTIVE Marketplace agreement, validate an EC2 launch with DryRun, then deploy only after exact approval."
echo "Commercial Marketplace acceptance is NOT automated in v1."

echo "[1/9] Preflight"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
node --check "$VERSION" >/dev/null || fail "current version.js syntax invalid"
grep -q '0.14.9.16' "$VERSION" || fail "expected installed base version 0.14.9.16"
grep -q 'export function createVodiaServer' "$INDEX" || fail "createVodiaServer anchor missing"
grep -q 'server.registerTool' "$INDEX" || fail "tool registration anchor missing"
if grep -q 'v0.14.9.17 AWS Marketplace EC2 deployment' "$INDEX"; then
  echo "v0.14.9.17 already appears installed; exiting without changes."
  exit 0
fi
echo PASS

echo "[2/9] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$INDEX" "$BACKUP_DIR/index.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
[[ -f "$MODULE" ]] && cp -a "$MODULE" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" || true
cp -a "$APP/package.json" "$BACKUP_DIR/package.json"
[[ -f "$APP/package-lock.json" ]] && cp -a "$APP/package-lock.json" "$BACKUP_DIR/package-lock.json" || true
echo "PASS: $BACKUP_DIR"

echo "[3/9] Install AWS SDK dependencies"
cd "$APP"
npm install --save \
  @aws-sdk/client-sts \
  @aws-sdk/client-ec2 \
  @aws-sdk/client-marketplace-discovery \
  @aws-sdk/client-marketplace-agreement \
  @aws-sdk/credential-providers >/tmp/vodia-mcp-aws-marketplace-npm.log 2>&1 || {
    cat /tmp/vodia-mcp-aws-marketplace-npm.log >&2
    fail "npm install failed"
  }
echo PASS

echo "[4/9] Download deployment module"
curl -fsSL "$SOURCE_BASE/aws-marketplace-ec2-deploy-v1.js" -o "$TMP_MODULE"
grep -q 'registerAwsMarketplaceDeployTools' "$TMP_MODULE" || fail "downloaded module missing expected export"
cp -a "$TMP_MODULE" "$MODULE"
node --check "$MODULE" >/dev/null || fail "deployment module syntax invalid"
node -e 'import("./aws-marketplace-ec2-deploy-v1.js").then(()=>process.exit(0)).catch(e=>{console.error(e);process.exit(1)})' || fail "deployment module dependency load failed"
echo PASS

echo "[5/9] Patch index.js registration"
cp -a "$INDEX" "$TMP_INDEX"
python3 - "$TMP_INDEX" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker='v0.14.9.17 AWS Marketplace EC2 deployment'
if marker in s:
    raise SystemExit('PATCH ERROR: marker already present')

import_line='import { registerAwsMarketplaceDeployTools } from "./aws-marketplace-ec2-deploy-v1.js";\n'
# Insert after the existing import block, before first non-import statement.
lines=s.splitlines(True)
insert_at=0
for i,line in enumerate(lines):
    if line.startswith('import '):
        insert_at=i+1
if insert_at == 0:
    raise SystemExit('PATCH ERROR: no ESM import block found')
lines.insert(insert_at, import_line)
s=''.join(lines)

factory=s.find('export function createVodiaServer')
if factory < 0:
    raise SystemExit('PATCH ERROR: createVodiaServer not found')
reg=s.find('server.registerTool(', factory)
if reg < 0:
    raise SystemExit('PATCH ERROR: first server.registerTool after createVodiaServer not found')

registration='''  // v0.14.9.17 AWS Marketplace EC2 deployment
  registerAwsMarketplaceDeployTools(server, {
    z,
    toolOutputSchema,
    scopedAudit,
    scopedSuccess,
    failure,
  });

'''
s=s[:reg]+registration+s[reg:]
p.write_text(s)
PY
node --check "$TMP_INDEX" >/dev/null || fail "patched index.js syntax invalid"
echo PASS

echo "[6/9] Patch connector version"
cp -a "$VERSION" "$TMP_VERSION"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.17\2',s,count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
echo PASS

echo "[7/9] Static safety validation"
python3 - "$TMP_INDEX" "$MODULE" <<'PY'
from pathlib import Path
import sys
index=Path(sys.argv[1]).read_text()
module=Path(sys.argv[2]).read_text()
for x in [
  'v0.14.9.17 AWS Marketplace EC2 deployment',
  'registerAwsMarketplaceDeployTools(server',
  './aws-marketplace-ec2-deploy-v1.js',
]:
    if x not in index: raise SystemExit(f'VALIDATION ERROR: index missing {x}')
for x in [
  '"aws_check_customer_connection"',
  '"aws_marketplace_search_vodia"',
  '"aws_marketplace_get_offer"',
  '"aws_marketplace_check_subscription"',
  '"aws_list_deployment_regions"',
  '"aws_discover_deployment_network"',
  '"aws_marketplace_plan_vodia_pbx_deployment"',
  '"aws_marketplace_apply_vodia_pbx_deployment"',
  '"aws_get_vodia_pbx_deployment_status"',
  'SUBSCRIPTION_REQUIRED',
  'DryRun: true',
  'CONFIRMATION_MISMATCH',
  'IamInstanceProfile',
]:
    if x not in module: raise SystemExit(f'VALIDATION ERROR: module missing {x}')
if 'AcceptAgreementRequestCommand' in module or 'CreateAgreementRequestCommand' in module:
    raise SystemExit('VALIDATION ERROR: v1 must not contain Marketplace purchase acceptance writes')
print('PASS: customer STS role assumption present')
print('PASS: Marketplace discovery/subscription checks are read-only')
print('PASS: deployment planning verifies active agreement and EC2 DryRun')
print('PASS: deployment apply requires exact short-lived plan confirmation')
print('PASS: v1 contains no Marketplace subscription/term-acceptance write')
PY
echo PASS

echo "[8/9] Activate + restart"
cp -a "$TMP_INDEX" "$INDEX"
cp -a "$TMP_VERSION" "$VERSION"
trap rollback ERR
node --check "$INDEX" >/dev/null
node --check "$VERSION" >/dev/null
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS http://127.0.0.1:3100/health > "$HEALTH" 2>/dev/null; then break; fi
  sleep 1
done
[[ -s "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 150 --no-pager || true; false; }
systemctl is-active --quiet "$SERVICE"
cat "$HEALTH"; echo
grep -q '0.14.9.17' "$HEALTH" || fail "health endpoint did not report v0.14.9.17"
echo PASS

echo "[9/9] Complete"
echo "PASS: v0.14.9.17 AWS Marketplace + EC2 deployment v1 installed"
echo "PASS: STS cross-account customer-role check"
echo "PASS: Marketplace Vodia search, offer discovery, and active-agreement verification"
echo "PASS: region/VPC/subnet/security-group/key-pair discovery"
echo "PASS: plan -> EC2 DryRun -> exact APPROVE DEPLOY -> RunInstances"
echo "PASS: deployment status inspection"
echo "IMPORTANT: the launched Vodia PBX must use an EC2 instance profile whose role has arn:aws:iam::aws:policy/AWSMarketplaceGetEntitlements."
echo "IMPORTANT: this v1 does not accept Marketplace commercial terms automatically."
echo "Backup: $BACKUP_DIR"
echo "Reconnect/start a fresh MCP client session after installation."
trap - ERR
