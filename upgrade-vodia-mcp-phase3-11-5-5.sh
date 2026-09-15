#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-5.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.5 — Compact Response ==="
echo "[1/6] Preflight"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "tool missing"
grep -q 'devices: rows' "$INDEX" || fail "expected old payload missing"
echo PASS

echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/6] Patch"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
name=s.find('"pbx_ai_prepare_3cx_device_migration"')
start=s.rfind("server.registerTool(",0,name)
end=s.find("server.registerTool(",name+1)
if min(name,start,end)<0: raise SystemExit("PATCH ERROR: boundaries")
b=s[start:end]
anchor='      const overallStatus = adminActions.length ? "COMPLETED_WITH_ACTIONS_REQUIRED" : "COMPLETED";'
lines=[
'',
'      // Phase 3.11.5.5: compact transport response; classifier unchanged.',
'      const compactDevice = r => ({',
'        extension: r.extension ?? null, mac: r.mac ?? null, vendor: r.vendor ?? null,',
'        sourceModel: r.sourceModel ?? null, sourceSerial: r.sourceSerial ?? null,',
'        selectedVodiaModel: r.selectedVodiaModel ?? null, serialToWrite: r.serialToWrite ?? null,',
'        status: r.status ?? null, reason: r.reason ?? null, adminAction: r.adminAction ?? null,',
'        flags: Array.isArray(r.flags) ? r.flags : [],',
'      });',
'      const compactDevices = rows.map(compactDevice);',
'      const compactAdminActions = adminActions.map(compactDevice);',
'      const compactMissingSerialDevices = missingSerialDevices.map(compactDevice);'
]
if anchor not in b: raise SystemExit("PATCH ERROR: anchor missing")
b=b.replace(anchor,anchor+"\n".join(lines),1)
for old,new in [
("        devices: rows,","        devices: compactDevices,"),
("        adminActions,","        adminActions: compactAdminActions,"),
("        missingSerialDevices,","        missingSerialDevices: compactMissingSerialDevices,")
]:
    if old not in b: raise SystemExit("PATCH ERROR: "+old.strip())
    b=b.replace(old,new,1)
p.write_text(s[:start]+b+s[end:])
PY
echo PASS

echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'Phase 3.11.5.5' "$TMP" || fail "marker missing"
grep -q 'devices: compactDevices' "$TMP" || fail "compact devices missing"
grep -q 'adminActions: compactAdminActions' "$TMP" || fail "compact actions missing"
grep -q 'missingSerialDevices: compactMissingSerialDevices' "$TMP" || fail "compact serials missing"
echo PASS

echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "unhealthy; restored"; fi
echo "PASS: $SERVICE active"

echo "[6/6] Verify"
grep -n -A35 -B5 'Phase 3.11.5.5' "$INDEX" | head -80
echo
echo "=== PHASE 3.11.5.5 INSTALL PASS ==="
echo "Classifier changed: no"
echo "Serial policy changed: no"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: rerun the read-only 71-device regression."
