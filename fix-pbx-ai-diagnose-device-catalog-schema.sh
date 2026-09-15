#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-diagnostic-schema-fix.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Fix pbx_ai_diagnose_device_catalog output schema ==="
echo "[1/6] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_diagnose_device_catalog"' "$INDEX" || fail "diagnostic tool missing"
echo PASS

echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/6] Patch diagnostic response"
echo 'ZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmltcG9ydCBzeXMKcD1QYXRoKHN5cy5hcmd2WzFdKQpzPXAucmVhZF90ZXh0KCkKc3RhcnQ9cy5maW5kKCdzZXJ2ZXIucmVnaXN0ZXJUb29sKFxuICAicGJ4X2FpX2RpYWdub3NlX2RldmljZV9jYXRhbG9nIiwnKQplbmQ9cy5maW5kKCdcbnNlcnZlci5yZWdpc3RlclRvb2woJywgc3RhcnQrMTApCmlmIHN0YXJ0IDwgMCBvciBlbmQgPCAwOgogICAgcmFpc2UgU3lzdGVtRXhpdCgiUEFUQ0ggRVJST1I6IGRpYWdub3N0aWMgdG9vbCBibG9jayBub3QgZm91bmQiKQpibG9jaz1zW3N0YXJ0OmVuZF0KaWYgJ21ldGE6IHsnIGluIGJsb2NrIGFuZCAndG9vbDogInBieF9haV9kaWFnbm9zZV9kZXZpY2VfY2F0YWxvZyInIGluIGJsb2NrOgogICAgcC53cml0ZV90ZXh0KHMpOyByYWlzZSBTeXN0ZW1FeGl0KDApCm9sZDE9JyAgICAgIHJldHVybiBzY29wZWRTdWNjZXNzKHsnCm5ldzE9JyAgICAgIGNvbnN0IGRpYWdub3N0aWNQYXlsb2FkID0geycKb2xkMj0nICAgICAgICBkaWFnbm9zaXM6IHJhd01vZGVsQ291bnQgPiAwICYmIHBhcnNlZC5sZW5ndGggPT09IDBcbiAgICAgICAgICA/ICJDQVRBTE9HX1BPUFVMQVRFRF9QQVJTRVJfRVhUUkFDVEVEX1pFUk8iXG4gICAgICAgICAgOiAiQ0FUQUxPR19ESUFHTk9TVElDX0NPTVBMRVRFRCJcbiAgICAgIH0pO1xuICAgIH0gY2F0Y2ggKGVycm9yKSB7XG4gICAgICByZXR1cm4gc2NvcGVkRXJyb3IoYERldmljZSBjYXRhbG9nIGRpYWdub3N0aWMgZmFpbGVkOiAke2Vycm9yPy5tZXNzYWdlIHx8IGVycm9yfWApO1xuICAgIH0nCm5ldzI9JyAgICAgICAgZGlhZ25vc2lzOiByYXdNb2RlbENvdW50ID4gMCAmJiBwYXJzZWQubGVuZ3RoID09PSAwXG4gICAgICAgICAgPyAiQ0FUQUxPR19QT1BVTEFURURfUEFSU0VSX0VYVFJBQ1RFRF9aRVJPIlxuICAgICAgICAgIDogIkNBVEFMT0dfRElBR05PU1RJQ19DT01QTEVURUQiXG4gICAgICB9O1xuICAgICAgcmV0dXJuIHtcbiAgICAgICAgZGF0YTogZGlhZ25vc3RpY1BheWxvYWQsXG4gICAgICAgIG1ldGE6IHtcbiAgICAgICAgICByZWFkT25seTogdHJ1ZSxcbiAgICAgICAgICBjaGFuZ2VzTWFkZTogZmFsc2UsXG4gICAgICAgICAgdG9vbDogInBieF9haV9kaWFnbm9zZV9kZXZpY2VfY2F0YWxvZyJcbiAgICAgICAgfVxuICAgICAgfTtcbiAgICB9IGNhdGNoIChlcnJvcikge1xuICAgICAgcmV0dXJuIHtcbiAgICAgICAgZGF0YToge1xuICAgICAgICAgIG9rOiBmYWxzZSxcbiAgICAgICAgICBlcnJvcjogYERldmljZSBjYXRhbG9nIGRpYWdub3N0aWMgZmFpbGVkOiAke2Vycm9yPy5tZXNzYWdlIHx8IGVycm9yfWAsXG4gICAgICAgICAgY2hhbmdlc01hZGU6IGZhbHNlXG4gICAgICAgIH0sXG4gICAgICAgIG1ldGE6IHtcbiAgICAgICAgICByZWFkT25seTogdHJ1ZSxcbiAgICAgICAgICBjaGFuZ2VzTWFkZTogZmFsc2UsXG4gICAgICAgICAgdG9vbDogInBieF9haV9kaWFnbm9zZV9kZXZpY2VfY2F0YWxvZyJcbiAgICAgICAgfVxuICAgICAgfTtcbiAgICB9JwppZiBvbGQxIG5vdCBpbiBibG9jazoKICAgIHJhaXNlIFN5c3RlbUV4aXQoIlBBVENIIEVSUk9SOiBzdWNjZXNzIHdyYXBwZXIgYW5jaG9yIG1pc3NpbmciKQppZiBvbGQyIG5vdCBpbiBibG9jazoKICAgIHJhaXNlIFN5c3RlbUV4aXQoIlBBVENIIEVSUk9SOiByZXR1cm4gdGFpbCBhbmNob3IgbWlzc2luZyIpCmJsb2NrPWJsb2NrLnJlcGxhY2Uob2xkMSxuZXcxLDEpLnJlcGxhY2Uob2xkMixuZXcyLDEpCnM9c1s6c3RhcnRdK2Jsb2NrK3NbZW5kOl0KcC53cml0ZV90ZXh0KHMpCg==' | base64 -d | python3 - "$TMP"
echo PASS

echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched JavaScript syntax invalid"
grep -q 'tool: "pbx_ai_diagnose_device_catalog"' "$TMP" || fail "meta block missing"
echo PASS

echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; }
echo "PASS: $SERVICE active"

echo "[6/6] Verify"
grep -n -A16 -B4 'tool: "pbx_ai_diagnose_device_catalog"' "$INDEX" | head -50
echo
echo "=== DIAGNOSTIC SCHEMA FIX INSTALL PASS ==="
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: Claude calls pbx_ai_diagnose_device_catalog again."
