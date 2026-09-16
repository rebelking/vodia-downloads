#!/usr/bin/env bash
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

echo "[fix] Downloading Cloudflare Phase 1 installer..."
wget -q -O "$TMP" "$BASE_URL/upgrade-vodia-mcp-cloudflare-phase1.sh"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '    s = imp + s\n'
new = '''    if s.startswith("#!"):\n        first_nl = s.find("\\n")\n        s = s[:first_nl + 1] + imp + s[first_nl + 1:]\n    else:\n        s = imp + s\n'''
if old not in s:
    raise SystemExit("Expected Phase 1 import insertion pattern was not found; refusing to run.")
s = s.replace(old, new, 1)
p.write_text(s)
PY

bash -n "$TMP"
echo "PASS: corrected installer syntax valid"
exec bash "$TMP"
