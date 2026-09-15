#!/usr/bin/env bash
set -Eeuo pipefail

SRC="/var/lib/vodia-mcp/imports/3cx-test-fixture-sanitized-normalized.json"
OUT="/var/lib/vodia-mcp/imports/3cx-serial-policy-regression.json"
STAMP="$(date -u +%Y%m%d-%H%M%S)"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== 3CX Serial Policy Runtime Fixture v2 ==="

echo "[1/5] Preflight"
test -f "$SRC" || fail "source fixture not found: $SRC"
command -v jq >/dev/null || fail "jq is required"
jq -e '.normalized.phones | type == "array"' "$SRC" >/dev/null || fail "source fixture has no .normalized.phones array"
COUNT="$(jq -r '.normalized.phones | length' "$SRC")"
[ "$COUNT" -eq 71 ] || fail "expected 71 source phones, found $COUNT"
echo "PASS: source phones=$COUNT"

echo "[2/5] Preserve any existing regression fixture"
if [ -f "$OUT" ]; then
  cp -a "$OUT" "${OUT}.bak.${STAMP}"
  echo "Backup: ${OUT}.bak.${STAMP}"
else
  echo "No previous regression fixture"
fi

echo "[3/5] Build four-case fixture under .normalized.phones"
jq '
  .normalized.phones = [
    {
      mac: "805E0C000901",
      model: "Yealink T48U",
      template: "yealinkT4x.ph.xml",
      interface: "serial-regression.local",
      extension: "9901",
      serial_number: "TEST-YEALINK-001"
    },
    {
      mac: "805E0C000902",
      model: "Yealink T48U",
      template: "yealinkT4x.ph.xml",
      interface: "serial-regression.local",
      extension: "9902"
    },
    {
      mac: "000413009903",
      model: "Snom D785",
      template: "snom.ph.xml",
      interface: "serial-regression.local",
      extension: "9903",
      serial_number: "TEST-SNOM-001"
    },
    {
      mac: "000413009904",
      model: "Snom D785",
      template: "snom.ph.xml",
      interface: "serial-regression.local",
      extension: "9904"
    }
  ]
  | .phone_model_counts = {
      "Yealink T48U": 2,
      "Snom D785": 2
    }
' "$SRC" > "${OUT}.tmp"

mv "${OUT}.tmp" "$OUT"
chown --reference="$SRC" "$OUT" 2>/dev/null || true
chmod --reference="$SRC" "$OUT" 2>/dev/null || true
echo "PASS"

echo "[4/5] Validate"
jq -e '.normalized.phones | length == 4' "$OUT" >/dev/null || fail "fixture does not contain 4 phones"
jq -e '
  (.normalized.phones[0].model == "Yealink T48U" and .normalized.phones[0].serial_number == "TEST-YEALINK-001") and
  (.normalized.phones[1].model == "Yealink T48U" and (.normalized.phones[1].serial_number? // "") == "") and
  (.normalized.phones[2].model == "Snom D785" and .normalized.phones[2].serial_number == "TEST-SNOM-001") and
  (.normalized.phones[3].model == "Snom D785" and (.normalized.phones[3].serial_number? // "") == "")
' "$OUT" >/dev/null || fail "fixture cases are incorrect"
echo "PASS"

echo "[5/5] Summary"
jq '{
  fixture: "3cx-serial-policy-regression.json",
  phones: [.normalized.phones[] | {
    extension, mac, model,
    serial_number: (.serial_number? // null)
  }]
}' "$OUT"

echo
echo "=== FIXTURE READY ==="
echo "File: $OUT"
echo "PBX writes: 0"
echo
echo 'Claude model_overrides: {"snom d785":"D785"}'
