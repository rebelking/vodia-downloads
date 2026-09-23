#!/usr/bin/env bash
# Vodia MCP v0.14.9.81 — One-click shared ACTIVE Marketplace agreement fix
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.81"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-one-click-shared-agreement-$STAMP"
TMP="$(mktemp -d)"
DRY_RUN_ONLY="${VODIA_MCP_DRY_RUN:-0}"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$BACKEND" "$UI" "$GUIDED" "$VERSION"; do
  [[ -f "$f" ]] || fail "missing $f"
done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.79|0.14.9.80) ;;
  0.14.9.81) echo "v0.14.9.81 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.79/.80/.81; found ${CURRENT:-unknown}. Refusing to patch an unknown version." ;;
esac

echo "=== Vodia MCP v$TO_VER — one-click shared ACTIVE agreement fix ==="
echo "[0/8] Live preflight — NO LIVE CHANGES"

grep -Fq 'VODIA_SHARED_MARKETPLACE_AGREEMENT_V78' "$BACKEND" || fail "shared-agreement v78 backend marker missing"
grep -Fq 'aws_marketplace_prepare_vodia_one_click' "$BACKEND" || fail "one-click preparation tool missing"
grep -Fq 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.' "$BACKEND" || {
  if [[ "$CURRENT" != "0.14.9.81" ]]; then
    fail "expected stale one-click AVAILABLE-agreement blocker was not found"
  fi
}
echo "PASS: one-click tool and shared-agreement backend detected"

mkdir -p "$TMP/staged"
cp -a "$BACKEND" "$TMP/staged/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/8] Patch staged backend — NO LIVE CHANGES"
python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

if 'VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_V81' not in s:
    marker='const VODIA_SHARED_MARKETPLACE_AGREEMENT_V78 = true;'
    i=s.find(marker)
    if i<0:
        raise SystemExit("PATCH ERROR: shared-agreement marker missing")
    e=s.find('\n',i)
    s=s[:e+1]+'const VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_V81 = true;\n'+s[e+1:]

tool_start=s.find('"aws_marketplace_prepare_vodia_one_click"')
if tool_start<0:
    raise SystemExit("PATCH ERROR: one-click tool missing")
network_anchor=s.find('        const network=await describeNetwork(',tool_start)
if network_anchor<0:
    raise SystemExit("PATCH ERROR: one-click network anchor missing")
segment=s[tool_start:network_anchor]

# v72 introduced an exclusive-slot check here. v78 intentionally made ACTIVE
# Marketplace agreements reusable, but this one-click path was missed.
pattern=re.compile(
    r'''\n\s*const usage=await reconcileMarketplaceAgreementUsage\(.*?\n\s*\);\n'''
    r'''\s*if\(usage\.status!==["']AVAILABLE["']\)\{\n'''
    r'''\s*throw new Error\(["']MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement\.["']\);\n'''
    r'''\s*\}\n''',
    re.S
)
new_segment,count=pattern.subn('\n',segment,count=1)

if count==0:
    # Idempotent repair mode: accept an already-patched v81 segment.
    if 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.' in segment:
        raise SystemExit("PATCH ERROR: stale blocker present but exact one-click block did not match")
else:
    s=s[:tool_start]+new_segment+s[network_anchor:]

# Guardrail: the one-click preparation must still require an AWS ACTIVE agreement.
tool_end=s.find('  server.registerTool(',tool_start+10)
if tool_end<0:
    tool_end=len(s)
oneclick=s[tool_start:tool_end]
if 'if(!subscription.active)' not in oneclick:
    raise SystemExit("PATCH ERROR: ACTIVE Marketplace subscription guard missing")
if 'if(!agreement)' not in oneclick:
    raise SystemExit("PATCH ERROR: selected ACTIVE agreement guard missing")
if 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.' in oneclick:
    raise SystemExit("PATCH ERROR: stale one-click exclusive-agreement blocker remains")

p.write_text(s)
PY

echo "[2/8] Cache-bump staged guided UI"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_UI_V81' not in s:
    anchor='const VODIA_MARKETPLACE_PRODUCT_ID='
    i=s.find(anchor)
    if i<0: raise SystemExit("PATCH ERROR: UI product anchor missing")
    e=s.find('\n',i)
    s=s[:e+1]+'  const VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_UI_V81 = true;\n'+s[e+1:]
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.81"',s)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(
    r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
    'ui://vodia/msp-guided/v0.14.9.81/mcp-app.html',
    s,count=1
)
if count!=1:
    raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(
    r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
    r'\g<1>'+to+r'\2',
    s,count=1
)
if count!=1:
    raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

echo "[3/8] Validate staged JavaScript"
node --check "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" >/dev/null || fail "backend JavaScript invalid"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null || fail "guided resource JavaScript invalid"
node --check "$TMP/staged/version.js" >/dev/null || fail "version JavaScript invalid"

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline.js" >/dev/null || fail "guided UI inline JavaScript invalid"

grep -Fq 'VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_V81' "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" || fail "backend v81 marker missing"
grep -Fq 'VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_UI_V81' "$TMP/staged/msp-guided-app.html" || fail "UI v81 marker missing"

python3 - "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
a=s.find('"aws_marketplace_prepare_vodia_one_click"')
b=s.find('  server.registerTool(',a+10)
seg=s[a:b if b>=0 else len(s)]
assert 'if(!subscription.active)' in seg
assert 'if(!agreement)' in seg
assert 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.' not in seg
print("PASS: one-click preparation accepts selected ACTIVE agreement regardless of prior deployment ledger state")
PY

echo "PASS: staged v81 patch validated"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.81 staged patch validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[4/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$BACKEND" "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v81 files"
  cp -a "$BACKUP_DIR/aws-marketplace-ec2-deploy-v1.js" "$BACKEND" || true
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[5/8] Install staged files + restart"
install -o root -g root -m 0644 "$TMP/staged/aws-marketplace-ec2-deploy-v1.js" "$BACKEND"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[6/8] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.81"' <<<"$HEALTH" || fail "health does not report v0.14.9.81"
echo "$HEALTH"

echo "[7/8] Live blocker verification"
grep -Fq 'VODIA_ONE_CLICK_SHARED_ACTIVE_AGREEMENT_V81' "$BACKEND" || fail "live backend v81 marker missing"
python3 - "$BACKEND" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
a=s.find('"aws_marketplace_prepare_vodia_one_click"')
b=s.find('  server.registerTool(',a+10)
seg=s[a:b if b>=0 else len(s)]
if 'MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: select another AVAILABLE agreement.' in seg:
    raise SystemExit("FAIL: live stale one-click blocker remains")
print("PASS: live one-click exclusive-agreement blocker removed")
PY

echo "[8/8] Complete"
echo "PASS: Vodia MCP v0.14.9.81 installed."
echo "PASS: ONE_CLICK_MARKETPLACE now treats an AWS ACTIVE agreement as reusable."
echo "PASS: exact ACTIVE-agreement validation remains."
echo "PASS: duplicate PBX-name/idempotency protections in deployment planning/apply remain unchanged."
echo "Backup: $BACKUP_DIR"
