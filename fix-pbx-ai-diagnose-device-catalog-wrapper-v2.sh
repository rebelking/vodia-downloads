#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-diagnostic-wrapper-fix-v2.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Diagnostic Wrapper Fix v2 ==="
echo "[1/6] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_diagnose_device_catalog"' "$INDEX" || fail "diagnostic tool missing"
echo PASS
echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"
echo "[3/6] Patch exact live lines 3501-3522 by content anchors"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
name=s.find('"pbx_ai_diagnose_device_catalog"')
start=s.rfind("server.registerTool(",0,name); end=s.find("server.registerTool(",name+1)
if name<0 or start<0 or end<0: raise SystemExit("PATCH ERROR: diagnostic boundaries not found")
b=s[start:end]
a=b.find("      return {\n        data: diagnosticPayload,")
c=b.find("    } catch (error) {",a)
if a<0 or c<0: raise SystemExit("PATCH ERROR: success/catch anchors missing")
e=b.rfind("      };",a,c)
if e<0: raise SystemExit("PATCH ERROR: success end missing")
e += len("      };")
success="      return scopedSuccess(\n        diagnosticPayload,\n        { operation: \"AI_DIAGNOSE_DEVICE_CATALOG\", readOnly: true, changesMade: false },\n        \"Device catalog diagnostic completed. No PBX changes were made.\"\n      );"
b=b[:a]+success+b[e:]
c=b.find("    } catch (error) {")
t=b.rfind("\n  }\n);")
if c<0 or t<0: raise SystemExit("PATCH ERROR: catch/tool-end anchors missing")
err="    } catch (error) {\n      return failure(error, \"device catalog diagnostic\");\n    }"
b=b[:c]+err+b[t:]
p.write_text(s[:start]+b+s[end:])
PY
echo PASS
echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'AI_DIAGNOSE_DEVICE_CATALOG' "$TMP" || fail "success wrapper missing"
grep -q 'failure(error, "device catalog diagnostic")' "$TMP" || fail "failure wrapper missing"
echo PASS
echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; fi
echo "PASS: $SERVICE active"
echo "[6/6] Verify"
grep -n -A20 -B5 'AI_DIAGNOSE_DEVICE_CATALOG' "$INDEX" | head -60
echo
echo "=== DIAGNOSTIC WRAPPER FIX V2 INSTALL PASS ==="
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: Claude calls pbx_ai_diagnose_device_catalog once."
