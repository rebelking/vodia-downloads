#!/usr/bin/env bash
# Vodia MCP diagnostic collector
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
OUT="${1:-/tmp/vodia-mcp-diagnostic-$(date -u +%Y%m%d-%H%M%S).txt}"

UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"

redact() {
  sed -E     -e 's/External ID[^ ]*[=:][^ ]+/External-ID=<REDACTED>/Ig'     -e 's/externalId[^,:}]*/externalId=<REDACTED>/Ig'     -e 's/Authorization: Bearer [A-Za-z0-9._~+\/-]+/Authorization: Bearer <REDACTED>/Ig'     -e 's/AWS_SECRET_ACCESS_KEY=[^ ]+/AWS_SECRET_ACCESS_KEY=<REDACTED>/Ig'     -e 's/AWS_ACCESS_KEY_ID=[^ ]+/AWS_ACCESS_KEY_ID=<REDACTED>/Ig'
}

section(){ printf '\n===== %s =====\n' "$1"; }

{
  echo "VODIA MCP DIAGNOSTIC"
  echo "Generated UTC: $(date -u --iso-8601=seconds)"
  echo "Host: $(hostname)"
  echo "Kernel: $(uname -a)"
  echo "App dir: $APP"
  echo "Service: $SERVICE"

  section "VERSION"
  if [[ -f "$VERSION" ]]; then
    grep -E 'CONNECTOR_VERSION|version' "$VERSION" | head -20 || true
  else
    echo "MISSING: $VERSION"
  fi

  section "HEALTH"
  curl -fsS http://127.0.0.1:3100/health 2>&1 || true
  echo

  section "SERVICE"
  systemctl is-active "$SERVICE" 2>&1 || true
  systemctl status "$SERVICE" --no-pager -l 2>&1 | head -80 || true

  section "LISTENING PORTS"
  ss -ltnp 2>/dev/null | grep -E '(:3100|vodia|node)' || true

  section "FILES"
  for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do
    if [[ -f "$f" ]]; then
      stat -c '%n | %s bytes | %y' "$f"
      sha256sum "$f"
    else
      echo "MISSING: $f"
    fi
  done

  section "NODE SYNTAX"
  for f in "$GUIDED" "$BACKEND" "$VERSION"; do
    if [[ -f "$f" ]]; then
      if node --check "$f" >/tmp/vodia-node-check.out 2>&1; then
        echo "PASS: $f"
      else
        echo "FAIL: $f"
        cat /tmp/vodia-node-check.out
      fi
    fi
  done

  if [[ -f "$UI" ]]; then
    python3 - "$UI" /tmp/vodia-inline-check.js <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text(errors="replace")
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
Path(sys.argv[2]).write_text("\n".join(scripts))
print(f"Inline scripts: {len(scripts)}")
PY
    if node --check /tmp/vodia-inline-check.js >/tmp/vodia-inline-node.out 2>&1; then
      echo "PASS: inline UI JavaScript"
    else
      echo "FAIL: inline UI JavaScript"
      cat /tmp/vodia-inline-node.out
    fi
  fi

  section "UI VERSION MARKERS"
  if [[ -f "$UI" ]]; then
    grep -oE 'data-[a-z0-9-]+="v?0\.14\.9\.[0-9]+"' "$UI" | sort -u || true
    grep -oE 'appInfo:\{name:"vodia-setup",version:"[^"]+"' "$UI" | head -5 || true
  fi
  if [[ -f "$GUIDED" ]]; then
    grep -oE 'ui://vodia/msp-guided/v0\.14\.9\.[0-9]+/mcp-app\.html' "$GUIDED" | head -5 || true
  fi

  section "EXPECTED UI ELEMENTS"
  if [[ -f "$UI" ]]; then
    for needle in       '2 · Marketplace'       '3 · Configure EC2'       '4 · Review &amp; Deploy'       'id="marketplaceAgreementSelect"'       'id="pbxName"'       'id="planDeployment"'       'id="reviewStepPanel"'       'function updatePlanButton()'       'function pollDeploymentStatus(launchResult)'       'rawPlanResult?.isError'
    do
      if grep -Fq "$needle" "$UI"; then echo "PASS: $needle"; else echo "MISS: $needle"; fi
    done
  fi

  section "BACKEND SAFETY MARKERS"
  if [[ -f "$BACKEND" ]]; then
    for needle in       'DUPLICATE_DEPLOYMENT_BLOCKED'       'ClientToken: clientToken'       'VodiaMarketplaceAgreementId'       'AGREEMENT_NOT_ACTIVE'       'SELECTED_AGREEMENT_NO_LONGER_ACTIVE'
    do
      if grep -Fq "$needle" "$BACKEND"; then echo "PASS: $needle"; else echo "MISS: $needle"; fi
    done
  fi

  section "RECENT SERVICE LOGS (LAST 15 MINUTES)"
  journalctl -u "$SERVICE" --since "15 minutes ago" --no-pager -o short-iso 2>&1 | tail -250 || true

  section "ERROR-FOCUSED LOGS"
  journalctl -u "$SERVICE" --since "30 minutes ago" --no-pager -o short-iso 2>&1     | grep -Ei 'error|fail|planner|approval|marketplace|dryrun|duplicate|ec2|agreement|exception|stack'     | tail -250 || true

  section "PROCESS SNAPSHOT"
  ps -eo pid,ppid,etime,cmd | grep -E '[n]ode|[v]odia-mcp' || true

  section "DONE"
  echo "Read-only diagnostics complete."
  echo "No AWS changes, Marketplace changes, PBX changes, or file modifications were performed."
} | redact | tee "$OUT"

echo
echo "Diagnostic saved to: $OUT"
