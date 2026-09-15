#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-4.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Phase 3.11.5.4 — Catalog Parser Fix ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q "function recursivelyCollectModelObjects" "$INDEX" || fail "parser missing"
grep -q "Array.isArray(value.models)" "$INDEX" || fail "expected old models[] parser not found"
echo PASS
echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"; cp -a "$INDEX" "$TMP"; echo "PASS: $BACKUP"
echo "[3/7] Patch live vendor + model[] shape"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
start=s.find("function recursivelyCollectModelObjects(")
end=s.find("\nfunction ", start+10)
if start<0 or end<0: raise SystemExit("PATCH ERROR: parser boundaries not found")
b=s[start:end]
old = '    const vendor = String(value.vendor ?? value.name ?? "").trim();\n    if (vendor && Array.isArray(value.models)) {\n      for (const entry of value.models) {'
new = '    const vendor = String(value.vendor ?? value.name ?? "").trim();\n    // Phase 3.11.5.4: live button_templates uses {vendor, model:[...]}.\n    const modelList = Array.isArray(value.model) ? value.model : (Array.isArray(value.models) ? value.models : null);\n    if (vendor && modelList) {\n      for (const entry of modelList) {'
if old not in b: raise SystemExit("PATCH ERROR: old models[] block anchor not found")
b=b.replace(old,new,1)
# Replace only the loop source inside this special-case block.
b=b.replace("      for (const entry of value.models) {","      for (const entry of modelList) {",1)
p.write_text(s[:start]+b+s[end:])
PY
echo PASS
echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q "Phase 3.11.5.4" "$TMP" || fail "phase marker missing"
grep -q "Array.isArray(value.model)" "$TMP" || fail "model[] support missing"
echo PASS
echo "[5/7] Static regression"
grep -q "Array.isArray(value.models)" "$TMP" || fail "legacy models[] support lost"
grep -q "out.push({ vendor, model })" "$TMP" || fail "vendor/model expansion missing"
echo "PASS: model[] + models[] supported"
echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; fi
echo "PASS: $SERVICE active"
echo "[7/7] Verify"
grep -n -A24 -B5 "Phase 3.11.5.4" "$INDEX" | head -60
echo
echo "=== PHASE 3.11.5.4 INSTALL PASS ==="
echo "Change: parse live {vendor, model:[...]} catalog shape"
echo "Legacy models[] support retained: yes"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: run diagnostic once; require parserExtractedCount > 0, then run 71-device regression."
