#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-8.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.8 — Guided Resolution + Serial Contract ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q 'function classify3cxDeviceForMigration' "$INDEX" || fail "classifier missing"
grep -q 'out.serialToWrite=serial;' "$INDEX" || fail "real-serial branch missing"
grep -q 'MODEL_SELECTED_BY_ADMIN' "$INDEX" || fail "override behavior missing"
grep -q 'modelOverridePolicy:' "$INDEX" || fail "3.11.5.7 contract missing"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Add guided-resolution and real-serial contracts"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
tool=s.find('"pbx_ai_prepare_3cx_device_migration"')
start=s.rfind("server.registerTool(",0,tool)
end=s.find("server.registerTool(",tool+1)
if min(tool,start,end)<0: raise SystemExit("PATCH ERROR: migration tool boundaries")
b=s[start:end]
anchor='modelOverridePolicy: "An administrator override is accepted only when it matches a candidate returned by the live Vodia catalog. The selection applies to all matching source-model strings; invalid overrides remain deferred.",'
if anchor not in b: raise SystemExit("PATCH ERROR: 3.11.5.7 anchor")
if "guidedAmbiguousModelPolicy:" not in b:
    extra = anchor + '\n          guidedAmbiguousModelPolicy: "When multiple live Vodia candidates remain for a source-model group, present the candidate list to the administrator and require one explicit selection. Never guess a variant. The confirmed selection may be applied to all matching source-model strings.",\n          realSerialPolicy: "When the source backup contains a non-empty serial number, preserve that exact serial as serialToWrite. The Yealink # fallback and non-Yealink omit policy apply only when the source serial is missing.",'
    b=b.replace(anchor,extra,1)
p.write_text(s[:start]+b+s[end:])
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'guidedAmbiguousModelPolicy:' "$TMP" || fail "guided policy missing"
grep -q 'realSerialPolicy:' "$TMP" || fail "real serial policy missing"
echo PASS

echo "[5/7] Safety + serial contract regression"
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
ca=classifier(a); cb=classifier(b)
if ca != cb: raise SystemExit("SAFETY FAIL: classifier changed")
required=[
 'const serial=String(phone?.serial_number??phone?.serial??"").trim();',
 'if(!serial){',
 'out.serialToWrite="#"',
 'out.serialToWrite=serial;'
]
for x in required:
    if x not in cb: raise SystemExit("STATIC REGRESSION FAIL: "+x)
print("PASS: classifier byte-identical")
print("PASS: real serial preservation branch present")
print("PASS: missing-serial fallback remains isolated")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A10 -B3 'guidedAmbiguousModelPolicy' "$INDEX" | head -50
echo
echo "=== PHASE 3.11.5.8 INSTALL PASS ==="
echo "Guided ambiguity policy: documented and machine-readable"
echo "Real source serial -> preserve exact serial: documented and statically verified"
echo "Classifier changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: rerun read-only regression, then test a sanitized fixture with a populated real serial."
