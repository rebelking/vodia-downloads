#!/usr/bin/env bash
set -Eeuo pipefail

INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-6-2.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.6.2 — Serial Rules Cleanup ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q 'yealinkMissingSerialPlaceholder: "#"' "$INDEX" || fail "3.11.5.6.1 Yealink rule missing"
grep -q 'nonYealinkMissingSerialPolicy: "OMIT"' "$INDEX" || fail "3.11.5.6.1 non-Yealink rule missing"
grep -q 'serialPlaceholder: "Disabled in Phase 3.11.5. Missing serials are reported explicitly."' "$INDEX" || fail "expected stale serialPlaceholder text not found"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Replace only the two stale rule strings"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p=Path(sys.argv[1])
s=p.read_text()

old1='missingSerial: "Do not invent a serial. Defer as DEFERRED_MISSING_SERIAL when the source backup has no serial.",'
new1='missingSerial: "Yealink devices use # when the source serial is missing; non-Yealink devices omit the serial.",'

old2='serialPlaceholder: "Disabled in Phase 3.11.5. Missing serials are reported explicitly.",'
new2='serialPlaceholder: "# is permitted only for Yealink devices with a missing source serial. Never use # for non-Yealink devices.",'

if s.count(old1) != 1:
    raise SystemExit(f"PATCH ERROR: expected exactly one stale missingSerial rule, found {s.count(old1)}")
if s.count(old2) != 1:
    raise SystemExit(f"PATCH ERROR: expected exactly one stale serialPlaceholder rule, found {s.count(old2)}")

s=s.replace(old1,new1,1).replace(old2,new2,1)
p.write_text(s)
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'missingSerial: "Yealink devices use # when the source serial is missing; non-Yealink devices omit the serial."' "$TMP" || fail "new missingSerial rule missing"
grep -q 'serialPlaceholder: "# is permitted only for Yealink devices with a missing source serial. Never use # for non-Yealink devices."' "$TMP" || fail "new serialPlaceholder rule missing"
! grep -q 'Disabled in Phase 3.11.5. Missing serials are reported explicitly.' "$TMP" || fail "stale serialPlaceholder text remains"
echo PASS

echo "[5/7] Safety — classifier must be byte-identical"
python3 - "$INDEX" "$TMP" <<'PY'
from pathlib import Path
import sys

def classifier(src):
    st=src.find("function classify3cxDeviceForMigration(")
    if st < 0: raise SystemExit("SAFETY FAIL: classifier start missing")
    en=src.find("\nserver.registerTool(", st)
    if en < 0: raise SystemExit("SAFETY FAIL: classifier end missing")
    return src[st:en]

before=Path(sys.argv[1]).read_text()
after=Path(sys.argv[2]).read_text()
if classifier(before) != classifier(after):
    raise SystemExit("SAFETY FAIL: classifier changed")
print("PASS: classifier byte-identical")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
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
grep -n -A16 -B4 'yealinkMissingSerialPlaceholder' "$INDEX" | head -60

echo
echo "=== PHASE 3.11.5.6.2 INSTALL PASS ==="
echo "Yealink missing serial -> #: rules consistent"
echo "Non-Yealink missing serial -> OMIT: rules consistent"
echo "Classifier changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: rerun the same read-only 71-device regression."
