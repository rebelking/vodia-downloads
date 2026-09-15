#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-device-catalog-diagnostic-tool.${STAMP}"
TMP="$(mktemp --suffix=.js)"
BLOCK="$(mktemp)"
trap 'rm -f "$TMP" "$BLOCK"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Install pbx_ai_diagnose_device_catalog ==="
echo "[1/6] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "migration anchor missing"
echo PASS

echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/6] Add read-only diagnostic tool"
echo 'CnNlcnZlci5yZWdpc3RlclRvb2woCiAgInBieF9haV9kaWFnbm9zZV9kZXZpY2VfY2F0YWxvZyIsCiAgewogICAgdGl0bGU6ICJEaWFnbm9zZSBWb2RpYSBwcm92aXNpb25pbmcgZGV2aWNlIGNhdGFsb2ciLAogICAgZGVzY3JpcHRpb246ICJSZWFkLW9ubHkgZGlhZ25vc3RpYyBmb3IgQUkvYWRtaW4gdHJvdWJsZXNob290aW5nLiBJbnNwZWN0cyB0aGUgbGl2ZSB0ZW5hbnQgYnV0dG9uLXRlbXBsYXRlIHJlc3BvbnNlIHNoYXBlIGFuZCBjb21wYXJlcyByYXcgY291bnRzIHdpdGggcGFyc2VyIG91dHB1dC4gTWFrZXMgbm8gUEJYIGNoYW5nZXMuIiwKICAgIGlucHV0U2NoZW1hOiB7IHRhcmdldF90ZW5hbnQ6IHouc3RyaW5nKCkubWluKDEpIH0sCiAgICBvdXRwdXRTY2hlbWE6IHRvb2xPdXRwdXRTY2hlbWEsCiAgICBhbm5vdGF0aW9uczogeyByZWFkT25seUhpbnQ6IHRydWUsIGRlc3RydWN0aXZlSGludDogZmFsc2UsIG9wZW5Xb3JsZEhpbnQ6IGZhbHNlIH0sCiAgfSwKICBhc3luYyAoeyB0YXJnZXRfdGVuYW50IH0pID0+IHsKICAgIHRyeSB7CiAgICAgIGNvbnN0IG9wcyA9IGZpbmREZXZpY2VDYXRhbG9nUmVhZE9wZXJhdGlvbnMoKTsKICAgICAgY29uc3Qgb3AgPSBvcHMuZmluZCh4ID0+CiAgICAgICAgL2J1dHRvbltfIC1dP3RlbXBsYXRlcy9pLnRlc3QoW3gub3BlcmF0aW9uSWQseC5wYXRoLHguc3VtbWFyeSwuLi4oeC50YWdzfHxbXSldLmpvaW4oIiAiKSkgJiYKICAgICAgICAvZG9tYWluL2kudGVzdChTdHJpbmcoeC5wYXRofHwiIikpCiAgICAgICk7CiAgICAgIGlmICghb3ApIHRocm93IG5ldyBFcnJvcigiTm8gdGVuYW50IGJ1dHRvbi10ZW1wbGF0ZSBjYXRhbG9nIG9wZXJhdGlvbiBmb3VuZC4iKTsKCiAgICAgIGNvbnN0IHJlc3VsdCA9IGF3YWl0IGNhbGxPcGVyYXRpb24ob3Aub3BlcmF0aW9uSWQsIHsKICAgICAgICBwYXRoUGFyYW1zOiB7IGRvbWFpbjogdGFyZ2V0X3RlbmFudCB9LAogICAgICAgIHF1ZXJ5UGFyYW1zOiB7IGlkOiAiYWxsIiB9LAogICAgICB9KTsKCiAgICAgIGNvbnN0IGRhdGEgPSByZXN1bHQ/LmRhdGE7CiAgICAgIGNvbnN0IGZpcnN0ID0gQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGFbMF0gOiBudWxsOwogICAgICBjb25zdCBmbSA9IGZpcnN0ICYmIHR5cGVvZiBmaXJzdCA9PT0gIm9iamVjdCIgPyBmaXJzdC5tb2RlbCA6IG51bGw7CgogICAgICBsZXQgcmF3TW9kZWxDb3VudCA9IDA7CiAgICAgIGlmIChBcnJheS5pc0FycmF5KGRhdGEpKSB7CiAgICAgICAgZm9yIChjb25zdCByb3cgb2YgZGF0YSkgewogICAgICAgICAgaWYgKCFyb3cgfHwgdHlwZW9mIHJvdyAhPT0gIm9iamVjdCIpIGNvbnRpbnVlOwogICAgICAgICAgY29uc3QgbSA9IHJvdy5tb2RlbDsKICAgICAgICAgIGlmIChBcnJheS5pc0FycmF5KG0pKSByYXdNb2RlbENvdW50ICs9IG0ubGVuZ3RoOwogICAgICAgICAgZWxzZSBpZiAobSAmJiB0eXBlb2YgbSA9PT0gIm9iamVjdCIpIHJhd01vZGVsQ291bnQgKz0gT2JqZWN0LmtleXMobSkubGVuZ3RoOwogICAgICAgICAgZWxzZSBpZiAodHlwZW9mIG0gPT09ICJzdHJpbmciICYmIG0udHJpbSgpKSByYXdNb2RlbENvdW50Kys7CiAgICAgICAgfQogICAgICB9CgogICAgICBjb25zdCBwYXJzZWQgPSByZWN1cnNpdmVseUNvbGxlY3RNb2RlbE9iamVjdHMoZGF0YSk7CiAgICAgIGNvbnN0IHNhbXBsZSA9IEFycmF5LmlzQXJyYXkoZm0pID8gZm0uc2xpY2UoMCw1KQogICAgICAgIDogKGZtICYmIHR5cGVvZiBmbSA9PT0gIm9iamVjdCIgPyBPYmplY3Qua2V5cyhmbSkuc2xpY2UoMCw1KQogICAgICAgIDogKHR5cGVvZiBmbSA9PT0gInN0cmluZyIgPyBbZm0uc2xpY2UoMCwxMjApXSA6IFtdKSk7CgogICAgICByZXR1cm4gc2NvcGVkU3VjY2Vzcyh7CiAgICAgICAgdGFyZ2V0VGVuYW50OiB0YXJnZXRfdGVuYW50LAogICAgICAgIGNoYW5nZXNNYWRlOiBmYWxzZSwKICAgICAgICBvcGVyYXRpb25JZDogb3Aub3BlcmF0aW9uSWQsCiAgICAgICAgcmVzcG9uc2VTaGFwZTogewogICAgICAgICAgZGF0YUlzQXJyYXk6IEFycmF5LmlzQXJyYXkoZGF0YSksCiAgICAgICAgICB0b3BMZXZlbExlbmd0aDogQXJyYXkuaXNBcnJheShkYXRhKSA/IGRhdGEubGVuZ3RoIDogbnVsbCwKICAgICAgICAgIGZpcnN0RW50cnlLZXlzOiBmaXJzdCAmJiB0eXBlb2YgZmlyc3QgPT09ICJvYmplY3QiID8gT2JqZWN0LmtleXMoZmlyc3QpLnNsaWNlKDAsMzApIDogW10sCiAgICAgICAgICBmaXJzdFZlbmRvcjogZmlyc3QgJiYgdHlwZW9mIGZpcnN0ID09PSAib2JqZWN0IiA/IFN0cmluZyhmaXJzdC52ZW5kb3IgPz8gIiIpIHx8IG51bGwgOiBudWxsLAogICAgICAgICAgZmlyc3RNb2RlbFR5cGU6IGZtID09PSBudWxsID8gIm51bGwiIDogdHlwZW9mIGZtLAogICAgICAgICAgZmlyc3RNb2RlbElzQXJyYXk6IEFycmF5LmlzQXJyYXkoZm0pLAogICAgICAgICAgZmlyc3RNb2RlbExlbmd0aDogQXJyYXkuaXNBcnJheShmbSkgPyBmbS5sZW5ndGggOiAoZm0gJiYgdHlwZW9mIGZtID09PSAib2JqZWN0IiA/IE9iamVjdC5rZXlzKGZtKS5sZW5ndGggOiBudWxsKSwKICAgICAgICAgIHNhZmVNb2RlbFNhbXBsZTogc2FtcGxlCiAgICAgICAgfSwKICAgICAgICBjb3VudHM6IHsKICAgICAgICAgIHJhd1ZlbmRvckNvdW50OiBBcnJheS5pc0FycmF5KGRhdGEpID8gZGF0YS5sZW5ndGggOiBudWxsLAogICAgICAgICAgcmF3TW9kZWxDb3VudCwKICAgICAgICAgIHBhcnNlckV4dHJhY3RlZENvdW50OiBwYXJzZWQubGVuZ3RoCiAgICAgICAgfSwKICAgICAgICBkaWFnbm9zaXM6IHJhd01vZGVsQ291bnQgPiAwICYmIHBhcnNlZC5sZW5ndGggPT09IDAKICAgICAgICAgID8gIkNBVEFMT0dfUE9QVUxBVEVEX1BBUlNFUl9FWFRSQUNURURfWkVSTyIKICAgICAgICAgIDogIkNBVEFMT0dfRElBR05PU1RJQ19DT01QTEVURUQiCiAgICAgIH0pOwogICAgfSBjYXRjaCAoZXJyb3IpIHsKICAgICAgcmV0dXJuIHNjb3BlZEVycm9yKGBEZXZpY2UgY2F0YWxvZyBkaWFnbm9zdGljIGZhaWxlZDogJHtlcnJvcj8ubWVzc2FnZSB8fCBlcnJvcn1gKTsKICAgIH0KICB9Cik7Cgo=' | base64 -d > "$BLOCK"
python3 - "$TMP" "$BLOCK" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
if '"pbx_ai_diagnose_device_catalog"' not in s:
    anchor='server.registerTool(\n  "pbx_ai_prepare_3cx_device_migration",'
    pos=s.find(anchor)
    if pos < 0:
        raise SystemExit("PATCH ERROR: migration tool anchor not found")
    block=Path(sys.argv[2]).read_text()
    s=s[:pos]+block+s[pos:]
p.write_text(s)
PY
echo PASS

echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched JavaScript syntax invalid"
grep -q '"pbx_ai_diagnose_device_catalog"' "$TMP" || fail "tool missing"
grep -q 'changesMade: false' "$TMP" || fail "safety field missing"
echo PASS

echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; }
echo "PASS: $SERVICE active"

echo "[6/6] Verify"
grep -n -A10 -B2 '"pbx_ai_diagnose_device_catalog"' "$INDEX" | head -25
echo
echo "=== DIAGNOSTIC TOOL INSTALL PASS ==="
echo "Tool: pbx_ai_diagnose_device_catalog"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
