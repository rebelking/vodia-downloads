#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-9.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.9 — Yealink-Only Serial Enforcement ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q 'function classify3cxDeviceForMigration' "$INDEX" || fail "classifier missing"
grep -q 'realSerialPolicy:' "$INDEX" || fail "3.11.5.8 policy missing"
grep -q 'out.serialToWrite=serial;' "$INDEX" || fail "serial branch missing"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"; cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Enforce Yealink-only serial behavior"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
st=s.find("function classify3cxDeviceForMigration(")
en=s.find("\nserver.registerTool(",st)
if st<0 or en<0: raise SystemExit("PATCH ERROR: classifier boundaries")
c=s[st:en]
old='  out.serialToWrite=serial;\n  out.status="READY_TO_MIGRATE";\n  out.reason="Supported live-catalog model and serial available.";\n  return out;'
new='  if(normalizeDeviceToken(vendor)==="yealink"){\n    out.serialToWrite=serial;\n    out.flags.push("SOURCE_SERIAL_PRESERVED");\n    out.status="READY_TO_MIGRATE";\n    out.reason="Supported Yealink model resolved; source serial preserved exactly.";\n    return out;\n  }\n  out.serialToWrite=null;\n  out.flags.push("SERIAL_OMITTED");\n  out.status="READY_TO_MIGRATE";\n  out.reason="Supported non-Yealink model resolved; serial is omitted by policy.";\n  return out;'
if c.count(old)!=1: raise SystemExit("PATCH ERROR: real-serial tail count="+str(c.count(old)))
c=c.replace(old,new,1)
s=s[:st]+c+s[en:]
oldp='realSerialPolicy: "When the source backup contains a non-empty serial number, preserve that exact serial as serialToWrite. The Yealink # fallback and non-Yealink omit policy apply only when the source serial is missing.",'
newp='realSerialPolicy: "Serial is a Yealink-only migration field. For Yealink, preserve a non-empty source serial exactly; when missing, use #. For all non-Yealink devices, omit serial even if the source contains one.",'
if s.count(oldp)!=1: raise SystemExit("PATCH ERROR: policy count="+str(s.count(oldp)))
s=s.replace(oldp,newp,1)
p.write_text(s)
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'SOURCE_SERIAL_PRESERVED' "$TMP" || fail "preservation flag missing"
grep -q 'Serial is a Yealink-only migration field' "$TMP" || fail "policy missing"
echo PASS

echo "[5/7] Safety contract checks"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
st=s.find("function classify3cxDeviceForMigration("); en=s.find("\nserver.registerTool(",st); c=s[st:en]
req=['if(!serial){','out.serialToWrite="#"','out.serialToWrite=serial;','SOURCE_SERIAL_PRESERVED','out.serialToWrite=null;','SERIAL_OMITTED']
for x in req:
    if x not in c: raise SystemExit("SAFETY FAIL: "+x)
if c.count("out.serialToWrite=serial;")!=1: raise SystemExit("SAFETY FAIL: real serial assignment count")
print("PASS: Yealink real serial preservation branch present")
print("PASS: Yealink missing serial # branch present")
print("PASS: non-Yealink omission branch present")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A24 -B8 'SOURCE_SERIAL_PRESERVED' "$INDEX" | head -70
grep -n -A3 -B2 'realSerialPolicy:' "$INDEX" | head -20
echo
echo "=== PHASE 3.11.5.9 INSTALL PASS ==="
echo "Yealink + real serial: preserve exact source serial"
echo "Yealink + missing serial: #"
echo "Non-Yealink + any serial state: omit serial"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: runtime-test all four serial cases with a sanitized fixture."
