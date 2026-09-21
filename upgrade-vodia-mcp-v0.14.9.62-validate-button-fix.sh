#!/usr/bin/env bash
# Vodia MCP v0.14.9.62 — fix disabled Validate button + remove orphan legacy step bars
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
TO_VER="0.14.9.62"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-validate-button-fix-$STAMP"
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
  0.14.9.61) ;;
  0.14.9.62) echo "v0.14.9.62 already installed."; exit 0 ;;
  *) fail "expected v0.14.9.61; found ${CURRENT:-unknown}" ;;
esac

echo "=== Vodia MCP v${TO_VER} — Validate button + UI cleanup ==="
mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
cp -a "$VERSION" "$TMP/staged/version.js"

echo "[1/6] Patch staged live UI — NO LIVE CHANGES"
python3 - "$TMP/staged/msp-guided-app.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()

# Remove the two orphan legacy step divs left behind by the .61 non-greedy replacement.
s=s.replace('''        <div class="step">2 · AWS</div>
        <div class="step">3 · Deploy</div>
      </div>
''','',1)

# Planning is safe to enable as soon as EC2 network data is loaded.
# The click handler itself performs a fresh Marketplace subscription check before DryRun,
# so gating on a stale UI boolean can incorrectly deadlock the button.
old='''  function updatePlanButton(){
    $("planDeployment").disabled=!(marketplaceSubscriptionActive && currentNetwork);
  }'''
new='''  function updatePlanButton(){
    const ready=Boolean(
      currentNetwork &&
      selectedRegion &&
      $("pbxName")?.value.trim() &&
      $("instanceType")?.value &&
      $("subnetSelect")?.value &&
      $("securityGroupSelect")?.value
    );
    $("planDeployment").disabled=!ready;
  }'''
if old not in s:
    raise SystemExit("PATCH ERROR: updatePlanButton anchor missing")
s=s.replace(old,new,1)

# Re-evaluate the button whenever the relevant deployment fields change.
listener_anchor='''  $("vpcSelect").addEventListener("change",filterNetworkForVpc);'''
listeners='''  ["pbxName","instanceType","subnetSelect","securityGroupSelect","regionSelect"].forEach(id=>{
    $(id)?.addEventListener("input",updatePlanButton);
    $(id)?.addEventListener("change",updatePlanButton);
  });
'''
if listeners.strip() not in s:
    if listener_anchor not in s: raise SystemExit("PATCH ERROR: network listener anchor missing")
    s=s.replace(listener_anchor,listener_anchor+'\n\n'+listeners,1)

# filterNetworkForVpc changes subnet and SG selections programmatically, so refresh readiness.
filter_end='''    const defaultGroup=groups.find(x=>x.groupName==="default") || groups[0];
    if(defaultGroup) $("securityGroupSelect").value=defaultGroup.groupId;
  }'''
filter_new='''    const defaultGroup=groups.find(x=>x.groupName==="default") || groups[0];
    if(defaultGroup) $("securityGroupSelect").value=defaultGroup.groupId;
    updatePlanButton();
  }'''
if filter_end not in s:
    raise SystemExit("PATCH ERROR: filterNetworkForVpc end missing")
s=s.replace(filter_end,filter_new,1)

# loadNetwork previously called updatePlanButton before populating the actual select values.
# Run it again after all dropdowns are populated/defaulted.
msg='''      setMsg("deployMsg","AWS network and instance types loaded. Review the selections before creating the deployment plan."+warning);'''
if msg not in s: raise SystemExit("PATCH ERROR: load-network success anchor missing")
s=s.replace(msg,msg+'\n      updatePlanButton();',1)

# Region changes invalidate network and must immediately disable plan.
region_marker='''    currentNetwork=null;
    currentDeploymentPlan=null;
    reportSize();'''
region_repl='''    currentNetwork=null;
    currentDeploymentPlan=null;
    updatePlanButton();
    reportSize();'''
if region_marker in s:
    s=s.replace(region_marker,region_repl,1)

# The live click handler still does a fresh Marketplace check, preserving the safety gate.
# Add a visible message if a disabled-looking state somehow occurs.
plan_click='''  $("planDeployment").addEventListener("click",async()=>{'''
if plan_click not in s: raise SystemExit("PATCH ERROR: planner click handler missing")

if 'data-validate-button-fix="v0.14.9.62"' not in s:
    s=s.replace('data-consolidated-ui="v0.14.9.61"',
                'data-consolidated-ui="v0.14.9.61" data-validate-button-fix="v0.14.9.62"',1)
s=re.sub(r'appInfo:\{name:"vodia-setup",version:"[^"]+"\}',
         'appInfo:{name:"vodia-setup",version:"1.21.1"}',s,count=1)
p.write_text(s)
PY

python3 - "$TMP/staged/msp-guided-app-v1.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',
                'ui://vodia/msp-guided/v0.14.9.62/mcp-app.html',s,count=1)
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

echo "[2/6] Validate staged UI"
node --check "$TMP/staged/msp-guided-app-v1.js" >/dev/null
node --check "$TMP/staged/version.js" >/dev/null
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline-app.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit("VALIDATION ERROR: no inline script found")
Path(sys.argv[2]).write_text("\n".join(scripts))
PY
node --check "$TMP/staged/inline-app.js" >/dev/null || fail "guided app inline JavaScript invalid"
grep -Fq 'const ready=Boolean(' "$TMP/staged/msp-guided-app.html" || fail "readiness logic missing"
grep -Fq 'updatePlanButton();' "$TMP/staged/msp-guided-app.html" || fail "plan refresh missing"
grep -Fq 'data-validate-button-fix="v0.14.9.62"' "$TMP/staged/msp-guided-app.html" || fail "version marker missing"
if grep -Fq '<div class="step">2 · AWS</div>' "$TMP/staged/msp-guided-app.html"; then fail "orphan AWS step remains"; fi
if grep -Fq '<div class="step">3 · Deploy</div>' "$TMP/staged/msp-guided-app.html"; then fail "orphan Deploy step remains"; fi
grep -Fq 'function pollDeploymentStatus(launchResult)' "$TMP/staged/msp-guided-app.html" || fail "status polling regression"
grep -Fq 'rawPlanResult?.isError' "$TMP/staged/msp-guided-app.html" || fail "planner error propagation regression"
echo "PASS: Validate button readiness + UI cleanup present"

echo "[3/6] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

rollback(){
  echo "ROLLBACK: restoring v0.14.9.61 UI files"
  cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
  cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" || true
}
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT

echo "[4/6] Install + restart"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
install -o root -g root -m 0644 "$TMP/staged/version.js" "$VERSION"
systemctl restart "$SERVICE"

echo "[5/6] Health"
HEALTH=""
for _ in {1..30}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health failed"
grep -q '"version":"0.14.9.62"' <<<"$HEALTH" || fail "health does not report v0.14.9.62"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "$HEALTH"

echo "[6/6] Complete"
echo "PASS: Vodia MCP v0.14.9.62 installed"
echo "PASS: Validate & Create Plan enables when EC2 fields are actually ready."
echo "PASS: Marketplace is still re-verified by the planner click before DryRun."
echo "PASS: Legacy 2 · AWS / 3 · Deploy orphan bars are removed."
echo "PASS: Planner error propagation and deployment status polling are retained."
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a fresh message to load the v0.14.9.62 UI resource."
