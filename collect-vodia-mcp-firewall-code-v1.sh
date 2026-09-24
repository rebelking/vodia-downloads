#!/usr/bin/env bash
# Collect only the code needed to patch the Vodia PBX launch/network flow.
# Does not read the database, environment file, IAM credentials, or backups.
set -Eeuo pipefail

MODE="${1:---inspect}"
case "$MODE" in --inspect|--collect) ;; *) echo "Usage: bash $0 [--inspect|--collect]" >&2; exit 2;; esac

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do
  [[ -f "$f" ]] || { echo "Missing code file: $f" >&2; exit 1; }
done

node --check "$BACKEND" >/dev/null
node --check "$GUIDED" >/dev/null
node --check "$VERSION" >/dev/null

python3 - "$BACKEND" "$UI" "$GUIDED" "$VERSION" <<'PY'
import re,sys
from pathlib import Path
backend,ui,guided,version=(Path(p).read_text() for p in sys.argv[1:])
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',version)
print('Version:',m.group(1) if m else 'unknown')
for label,source,marker in (
    ('Backend one-click preparation',backend,'aws_marketplace_prepare_vodia_one_click'),
    ('Backend deployment planner',backend,'aws_marketplace_plan_vodia_pbx_deployment'),
    ('Backend deployment apply',backend,'aws_marketplace_apply_vodia_pbx_deployment'),
    ('Backend params builder',backend,'function buildRunInstancesParams('),
    ('Backend instance inventory',backend,'VODIA_INSTANCE_ACCESS_INVENTORY_V3'),
    ('UI fifth card',ui,'VODIA_INSTANCE_ACCESS_CARD_V1'),
    ('UI one-click security group',ui,'securityGroupSelect'),
    ('Guided resource',guided,'ui://vodia/msp-guided/')):
    print(label+':',source.count(marker))
print('No code contents, credentials, or customer records printed.')
PY

if [[ "$MODE" == '--inspect' ]]; then exit 0; fi

STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="/tmp/vodia-mcp-firewall-code-$STAMP.tar.gz"
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
umask 077
tar -C "$APP" -czf "$OUT" \
  aws-marketplace-ec2-deploy-v1.js \
  ui/msp-guided-app.html \
  msp-guided-app-v1.js \
  version.js
chmod 600 "$OUT"
echo "Code-only bundle: $OUT"
echo 'The bundle contains four code files only. Upload it here for the firewall deployment patch.'
