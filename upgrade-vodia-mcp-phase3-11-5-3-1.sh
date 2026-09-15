#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-3-1.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.3.1 ==="

echo "[1/6] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q 'Phase 3.11.5.3 vendor models array extraction' "$INDEX" || fail "3.11.5.3 block missing"
echo "PASS"

echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/6] Correct node -> value in 3.11.5.3 block"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
start=s.find("// Phase 3.11.5.3 vendor models array extraction.")
end=s.find("if (depth > 6 || value == null)", start)
if start < 0 or end < 0:
    raise SystemExit("PATCH ERROR: 3.11.5.3 block not found")
block=s[start:end]
block=block.replace("node && typeof node", "value && typeof value")
block=block.replace("Array.isArray(node)", "Array.isArray(value)")
block=block.replace("node.vendor", "value.vendor")
block=block.replace("node.name", "value.name")
block=block.replace("node.models", "value.models")
s=s[:start]+block+s[end:]
p.write_text(s)
PY
echo "PASS"

echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
if sed -n '/Phase 3.11.5.3 vendor models array extraction/,/if (depth > 6 || value == null)/p' "$TMP" | grep -qw node; then
  fail "node reference still exists in patched block"
fi
echo "PASS"

echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; }
echo "PASS: $SERVICE active"

echo "[6/6] Verify"
sed -n '/Phase 3.11.5.3 vendor models array extraction/,/if (depth > 6 || value == null)/p' "$INDEX"
echo
echo "=== PHASE 3.11.5.3.1 INSTALL PASS ==="
echo "Backup: $BACKUP"
echo "PBX writes: 0"
echo "NEXT: rerun the read-only 71-device regression."
