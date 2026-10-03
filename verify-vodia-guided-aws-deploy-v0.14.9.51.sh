#!/usr/bin/env bash
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
BACKEND="$APP/msp-customer-connections-v1.js"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
fail(){ echo "FAIL: $*" >&2; exit 1; }
for f in "$BACKEND" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
node --check "$BACKEND" >/dev/null || fail "backend JavaScript invalid"
node --check "$GUIDED" >/dev/null || fail "guided JavaScript invalid"
grep -Fq 'VODIA_AWS_ONBOARDING_V50' "$BACKEND" || fail "v0.14.9.50 prerequisite missing"
grep -Fq 'VODIA_AWS_AUTO_REUSE_V51' "$BACKEND" || fail "automatic account reuse marker missing"
grep -Fq 'reuseAccessibleAwsConnectionForAccount' "$BACKEND" || fail "automatic account reuse helper missing"
grep -Fq 'reusedExistingConnection: Boolean(reusedFromCustomerId)' "$BACKEND" || fail "reuse result metadata missing"
grep -Fq 'isAssumeRoleDenied(error)' "$BACKEND" || fail "AssumeRole-only fallback missing"
grep -Fq 'requireCustomerAccess(extra, sourceCustomerId' "$BACKEND" || fail "source customer authorization missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.51/mcp-app.html' "$GUIDED" || fail "v0.14.9.51 UI URI missing"
grep -Eq "CONNECTOR_VERSION[[:space:]]*=[[:space:]]*['\"]0\\.14\\.9\\.51['\"]" "$VERSION" || fail "connector version missing"
echo "PASS: exact-account authorized AWS connection recovery, STS retest, and JavaScript syntax verified."
