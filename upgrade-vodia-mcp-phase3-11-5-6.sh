#!/usr/bin/env bash
set -Eeuo pipefail

INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-6.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.6 — Yealink Serial Policy Consistency ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "migration tool missing"
grep -q 'serialToWrite' "$INDEX" || fail "serial classification logic missing"
echo PASS

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Normalize Yealink-only missing-serial policy text/rules"
python3 - "$TMP" <<'PY'
from pathlib import Path
import re, sys

p=Path(sys.argv[1]); s=p.read_text()
name=s.find('"pbx_ai_prepare_3cx_device_migration"')
start=s.rfind("server.registerTool(",0,name)
end=s.find("server.registerTool(",name+1)
if min(name,start,end)<0:
    raise SystemExit("PATCH ERROR: migration tool boundaries not found")
b=s[start:end]

# Keep classifier behavior untouched. This phase makes the public contract/rules
# accurately describe the already-observed behavior: Yealink missing serial -> "#";
# non-Yealink missing serial -> omitted.
old_desc=re.search(r'description:\s*"([^"]*)"', b)
if not old_desc:
    raise SystemExit("PATCH ERROR: migration description not found")
desc=old_desc.group(1)
new_desc=re.sub(
    r'Missing serials use the validated [^\.]*placeholder\.',
    "When a source serial is missing, Yealink devices use the validated '#' provisioning placeholder; non-Yealink devices omit the serial.",
    desc
)
if new_desc == desc:
    # If wording drifted, append an explicit policy sentence rather than guessing.
    new_desc = desc.rstrip() + " Missing-serial policy: Yealink uses '#'; non-Yealink omits serial."
b=b[:old_desc.start(1)] + new_desc + b[old_desc.end(1):]

# Replace contradictory rule strings only inside this tool.
replacements = [
    (r'["\']Serial placeholder is disabled[^"\']*["\']',
     '"Missing-serial policy: Yealink uses #; non-Yealink omits serial."'),
    (r'["\'][^"\']*missing serials reported explicitly[^"\']*["\']',
     '"Missing-serial policy: Yealink uses #; non-Yealink omits serial."'),
    (r'["\'][^"\']*do not invent a placeholder[^"\']*["\']',
     '"Do not invent serial placeholders for non-Yealink devices; Yealink may use # when the source serial is absent."'),
]
for pat,repl in replacements:
    b=re.sub(pat,repl,b,flags=re.I)

# Add an explicit machine-readable rule if not already present.
rules_pos=b.find("rules:")
if rules_pos >= 0 and "yealinkMissingSerialPlaceholder" not in b:
    brace=b.find("{", rules_pos)
    if brace >= 0:
        b=b[:brace+1] + '\n          yealinkMissingSerialPlaceholder: "#",\n          nonYealinkMissingSerialPolicy: "OMIT",' + b[brace+1:]

p.write_text(s[:start]+b+s[end:])
PY
echo PASS

echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q "Yealink" "$TMP" || fail "Yealink policy text missing"
grep -q 'yealinkMissingSerialPlaceholder: "#"' "$TMP" || fail "machine-readable Yealink rule missing"
grep -q 'nonYealinkMissingSerialPolicy: "OMIT"' "$TMP" || fail "non-Yealink rule missing"
echo PASS

echo "[5/7] Safety check — classifier must remain untouched"
python3 - "$INDEX" "$TMP" <<'PY'
from pathlib import Path
import sys, re
a=Path(sys.argv[1]).read_text()
b=Path(sys.argv[2]).read_text()

def classifier(src):
    st=src.find("function classify3cxDeviceForMigration(")
    en=src.find("\nfunction ", st+10)
    if st<0 or en<0: raise SystemExit("SAFETY FAIL: classifier boundaries not found")
    return src[st:en]

if classifier(a) != classifier(b):
    raise SystemExit("SAFETY FAIL: classifier function changed")
print("PASS: classify3cxDeviceForMigration byte-identical")
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
grep -n -A28 -B8 'yealinkMissingSerialPlaceholder' "$INDEX" | head -80

echo
echo "=== PHASE 3.11.5.6 INSTALL PASS ==="
echo "Policy contract: Yealink missing serial -> #"
echo "Policy contract: non-Yealink missing serial -> OMIT"
echo "Classifier implementation changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: rerun the read-only 71-device regression and verify Yealink-only # behavior."
