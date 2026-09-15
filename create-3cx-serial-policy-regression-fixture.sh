#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/var/lib/vodia-mcp/imports/3cx-test-fixture-sanitized-normalized.json"
OUT="/var/lib/vodia-mcp/imports/3cx-serial-policy-regression.json"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== 3CX Serial Policy Runtime Fixture ==="

echo "[1/5] Preflight"
test -f "$SRC" || fail "source fixture not found: $SRC"
command -v jq >/dev/null || fail "jq is required"
jq -e '.phones | type == "array"' "$SRC" >/dev/null || fail "source fixture has no phones array"
echo "PASS"

echo "[2/5] Preserve any existing regression fixture"
if [ -f "$OUT" ]; then
  cp -a "$OUT" "${OUT}.bak.${STAMP}"
  echo "Backup: ${OUT}.bak.${STAMP}"
else
  echo "No previous regression fixture"
fi

echo "[3/5] Build four-case fixture"
jq '
  .phones = [
    {
      extension: "9901",
      mac: "805E0C000901",
      vendor: "Yealink",
      model: "T48U",
      serial_number: "TEST-YEALINK-001"
    },
    {
      extension: "9902",
      mac: "805E0C000902",
      vendor: "Yealink",
      model: "T48U",
      serial_number: ""
    },
    {
      extension: "9903",
      mac: "000413009903",
      vendor: "Snom",
      model: "D785",
      serial_number: "TEST-SNOM-001"
    },
    {
      extension: "9904",
      mac: "000413009904",
      vendor: "Snom",
      model: "D785",
      serial_number: ""
    }
  ]
' "$SRC" > "${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"
chown --reference="$SRC" "$OUT" 2>/dev/null || true
chmod --reference="$SRC" "$OUT" 2>/dev/null || true
echo "PASS"

echo "[4/5] Validate"
jq -e '.phones | length == 4' "$OUT" >/dev/null || fail "fixture does not contain 4 phones"
jq -e '
  (.phones[0].vendor == "Yealink" and .phones[0].serial_number == "TEST-YEALINK-001") and
  (.phones[1].vendor == "Yealink" and .phones[1].serial_number == "") and
  (.phones[2].vendor == "Snom" and .phones[2].serial_number == "TEST-SNOM-001") and
  (.phones[3].vendor == "Snom" and .phones[3].serial_number == "")
' "$OUT" >/dev/null || fail "fixture cases are incorrect"
echo "PASS"

echo "[5/5] Summary"
jq '{phones: [.phones[] | {extension,mac,vendor,model,serial_number}]}' "$OUT"

echo
echo "=== FIXTURE READY ==="
echo "File: $OUT"
echo "PBX writes: 0"
echo
echo 'Claude test override: {"snom d785":"D785"}'
