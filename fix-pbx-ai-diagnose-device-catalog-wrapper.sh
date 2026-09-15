#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"; SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-diagnostic-wrapper-fix.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Diagnostic Wrapper Fix ==="
echo "[1/6] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q '"pbx_ai_diagnose_device_catalog"' "$INDEX" || fail "diagnostic tool missing"
echo PASS
echo "[2/6] Backup"
cp -a "$INDEX" "$BACKUP"; cp -a "$INDEX" "$TMP"; echo "PASS: $BACKUP"
echo "[3/6] Patch native response wrappers"
echo 'ZnJvbSBwYXRobGliIGltcG9ydCBQYXRoCmltcG9ydCBzeXMKcD1QYXRoKHN5cy5hcmd2WzFdKQpzPXAucmVhZF90ZXh0KCkKc3RhcnQ9cy5maW5kKCdzZXJ2ZXIucmVnaXN0ZXJUb29sKFxcbiAgInBieF9haV9kaWFnbm9zZV9kZXZpY2VfY2F0YWxvZyIsJykKZW5kPXMuZmluZCgnXFxuc2VydmVyLnJlZ2lzdGVyVG9vbCgnLCBzdGFydCsxMCkKaWYgc3RhcnQgPCAwIG9yIGVuZCA8IDA6IHJhaXNlIFN5c3RlbUV4aXQoIlBBVENIIEVSUk9SOiBkaWFnbm9zdGljIGJsb2NrIG5vdCBmb3VuZCIpCmI9c1tzdGFydDplbmRdCm9sZDE9JyAgICAgIHJldHVybiB7XG4gICAgICAgIGRhdGE6IGRpYWdub3N0aWNQYXlsb2FkLFxuICAgICAgICBtZXRhOiB7XG4gICAgICAgICAgcmVhZE9ubHk6IHRydWUsXG4gICAgICAgICAgY2hhbmdlc01hZGU6IGZhbHNlLFxuICAgICAgICAgIHRvb2w6ICJwYnhfYWlfZGlhZ25vc2VfZGV2aWNlX2NhdGFsb2ciXG4gICAgICAgIH1cbiAgICAgIH07JwpuZXcxPScgICAgICByZXR1cm4gc2NvcGVkU3VjY2VzcyhcbiAgICAgICAgZGlhZ25vc3RpY1BheWxvYWQsXG4gICAgICAgIHsgb3BlcmF0aW9uOiAiQUlfRElBR05PU0VfREVWSUNFX0NBVEFMT0ciLCByZWFkT25seTogdHJ1ZSwgY2hhbmdlc01hZGU6IGZhbHNlIH0sXG4gICAgICAgICJEZXZpY2UgY2F0YWxvZyBkaWFnbm9zdGljIGNvbXBsZXRlZC4gTm8gUEJYIGNoYW5nZXMgd2VyZSBtYWRlLiJcbiAgICAgICk7JwpvbGQyPScgICAgfSBjYXRjaCAoZXJyb3IpIHtcbiAgICAgIHJldHVybiB7XG4gICAgICAgIGRhdGE6IHtcbiAgICAgICAgICBvazogZmFsc2UsXG4gICAgICAgICAgZXJyb3I6IGBEZXZpY2UgY2F0YWxvZyBkaWFnbm9zdGljIGZhaWxlZDogJHtlcnJvcj8ubWVzc2FnZSB8fCBlcnJvcn1gLFxuICAgICAgICAgIGNoYW5nZXNNYWRlOiBmYWxzZVxuICAgICAgICB9LFxuICAgICAgICBtZXRhOiB7XG4gICAgICAgICAgcmVhZE9ubHk6IHRydWUsXG4gICAgICAgICAgY2hhbmdlc01hZGU6IGZhbHNlLFxuICAgICAgICAgIHRvb2w6ICJwYnhfYWlfZGlhZ25vc2VfZGV2aWNlX2NhdGFsb2ciXG4gICAgICAgIH1cbiAgICAgIH07XG4gICAgfScKbmV3Mj0nICAgIH0gY2F0Y2ggKGVycm9yKSB7XG4gICAgICByZXR1cm4gZmFpbHVyZShlcnJvciwgImRldmljZSBjYXRhbG9nIGRpYWdub3N0aWMiKTtcbiAgICB9JwppZiBvbGQxIG5vdCBpbiBiOiByYWlzZSBTeXN0ZW1FeGl0KCJQQVRDSCBFUlJPUjogcmF3IHN1Y2Nlc3MgZW52ZWxvcGUgbm90IGZvdW5kIikKaWYgb2xkMiBub3QgaW4gYjogcmFpc2UgU3lzdGVtRXhpdCgiUEFUQ0ggRVJST1I6IHJhdyBlcnJvciBlbnZlbG9wZSBub3QgZm91bmQiKQpiPWIucmVwbGFjZShvbGQxLG5ldzEsMSkucmVwbGFjZShvbGQyLG5ldzIsMSkKcC53cml0ZV90ZXh0KHNbOnN0YXJ0XStiK3NbZW5kOl0pCg==' | base64 -d | python3 - "$TMP"
echo PASS
echo "[4/6] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'AI_DIAGNOSE_DEVICE_CATALOG' "$TMP" || fail "success wrapper missing"
grep -q 'failure(error, "device catalog diagnostic")' "$TMP" || fail "failure wrapper missing"
echo PASS
echo "[5/6] Install + restart"
cp -a "$TMP" "$INDEX"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; }
echo "PASS: $SERVICE active"
echo "[6/6] Verify"
grep -n -A18 -B5 'AI_DIAGNOSE_DEVICE_CATALOG' "$INDEX" | head -50
echo
echo "=== DIAGNOSTIC WRAPPER FIX INSTALL PASS ==="
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo "NEXT: Claude calls pbx_ai_diagnose_device_catalog once."
