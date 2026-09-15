#!/usr/bin/env bash
set -Eeuo pipefail

INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-2.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

echo "=========================================="
echo " Vodia MCP Phase 3.11.5.2"
echo "=========================================="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "$INDEX not found"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'async function fetchLiveVodiaDeviceCatalog' "$INDEX" || fail "catalog function missing"
grep -q 'SERIAL_PLACEHOLDER_USED' "$INDEX" || fail "Yealink serial policy missing"
grep -q 'SERIAL_OMITTED' "$INDEX" || fail "non-Yealink serial policy missing"
echo "PASS"

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Patch catalog call"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
marker = "Phase 3.11.5.2 structured operation arguments"

if marker not in s:
    start = s.find("async function fetchLiveVodiaDeviceCatalog(domain = null)")
    end = s.find("\nfunction matchLiveDeviceCandidates", start)
    if start < 0 or end < 0:
        raise SystemExit("PATCH ERROR: fetchLiveVodiaDeviceCatalog block not found")

    block = s[start:end]
    old = "      const result = await callOperation(op.operationId, args);"
    new = '''      // Phase 3.11.5.2 structured operation arguments.
      // callOperationRaw expects pathParams/queryParams rather than flat args.
      const pathParams = {};
      const queryParams = {};
      if (domain) pathParams.domain = domain;
      if (Object.prototype.hasOwnProperty.call(args, "id")) queryParams.id = args.id;

      const result = await callOperation(op.operationId, {
        pathParams,
        queryParams,
      });'''

    if old not in block:
        raise SystemExit("PATCH ERROR: expected flat callOperation call not found")
    block = block.replace(old, new, 1)
    s = s[:start] + block + s[end:]

p.write_text(s)
PY
echo "PASS"

echo "[4/7] Validate temporary source"
node --check "$TMP" >/dev/null || fail "patched JavaScript syntax invalid"
grep -q 'Phase 3.11.5.2 structured operation arguments' "$TMP" || fail "patch marker missing"
grep -q 'pathParams.domain = domain' "$TMP" || fail "pathParams.domain missing"
grep -q 'queryParams.id = args.id' "$TMP" || fail "queryParams.id missing"
echo "PASS"

echo "[5/7] Install"
cp -a "$TMP" "$INDEX"
if ! node --check "$INDEX" >/dev/null; then
  cp -a "$BACKUP" "$INDEX"
  fail "installed JavaScript invalid; backup restored"
fi
echo "PASS"

echo "[6/7] Restart + health"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" || true
  fail "service unhealthy; backup restored"
fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A12 -B3 'Phase 3.11.5.2 structured operation arguments' "$INDEX"
echo
echo "=== PHASE 3.11.5.2 INSTALL PASS ==="
echo "Backup: $BACKUP"
echo "PBX writes performed by installer: 0"
echo
echo "NEXT: run the read-only 71-device 3CX regression."
