#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-catalog-diag.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Catalog Diagnostic ==="
echo "[1/5] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "syntax invalid"
echo PASS
echo "[2/5] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"
echo "[3/5] Add diagnostic"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
marker="Phase 3.11.5 diagnostic result.data shape"
if marker not in s:
    needle="      const found = recursivelyCollectModelObjects(result.data);"
    js = [
      "      // Phase 3.11.5 diagnostic result.data shape.",
      "      const diagnosticData = result?.data;",
      "      const diagnosticFirst = Array.isArray(diagnosticData) ? diagnosticData[0] : null;",
      '      console.error("[VODIA-MCP-CATALOG-DIAG]", JSON.stringify({',
      "        operationId: op.operationId,",
      '        dataType: diagnosticData === null ? "null" : typeof diagnosticData,',
      "        dataIsArray: Array.isArray(diagnosticData),",
      '        dataTopLevelKeys: diagnosticData && typeof diagnosticData === "object" && !Array.isArray(diagnosticData) ? Object.keys(diagnosticData).slice(0,30) : [],',
      "        dataArrayLength: Array.isArray(diagnosticData) ? diagnosticData.length : null,",
      "        firstElementType: diagnosticFirst === null ? null : typeof diagnosticFirst,",
      "        firstElementIsArray: Array.isArray(diagnosticFirst),",
      '        firstElementKeys: diagnosticFirst && typeof diagnosticFirst === "object" && !Array.isArray(diagnosticFirst) ? Object.keys(diagnosticFirst).slice(0,30) : []',
      "      }));",
      "      const found = recursivelyCollectModelObjects(result.data);"
    ]
    if needle not in s: raise SystemExit("PATCH ERROR: extraction call not found")
    s=s.replace(needle, "\n".join(js), 1)
p.write_text(s)
PY
echo PASS
echo "[4/5] Validate/install/restart"
node --check "$TMP" >/dev/null || fail "diagnostic syntax invalid"
grep -q 'VODIA-MCP-CATALOG-DIAG' "$TMP" || fail "marker missing"
cp -a "$TMP" "$INDEX"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || fail "service unhealthy"
echo "PASS: $SERVICE active"
echo "[5/5] Ready"
echo "=== DIAGNOSTIC INSTALL PASS ==="
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "Run the Claude read-only regression once, then run:"
echo "journalctl -u vodia-mcp --since \"10 minutes ago\" --no-pager | grep VODIA-MCP-CATALOG-DIAG"
