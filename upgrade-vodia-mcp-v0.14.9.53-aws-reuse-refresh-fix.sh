#!/usr/bin/env bash
# Vodia MCP v0.14.9.53 — fix AWS reuse source filtering and refresh selection
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.53"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-aws-reuse-fix-$STAMP"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else "",end="")
PY
)"
case "$CURRENT" in
  0.14.9.51|0.14.9.52) ;;
  0.14.9.53) echo "v0.14.9.53 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.51 or v0.14.9.52; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — AWS reuse/refresh fix ==="
echo "[1/6] Stage live UI — NO LIVE CHANGES"
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[2/6] Patch live UI behavior — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Preserve selected customer across Refresh.
old='''  async function refreshCustomers(preselect){
    const r=dataFrom(await callTool("msp_list_customers",{}));
    allCustomers=r.customers||[];
    renderCustomers(preselect);
  }'''
new='''  async function refreshCustomers(preselect){
    const keep=preselect||customerId();
    const r=dataFrom(await callTool("msp_list_customers",{}));
    allCustomers=r.customers||[];
    renderCustomers(keep);
  }'''
if old in s:
    s=s.replace(old,new,1)
elif 'const keep=preselect||customerId();' not in s:
    raise SystemExit("PATCH ERROR: refreshCustomers anchor missing")

# Replace the v0.14.9.50 reuse picker. Only verified connections may be offered.
start=s.find('  function refreshReuseAwsOptions(){')
end=s.find('\n  $("awsSetupComplete").addEventListener("change"',start)
if start<0 or end<0:
    if 'async function refreshReuseAwsOptions(){' not in s:
        raise SystemExit("PATCH ERROR: reuse picker boundaries missing")
else:
    replacement='''  async function refreshReuseAwsOptions(){
    const target=customerId();
    const select=$("reuseAwsSource");
    if(!select) return;
    select.disabled=true;
    select.innerHTML='<option value="">Checking verified connections…</option>';
    setMsg("reuseAwsMsg","Checking which customers actually have a verified AWS connection…");

    const candidates=(allCustomers||[]).filter(c=>c.id!==target);
    const connected=[];
    for(const c of candidates){
      try{
        const r=dataFrom(await callTool("msp_get_customer_aws_connection",{customerId:c.id}));
        const connection=r.connection||null;
        if(connection?.configured){
          connected.push({customer:c,connection});
        }
      }catch(_e){
        // Ignore inaccessible/unconfigured candidates. They must never appear
        // as reusable AWS sources.
      }
    }

    select.innerHTML='<option value="">Select verified connection…</option>';
    connected.forEach(({customer,connection})=>{
      const option=document.createElement("option");
      option.value=customer.id;
      const org=customer.organizationName?customer.organizationName+" — ":"";
      const account=connection.account?" · AWS "+connection.account:"";
      option.textContent=org+customer.name+account;
      select.appendChild(option);
    });
    select.disabled=connected.length===0;
    $("reuseAwsConnection").disabled=connected.length===0;
    setMsg("reuseAwsMsg",connected.length
      ? "Only customers with a verified AWS connection are listed."
      : "No other verified AWS connection is available to reuse.");
    reportSize();
  }
'''
    s=s[:start]+replacement+s[end:]

# Await refreshReuseAwsOptions wherever it is called in async flows when possible.
s=s.replace('      refreshReuseAwsOptions();','      refreshReuseAwsOptions().catch(e=>setMsg("reuseAwsMsg",e.message));')
s=s.replace('    refreshReuseAwsOptions();\n    $("reuseAwsBox").classList.remove("hidden");',
            '    refreshReuseAwsOptions().catch(e=>setMsg("reuseAwsMsg",e.message));\n    $("reuseAwsBox").classList.remove("hidden");')

# Improve AWS-step copy: if current customer is already connected, it should
# never suggest "reuse" as though another source is required.
s=s.replace(
  'setMsg("awsMsg","AWS account "+(connection.account||"")+" is connected.");',
  'setMsg("awsMsg","This customer is already connected to AWS account "+(connection.account||"")+". No reuse or new AWS setup is required.");',
  1
)

# Cache bust UI resource without depending on prior exact patch number.
gmarker='data-aws-reuse-filter="v0.14.9.53"'
if gmarker not in s:
    s=s.replace('<div class="card"', '<div class="card" data-aws-reuse-filter="v0.14.9.53"', 1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.15.0"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.53/mcp-app.html',s,count=1)
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

echo "[3/6] Validate staged patch"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
grep -Fq 'data-aws-reuse-filter="v0.14.9.53"' "$TMP/staged/msp-guided-app.html" || fail "UI marker missing"
grep -Fq 'Checking which customers actually have a verified AWS connection' "$TMP/staged/msp-guided-app.html" || fail "verified-source filter missing"
grep -Fq 'const keep=preselect||customerId();' "$TMP/staged/msp-guided-app.html" || fail "refresh selection preservation missing"
grep -Fq 'ui://vodia/msp-guided/v0.14.9.53/mcp-app.html' "$TMP/staged/msp-guided-app-v1.js" || fail "UI cache bust missing"
echo "PASS"

echo "[4/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

echo "[5/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.53"' <<<"$HEALTH" || fail "health does not report v0.14.9.53"
echo "$HEALTH"
echo "PASS"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.53 installed"
echo "PASS: Refresh preserves the selected customer."
echo "PASS: AWS reuse only lists customers with a verified saved AWS connection."
echo "PASS: An already-connected customer is treated as connected; no reuse/new setup is required."
echo "PASS: Existing Marketplace subscription remains reusable for additional EC2 deployments in that AWS account."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the new UI resource."
