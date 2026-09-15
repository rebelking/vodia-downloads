#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-1.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Phase 3.11.5.1 ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "$INDEX not found"
command -v node >/dev/null || fail "node missing"
command -v python3 >/dev/null || fail "python3 missing"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q 'TENANT_BUTTON_TEMPLATES' "$INDEX" || fail "3.11.5 catalog marker missing"
echo "PASS"
echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"
echo "[3/7] Patch temporary copy"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

# Explicit target tenant -> domain path binding.
if 'if (domain) args.domain = domain;' not in s:
    a='      const args = {};\n      const params = Array.isArray(op.parameters) ? op.parameters : [];'
    b='      const args = {};\n      // Phase 3.11.5.1 explicit tenant path binding.\n      if (domain) args.domain = domain;\n      const params = Array.isArray(op.parameters) ? op.parameters : [];'
    if a not in s: raise SystemExit("PATCH ERROR: catalog args anchor not found")
    s=s.replace(a,b,1)

# Missing serial policy.
if 'SERIAL_OMITTED' not in s:
    a='  if(!serial){\n    out.serialToWrite=null;\n    out.flags.push("SERIAL_MISSING");\n    out.status="DEFERRED_MISSING_SERIAL";\n    out.reason="Supported live-catalog model resolved, but the source backup does not contain a serial number.";\n    out.adminAction="Supply the device serial if required by provisioning; do not invent a placeholder.";\n    return out;\n  }\n  out.serialToWrite=serial;\n  out.status="READY_TO_MIGRATE";\n  out.reason="Supported live-catalog model and serial available.";\n  return out;'
    b='  if(!serial){\n    if(normalizeDeviceToken(vendor)==="yealink"){\n      out.serialToWrite="#";\n      out.flags.push("SERIAL_PLACEHOLDER_USED");\n      out.status="READY_TO_MIGRATE";\n      out.reason="Supported Yealink model resolved; source backup has no serial, so the Vodia # placeholder is used.";\n      return out;\n    }\n    out.serialToWrite=null;\n    out.flags.push("SERIAL_OMITTED");\n    out.status="READY_TO_MIGRATE";\n    out.reason="Supported model resolved; source backup has no serial, so serial is omitted for this non-Yealink device.";\n    return out;\n  }\n  out.serialToWrite=serial;\n  out.status="READY_TO_MIGRATE";\n  out.reason="Supported live-catalog model and serial available.";\n  return out;'
    if a not in s: raise SystemExit("PATCH ERROR: expected 3.11.5 serial block not found")
    s=s.replace(a,b,1)

s=s.replace('const missingSerialDevices = rows.filter(r => r.flags.includes("SERIAL_MISSING"));',
            'const missingSerialDevices = rows.filter(r => r.flags.includes("SERIAL_PLACEHOLDER_USED") || r.flags.includes("SERIAL_OMITTED"));',1)
p.write_text(s)
PY
echo "PASS"
echo "[4/7] Validate patched source"
node --check "$TMP" >/dev/null || fail "patched JavaScript syntax invalid"
grep -q 'if (domain) args.domain = domain;' "$TMP" || fail "domain binding missing"
grep -q 'SERIAL_PLACEHOLDER_USED' "$TMP" || fail "Yealink # policy missing"
grep -q 'SERIAL_OMITTED' "$TMP" || fail "non-Yealink omission policy missing"
echo "PASS"
echo "[5/7] Install"
cp -a "$TMP" "$INDEX"
if ! node --check "$INDEX" >/dev/null; then cp -a "$BACKUP" "$INDEX"; fail "syntax failed; backup restored"; fi
echo "PASS"
echo "[6/7] Restart and verify"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; backup restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; backup restored"; fi
echo "PASS: $SERVICE active"
echo "[7/7] Verify markers"
grep -n -E 'args.domain = domain|SERIAL_PLACEHOLDER_USED|SERIAL_OMITTED' "$INDEX" | head -30
echo "=== PHASE 3.11.5.1 INSTALL PASS ==="
echo "Backup: $BACKUP"
echo "No PBX write was performed by this installer."
echo "NEXT: run the same read-only 71-device 3CX regression."
