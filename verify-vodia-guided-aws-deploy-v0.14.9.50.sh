#!/usr/bin/env bash
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
BACKEND="$APP/msp-customer-connections-v1.js"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
fail(){ echo "FAIL: $*" >&2; exit 1; }
for f in "$UI" "$BACKEND" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
node --check "$BACKEND" >/dev/null || fail "backend JavaScript invalid"
node --check "$GUIDED" >/dev/null || fail "guided JavaScript invalid"
grep -Fq 'data-aws-onboarding="v0.14.9.50"' "$UI" || fail "v0.14.9.50 UI marker missing"
grep -Fq 'VODIA_AWS_ONBOARDING_V50' "$BACKEND" || fail "stable onboarding marker missing"
grep -Fq 'reused: reusable' "$BACKEND" || fail "stable External ID response missing"
grep -Fq 'msp_reuse_customer_aws_connection' "$BACKEND" || fail "connection reuse tool missing"
grep -Fq 'reuseScopedAwsConnection' "$BACKEND" || fail "connection reuse implementation missing"
grep -Fq 'AWS Setup and the CloudFormation stack shows CREATE_COMPLETE' "$UI" || fail "CloudFormation completion gate missing"
grep -Fq 'id="reuseAwsConnection"' "$UI" || fail "reuse connection UI missing"
grep -Fq 'msp_reuse_customer_aws_connection' "$UI" || fail "reuse connection handler missing"
grep -Fq 'appInfo:{name:"vodia-setup",version:"1.14.0"}' "$UI" || fail "UI app version missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.50/mcp-app.html' "$GUIDED" || fail "v0.14.9.50 UI URI missing"
grep -Eq 'CONNECTOR_VERSION[[:space:]]*=[[:space:]]*["'"']0\.14\.9\.50["'"']' "$VERSION" || fail "connector version missing"
echo "PASS: stable AWS onboarding, CloudFormation completion gate, secure connection reuse, and JavaScript syntax verified."
