#!/usr/bin/env bash
# Vodia MCP v0.14.9.80 — License Manager button wiring fix
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.80"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-license-button-$STAMP"
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
  0.14.9.79) ;;
  0.14.9.80) echo "v0.14.9.80 detected; verification/repair mode." ;;
  *) fail "expected live v0.14.9.79 or .80; found ${CURRENT:-unknown}. Refusing to patch an unknown version." ;;
esac

echo "=== Vodia MCP v$TO_VER — License Manager button wiring fix ==="
echo "[0/7] Live preflight — NO LIVE CHANGES"

grep -Fq 'VODIA_LICENSE_MANAGER_INIT_BACKEND_V79_R4' "$BACKEND" || fail "r4 backend initializer marker missing"
grep -Fq 'aws_license_manager_initialize' "$BACKEND" || fail "aws_license_manager_initialize tool registration missing"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_UI_V79_R4' "$UI" || fail "r4 UI marker missing"
grep -Fq 'id="initializeMarketplaceLicenseManager"' "$UI" || fail "Initialize License Manager button missing"
grep -Fq 'initializeMarketplaceLicenseManagerV79R4' "$UI" || fail "r4 initialization function missing"
echo "PASS: r4 backend and UI are present"

mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/7] Patch staged UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

start=s.find('  async function initializeMarketplaceLicenseManagerV79R4(){')
end=s.find('  async function checkMarketplaceSubscription', start)
if start<0 or end<0:
    raise SystemExit("PATCH ERROR: r4 initialize function anchors missing")

new_fn=r'''  const VODIA_LICENSE_MANAGER_INIT_UI_V80 = true;
  let licenseManagerInitArmedUntilV80 = 0;

  async function initializeMarketplaceLicenseManagerV80(){
    const id=customerId();
    if(!id) return null;

    const button=$("initializeMarketplaceLicenseManager");
    const now=Date.now();

    if(now > licenseManagerInitArmedUntilV80){
      licenseManagerInitArmedUntilV80=now+15000;
      if(button){
        button.textContent="Confirm Initialize License Manager";
        button.classList.remove("hidden");
      }
      setMsg(
        "marketplaceMsg",
        "One-time AWS setup: click Confirm Initialize License Manager within 15 seconds. "+
        "This creates only AWSServiceRoleForAWSLicenseManagerRole using the connected customer deployment role. "+
        "It does not purchase anything, launch EC2, or change the Marketplace agreement."
      );
      setTimeout(()=>{
        if(Date.now() > licenseManagerInitArmedUntilV80){
          licenseManagerInitArmedUntilV80=0;
          const b=$("initializeMarketplaceLicenseManager");
          if(b && !b.disabled) b.textContent="Initialize License Manager";
        }
      },16000);
      reportSize();
      return {armed:true};
    }

    licenseManagerInitArmedUntilV80=0;
    try{
      if(button){button.disabled=true;button.textContent="Initializing…";}
      setMsg("marketplaceMsg","Initializing AWS License Manager with VodiaMCPDeploymentRole…");

      const raw=await callTool("aws_license_manager_initialize",{
        customerId:id,
        productId:VODIA_MARKETPLACE_PRODUCT_ID,
        confirmation:"INITIALIZE AWS LICENSE MANAGER"
      });

      if(raw?.isError) throw new Error(toolErrorText(raw)||"License Manager initialization failed.");

      const data=dataFrom(raw);
      if(data?.licenseManagerReady){
        setMsg("marketplaceMsg","AWS License Manager initialized. Refreshing subscription and license evidence…");
      }else{
        setMsg(
          "marketplaceMsg",
          "AWS accepted the License Manager initialization. The service-linked role may still be propagating; refreshing now."
        );
      }

      await checkMarketplaceSubscription();
      return data;
    }catch(e){
      setMsg("marketplaceMsg",e?.message||String(e));
      return null;
    }finally{
      if(button){
        button.disabled=false;
        button.textContent="Initialize License Manager";
      }
      reportSize();
    }
  }

'''

s=s[:start]+new_fn+s[end:]

old='  $("initializeMarketplaceLicenseManager").addEventListener("click",initializeMarketplaceLicenseManagerV79R4);'
if old not in s:
    raise SystemExit("PATCH ERROR: r4 button listener anchor missing")

new=r'''  document.addEventListener("click",(event)=>{
    const target=event.target?.closest?.("#initializeMarketplaceLicenseManager");
    if(!target) return;
    event.preventDefault();
    event.stopPropagation();
    initializeMarketplaceLicenseManagerV80();
  });'''
s=s.replace(old,new,1)

s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.80"',s)

p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                 'ui://vodia/msp-guided/v0.14.9.80/mcp-app.html',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: guided UI URI anchor missing")
p.write_text(n)
PY

python3 - "$TMP/staged/version.js" "$TO_VER" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); to=sys.argv[2]; s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',
                 r'\g<1>'+to+r'\2',s,count=1)
if count!=1: raise SystemExit("PATCH ERROR: CONNECTOR_VERSION anchor missing")
p.write_text(n)
PY

echo "[2/7] Validate staged UI"
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

for marker in \
  'VODIA_LICENSE_MANAGER_INIT_UI_V80' \
  'initializeMarketplaceLicenseManagerV80' \
  'Confirm Initialize License Manager' \
  'aws_license_manager_initialize' \
  'document.addEventListener("click"'; do
  grep -Fq "$marker" "$TMP/staged/msp-guided-app.html" || fail "UI marker missing: $marker"
done

! grep -Fq 'initializeMarketplaceLicenseManagerV79R4);' "$TMP/staged/msp-guided-app.html" \
  || fail "old r4 direct listener still present"

echo "PASS: v80 two-click in-app confirmation and delegated button wiring staged"

if [[ "$DRY_RUN_ONLY" == "1" ]]; then
  echo
  echo "DRY RUN PASS: v0.14.9.80 staged UI fix validated successfully."
  echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."
  exit 0
fi

echo "[3/7] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring pre-v80 UI files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/7] Install UI fix + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/7] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.80"' <<<"$HEALTH" || fail "health does not report v0.14.9.80"
echo "$HEALTH"

echo "[6/7] Live verification"
grep -Fq 'VODIA_LICENSE_MANAGER_INIT_UI_V80' "$UI" || fail "live v80 marker missing"
grep -Fq 'Confirm Initialize License Manager' "$UI" || fail "live two-click confirmation missing"
grep -Fq 'document.addEventListener("click"' "$UI" || fail "live delegated button handler missing"
echo "PASS: live v80 button wiring present"

echo "[7/7] Complete"
echo "PASS: Vodia MCP v0.14.9.80 installed."
echo "PASS: browser window.confirm dependency removed."
echo "PASS: first click arms the one-time License Manager action for 15 seconds."
echo "PASS: second click calls aws_license_manager_initialize."
echo "PASS: backend r4 initializer remains unchanged."
echo "Backup: $BACKUP_DIR"
