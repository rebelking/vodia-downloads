#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
HTTP="$APP/http.js"
INDEX="$APP/index.js"
PUBLIC="$APP/public"
PKG="$APP/package.json"

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "Missing $APP"
[[ -f "$PKG" ]] || fail "Missing $PKG"

echo "=== Vodia MCP integration hook inspection ==="
echo "READ-ONLY: this script makes no changes."
echo

echo "[1] Installed version"
node -p "require('$PKG').version" 2>/dev/null || true
echo

echo "[2] Top-level application files"
find "$APP" -maxdepth 2 -type f \
  \( -name '*.js' -o -name '*.html' -o -name '*.json' \) \
  -printf '%P\n' | sort | head -200
echo

echo "[3] HTTP/control-center route anchors"
if [[ -f "$HTTP" ]]; then
  grep -nE "(app|router)\.(get|post|put|patch|delete)\(|express\.static|/api/|control|dashboard|login|logout|session|csrf|admin" "$HTTP" \
    | sed -E 's/(Authorization|Bearer|token|secret|password|cookie)[^,;)]*/\1=[REDACTED]/Ig' \
    | head -220 || true
else
  echo "http.js not present"
fi
echo

echo "[4] Authentication/middleware function names"
for f in "$HTTP" "$INDEX"; do
  [[ -f "$f" ]] || continue
  echo "--- ${f#$APP/} ---"
  grep -nE "^(async[[:space:]]+)?function[[:space:]]+[A-Za-z0-9_]+|const[[:space:]]+[A-Za-z0-9_]+[[:space:]]*=[[:space:]]*(async[[:space:]]*)?\(" "$f" \
    | grep -Ei "auth|admin|session|csrf|user|role|require|protect|dashboard|control|audit" \
    | head -160 || true
done
echo

echo "[5] Existing MCP tool-registration anchors"
for f in "$INDEX" "$HTTP"; do
  [[ -f "$f" ]] || continue
  echo "--- ${f#$APP/} ---"
  grep -n "registerTool" "$f" | head -80 || true
done
echo

echo "[6] Public UI structure"
if [[ -d "$PUBLIC" ]]; then
  find "$PUBLIC" -maxdepth 2 -type f -printf '%P\n' | sort | head -160
  echo
  for f in "$PUBLIC"/*.html "$PUBLIC"/*.js; do
    [[ -f "$f" ]] || continue
    echo "--- ${f#$APP/} ---"
    grep -nEi "integration|user|oauth|settings|navigation|nav|fetch\(|/api/|dashboard|control" "$f" \
      | sed -E 's/(Authorization|Bearer|token|secret|password|cookie)[^,;)]*/\1=[REDACTED]/Ig' \
      | head -120 || true
  done
else
  echo "public directory not present"
fi
echo

echo "[7] SQLite/auth storage references"
for f in "$APP"/*.js; do
  [[ -f "$f" ]] || continue
  grep -nEi "node:sqlite|DatabaseSync|CREATE TABLE|auth\.db|DB_PATH" "$f" \
    | sed -E 's/(token|secret|password)[^,;)]*/\1=[REDACTED]/Ig' \
    | head -120 || true
done
echo

echo "=== INSPECTION COMPLETE ==="
echo "Paste this output back into the build session. It should contain structure and route names only, not credential values."
