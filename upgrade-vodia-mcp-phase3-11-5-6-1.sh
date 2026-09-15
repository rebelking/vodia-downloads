#!/usr/bin/env bash
set -Eeuo pipefail

INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-6-1.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.6.1 — Serial Policy Contract Fix ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "migration tool missing"
grep -q 'if(normalizeDeviceToken(vendor)==="yealink")' "$INDEX" || fail "Yealink classifier branch missing"
grep -q 'out.serialToWrite="#"' "$INDEX" || fail "Yealink # behavior missing"
grep -q 'out.flags.push("SERIAL_OMITTED")' "$INDEX" || fail "non-Yealink omit behavior missing"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Patch description/rules only"
python3 - "$TMP" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1]); s=p.read_text()
tool=s.find('"pbx_ai_prepare_3cx_device_migration"')
start=s.rfind("server.registerTool(",0,tool)
end=s.find("server.registerTool(",tool+1)
if min(tool,start,end)<0: raise SystemExit("PATCH ERROR: migration tool boundaries")
b=s[start:end]

m=re.search(r'description:\s*"([^"]*)"', b)
if not m: raise SystemExit("PATCH ERROR: description missing")
desc=m.group(1)
policy="Missing-serial policy: Yealink uses the validated # provisioning placeholder; non-Yealink devices omit serial."
desc=re.sub(r'Missing serials use the validated [^\.]*placeholder\.', policy, desc)
if policy not in desc:
    desc=desc.rstrip()+" "+policy
b=b[:m.start(1)]+desc+b[m.end(1):]

# Remove known contradictory prose in this tool if present.
b=re.sub(r'"Serial placeholder is disabled[^"]*"', '"Yealink missing serial uses #; non-Yealink missing serial is omitted."', b, flags=re.I)
b=re.sub(r'"[^"]*missing serials reported explicitly[^"]*"', '"Yealink missing serial uses #; non-Yealink missing serial is omitted."', b, flags=re.I)

# Add explicit machine-readable rules if a rules object exists.
rp=b.find("rules:")
if rp >= 0 and "yealinkMissingSerialPlaceholder" not in b:
    brace=b.find("{",rp)
    if brace < 0: raise SystemExit("PATCH ERROR: rules object brace missing")
    b=b[:brace+1]+'\n          yealinkMissingSerialPlaceholder: "#",\n          nonYealinkMissingSerialPolicy: "OMIT",'+b[brace+1:]

p.write_text(s[:start]+b+s[end:])
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'yealinkMissingSerialPlaceholder: "#"' "$TMP" || fail "Yealink rule missing"
grep -q 'nonYealinkMissingSerialPolicy: "OMIT"' "$TMP" || fail "non-Yealink rule missing"
echo PASS

echo "[5/7] Safety — compare exact classifier region through next server.registerTool"
python3 - "$INDEX" "$TMP" <<'PY'
from pathlib import Path
import sys
def classifier(src):
    st=src.find("function classify3cxDeviceForMigration(")
    if st<0: raise SystemExit("SAFETY FAIL: classifier start missing")
    en=src.find("\nserver.registerTool(",st)
    if en<0: raise SystemExit("SAFETY FAIL: classifier end missing")
    return src[st:en]
a=Path(sys.argv[1]).read_text()
b=Path(sys.argv[2]).read_text()
if classifier(a)!=classifier(b):
    raise SystemExit("SAFETY FAIL: classifier changed")
print("PASS: classifier byte-identical")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true
  fail "service unhealthy; backup restored"
fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A24 -B8 'yealinkMissingSerialPlaceholder' "$INDEX" | head -80
echo
echo "=== PHASE 3.11.5.6.1 INSTALL PASS ==="
echo "Yealink missing serial -> #: documented and machine-readable"
echo "Non-Yealink missing serial -> OMIT: documented and machine-readable"
echo "Classifier changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: rerun the read-only 71-device regression."
