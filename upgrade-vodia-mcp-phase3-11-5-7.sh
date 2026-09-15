#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-7.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.7 — Model Override Regression Guard ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "migration tool missing"
grep -q 'model_overrides: z.record(z.string()).optional()' "$INDEX" || fail "model_overrides input missing"
grep -q 'MODEL_SELECTED_BY_ADMIN' "$INDEX" || fail "override flag missing"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"; cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Add override-policy metadata only"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
tool=s.find('"pbx_ai_prepare_3cx_device_migration"')
start=s.rfind("server.registerTool(",0,tool)
end=s.find("server.registerTool(",tool+1)
if min(tool,start,end)<0: raise SystemExit("PATCH ERROR: tool boundaries")
b=s[start:end]
anchor="rules: {"
if anchor not in b: raise SystemExit("PATCH ERROR: rules object")
if "modelOverridePolicy:" not in b:
    b=b.replace(anchor, anchor + '\n          modelOverridePolicy: "An administrator override is accepted only when it matches a candidate returned by the live Vodia catalog. The selection applies to all matching source-model strings; invalid overrides remain deferred.",',1)
p.write_text(s[:start]+b+s[end:])
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'modelOverridePolicy:' "$TMP" || fail "override policy missing"
echo PASS

echo "[5/7] Safety — classifier byte-identical"
python3 - "$INDEX" "$TMP" <<'PY'
from pathlib import Path
import sys
def classifier(src):
    st=src.find("function classify3cxDeviceForMigration(")
    if st<0: raise SystemExit("SAFETY FAIL: classifier start")
    en=src.find("\nserver.registerTool(",st)
    if en<0: raise SystemExit("SAFETY FAIL: classifier end")
    return src[st:en]
a=Path(sys.argv[1]).read_text(); b=Path(sys.argv[2]).read_text()
if classifier(a)!=classifier(b): raise SystemExit("SAFETY FAIL: classifier changed")
print("PASS: classifier byte-identical")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A12 -B4 'modelOverridePolicy' "$INDEX" | head -50
echo
echo "=== PHASE 3.11.5.7 INSTALL PASS ==="
echo "Classifier changed: no"
echo "Serial policy changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo 'NEXT: read-only regression with model_overrides={"snom d785":"D785","fanvil x6":"X6"}'
echo "Expected: total=71, ready=37, ambiguous=31, unsupported=3"
