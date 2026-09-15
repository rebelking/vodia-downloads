#!/usr/bin/env bash
set -Eeuo pipefail
INDEX="/opt/vodia-mcp/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="${INDEX}.pre-phase3-11-5-3.${STAMP}"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
echo "=== Vodia MCP Phase 3.11.5.3 ==="
echo "[1/7] Preflight"
test -f "$INDEX" || fail "index.js missing"
node --check "$INDEX" >/dev/null || fail "current syntax invalid"
grep -q 'Phase 3.11.5.2 structured operation arguments' "$INDEX" || fail "3.11.5.2 fix missing"
grep -q 'function recursivelyCollectModelObjects' "$INDEX" || fail "model collector missing"
echo PASS
echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"
echo "[3/7] Patch catalog extraction"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
marker="Phase 3.11.5.3 vendor models array extraction"
if marker not in s:
    start=s.find("function recursivelyCollectModelObjects")
    if start < 0: raise SystemExit("PATCH ERROR: collector not found")
    brace=s.find("{", start)
    if brace < 0: raise SystemExit("PATCH ERROR: opening brace not found")
    insert="""
  // Phase 3.11.5.3 vendor models array extraction.
  // Vodia button_templates may return [{ vendor, models: [...] }, ...].
  if (node && typeof node === "object" && !Array.isArray(node)) {
    const vendor = String(node.vendor ?? node.name ?? "").trim();
    if (vendor && Array.isArray(node.models)) {
      for (const entry of node.models) {
        if (typeof entry === "string" || typeof entry === "number") {
          const model = String(entry).trim();
          if (model) out.push({ vendor, model });
        } else if (entry && typeof entry === "object") {
          const model = String(entry.model ?? entry.name ?? entry.id ?? "").trim();
          if (model) out.push({ vendor, model });
        }
      }
    }
  }
"""
    s=s[:brace+1]+insert+s[brace+1:]
p.write_text(s)
PY
echo PASS
echo "[4/7] Validate"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
grep -q 'Phase 3.11.5.3 vendor models array extraction' "$TMP" || fail "marker missing"
echo PASS
echo "[5/7] Install"
cp -a "$TMP" "$INDEX"
node --check "$INDEX" >/dev/null || { cp -a "$BACKUP" "$INDEX"; fail "install invalid; restored"; }
echo PASS
echo "[6/7] Restart/health"
systemctl restart "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "restart failed; restored"; }
sleep 2
systemctl is-active --quiet "$SERVICE" || { cp -a "$BACKUP" "$INDEX"; systemctl restart "$SERVICE" || true; fail "service unhealthy; restored"; }
echo "PASS: $SERVICE active"
echo "[7/7] Verify"
grep -n -A18 -B2 'Phase 3.11.5.3 vendor models array extraction' "$INDEX" | head -30
echo
echo "=== PHASE 3.11.5.3 INSTALL PASS ==="
echo "Backup: $BACKUP"
echo "PBX writes: 0"
echo "NEXT: rerun the same read-only 71-device regression."
