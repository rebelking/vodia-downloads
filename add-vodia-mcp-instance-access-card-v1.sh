#!/usr/bin/env bash
# Vodia MCP instance access card. UI-only add-on for the v0.14.9.81/.82 guided setup.
set -Eeuo pipefail

MODE="${1:---explain}"
case "$MODE" in
  --explain|--dry-run|--apply) ;;
  *) echo "Usage: bash $0 [--explain | --dry-run | --apply]" >&2; exit 2 ;;
esac

explain() {
  cat <<'TEXT'
Add a fifth Vodia Setup page: Instance access.

The page loads the selected customer's EC2 inventory, offers an explicit
instance picker, and shows separate PBX web and EC2 machine access controls.
Only Vodia Marketplace instances tagged with the selected customer's ID and
the configured Vodia product ID can be selected. A fresh inventory read is
required each time the card is opened; changing customers clears the choice.

"Open PBX to change administrator password" opens the selected machine's
HTTPS address. The password is changed on the PBX's own authenticated page.
"Open machine access" opens the AWS EC2 console for that exact instance;
Linux access uses configured Session Manager or SSH. Neither action changes
a password in the MCP. The current AMI does not have a verified, secure
post-boot password-change API; this patch deliberately has no password form.

This update only modifies the guided UI HTML and its resource URI. It does
not change AWS permissions, Marketplace agreements, instances, PBX accounts,
the Chime patch, or the MCP server's reported version. It makes a backup and
rolls back if the service restart or health check fails. Before --apply it
also REQUIRES the verified, whole-MCP checkpoint created by
backup-vodia-mcp-pre-instance-access-v1.sh --create. The checkpoint must
match this server, version and current MCP code; --dry-run makes no changes.

  bash this-file.sh --explain
  sudo bash this-file.sh --dry-run
  sudo bash this-file.sh --apply
TEXT
}
if [[ "$MODE" == --explain ]]; then explain; exit 0; fi

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
VERSION="$APP/version.js"
HEALTH_URL="${VODIA_MCP_HEALTH_URL:-http://127.0.0.1:3100/health}"
BACKUP_ROOT="${VODIA_MCP_BACKUP_ROOT:-/var/backups}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
BACKUP_DIR=""
INSTALLED=0
fail(){ echo "FAIL: $*" >&2; exit 1; }
cleanup(){
  rc=$?
  if (( rc != 0 && INSTALLED )); then
    echo "Restoring guided UI from $BACKUP_DIR" >&2
    cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
    cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
    systemctl restart "$SERVICE" || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$UI" "$GUIDED" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done

CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',Path(sys.argv[1]).read_text())
print(m.group(1) if m else '',end='')
PY
)"
case "$CURRENT" in
  0.14.9.81|0.14.9.82) ;;
  *) fail "expected v0.14.9.81 or .82, got ${CURRENT:-unknown}; refusing an unknown UI" ;;
esac

if [[ "$MODE" == --apply ]]; then
  POINTER="${VODIA_MCP_FULL_BACKUP_ROOT:-/opt/vodia-mcp-backups}/vodia-mcp-pre-instance-access-v1.latest"
  [[ -f "$POINTER" ]] || fail "create a verified full MCP checkpoint first: backup-vodia-mcp-pre-instance-access-v1.sh --create"
  ARCHIVE="$(cat "$POINTER")"
  python3 - "$ARCHIVE" "$CURRENT" "$APP" <<'PY'
import hashlib,json,os,socket,sys
from pathlib import Path
archive,version,app=Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
receipt=Path(str(archive)+'.verified.json')
def require(ok,message):
    if not ok: raise SystemExit('FAIL: '+message)
require(archive.is_file() and receipt.is_file(),'full MCP backup archive or verification receipt missing')
require(archive.name.startswith('vodia-mcp-pre-instance-access-v1-'),'wrong backup archive name')
require(archive.stat().st_uid==0 and receipt.stat().st_uid==0,'backup must be root owned')
require(archive.stat().st_mode & 0o777==0o600,'backup must be mode 600')
r=json.loads(receipt.read_text())
require(r.get('format')=='vodia-mcp-pre-instance-access-v1' and r.get('verified') is True,
        'archive has no verified receipt')
require(r.get('archive')==str(archive.resolve()),'receipt points at a different archive')
require(r.get('hostname')==socket.gethostname(),'backup belongs to another server')
require(r.get('version')==version,'backup does not match the current MCP version')
h=hashlib.sha256()
with archive.open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
require(h.hexdigest()==r.get('sha256'),'backup archive checksum mismatch')
required=('index.js','version.js','ui/msp-guided-app.html',
          'msp-guided-app-v1.js','aws-marketplace-ec2-deploy-v1.js')
for rel in required:
    expected=r.get('files',{}).get('opt/vodia-mcp/'+rel)
    file=app/rel
    require(expected and file.is_file(),f'backup missing expected live file: {rel}')
    require(hashlib.sha256(file.read_bytes()).hexdigest()==expected,
            f'live {rel} differs from verified backup; create a new checkpoint')
print('PASS: verified full MCP backup matches current live code and host')
PY
  systemctl is-active --quiet "$SERVICE" || fail "MCP service is not running"
  BEFORE_HEALTH="$(curl -fsS "$HEALTH_URL")" || fail "MCP health is unavailable before patch"
  grep -Fq "\"version\":\"$CURRENT\"" <<<"$BEFORE_HEALTH" || fail "MCP health version differs from live code"
fi

mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/msp-guided-app-v1.js" "$CURRENT" <<'PY'
from pathlib import Path
import re,sys
ui,resource,version=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
s=ui.read_text()
t=resource.read_text()
marker='VODIA_INSTANCE_ACCESS_CARD_V1'
new_uri=f'ui://vodia/msp-guided/v{version}-instance-access-v1/mcp-app.html'

if marker in s:
    if not re.search(r'ui://vodia/msp-guided/v0\.14\.9\.\d+-instance-access-v1/mcp-app\.html',t):
        raise SystemExit('PATCH ERROR: card exists but resource URI is stale')
    print('PASS: instance access card already installed')
    raise SystemExit(0)

def replace_once(source,old,new,label):
    if source.count(old)!=1:
        raise SystemExit(f'PATCH ERROR: {label}: expected one anchor, found {source.count(old)}')
    return source.replace(old,new,1)

for required in ('VODIA_EC2_INVENTORY_UI_V75','function setStep(step){',
                 'reviewStepPanel:step===4','function dataFrom(result){',
                 'function toolErrorText(result){','consolidateGuidedLayout();',
                 'const VODIA_MARKETPLACE_PRODUCT_ID='):
    if required not in s: raise SystemExit(f'PATCH ERROR: missing expected UI feature: {required}')

s=replace_once(s,'<div class="step">4 · Review &amp; Deploy</div>',
               '<div class="step">4 · Review &amp; Deploy</div>\n'
               '        <div class="step">5 · Instance access</div>', 'fifth step header')

panel='''      <!-- VODIA_INSTANCE_ACCESS_CARD_V1: selected-customer, selected-instance access -->
      <div id="instanceAccessPanelV1" class="panel step-panel hidden" hidden aria-hidden="true">
        <h2>5 · Instance access</h2>
        <p>Choose one deployed Vodia PBX before opening its login or machine access.</p>
        <div class="field">
          <label for="instanceAccessSelectV1">Vodia PBX instance</label>
          <select id="instanceAccessSelectV1" disabled>
            <option value="">Select a PBX instance</option>
          </select>
        </div>
        <p id="instanceAccessStatusV1" role="status" aria-live="polite">Select a customer with a connected AWS account.</p>
        <div id="instanceAccessDetailsV1" class="hidden" hidden>
          <p id="instanceAccessIdentityV1"></p>
          <div class="instance-access-actions-v1">
            <a id="instanceAccessPbxV1" class="secondary" target="_blank" rel="noopener noreferrer" href="#">Open PBX to change administrator password</a>
            <a id="instanceAccessMachineV1" class="secondary" target="_blank" rel="noopener noreferrer" href="#">Open machine access in AWS</a>
          </div>
          <p class="instance-access-help-v1">EC2 running does not prove the PBX is ready. PBX administrator credentials and Linux machine access are separate. Change the PBX password in its own administrator settings. For vendor access, create a separate administrator account on that PBX. The machine uses your configured Session Manager or SSH access. Confirm the PBX HTTPS certificate before entering credentials.</p>
          <p class="instance-access-help-v1"><a href="https://doc.vodia.com/docs/login" target="_blank" rel="noopener noreferrer">Vodia administrator login instructions</a> · <a href="https://doc.vodia.com/docs/admin-security-users" target="_blank" rel="noopener noreferrer">Create a separate vendor administrator</a></p>
        </div>
        <div class="nav-actions">
          <button id="instanceAccessBackV1" class="secondary" type="button">Back to customer</button>
          <button id="instanceAccessRefreshV1" class="secondary" type="button">Refresh instances</button>
        </div>
      </div>

'''
s=replace_once(s,'      <div class="actions">\n        <button id="refresh"',
               panel+'      <div class="actions">\n        <button id="refresh"','instance panel mount')
s=replace_once(s,'reviewStepPanel:step===4','reviewStepPanel:step===4,\n      instanceAccessPanelV1:step===5','step router')
s=replace_once(s,':$("reviewStepPanel");',
               ':step===4?$("reviewStepPanel")\n        :$("instanceAccessPanelV1");','step scroll target')

# Load fresh inventory whenever the fifth page is opened. The old inventory
# table remains read-only on the customer page, and is never used as authority.
s=replace_once(s,'  function setStep(step){\n    currentStep=step;',
               '  function setStep(step){\n    currentStep=step;\n'
               '    if(step===5) queueMicrotask(()=>refreshInstanceAccessV1());',
               'step entrance')

style='''
/* VODIA_INSTANCE_ACCESS_CARD_V1 */
.steps{grid-template-columns:repeat(5,minmax(0,1fr))}
.steps .step{font-size:11px}
.instance-access-actions-v1{display:flex;gap:10px;flex-wrap:wrap;margin:12px 0}
.instance-access-actions-v1 a{display:inline-block;text-decoration:none;padding:9px 12px;border-radius:8px}
.instance-access-help-v1{font-size:12px;opacity:.8}
@media(max-width:620px){.steps{grid-template-columns:repeat(2,minmax(0,1fr))}}
'''
s=replace_once(s,'</style>',style+'</style>','access card styles')

logic=r'''  // VODIA_INSTANCE_ACCESS_CARD_V1: no passwords or EC2 commands enter MCP tools.
  let instanceAccessRowsV1=[];
  let instanceAccessScopeV1="";
  let instanceAccessRequestV1=0;

  function clearInstanceAccessV1(message){
    const select=$("instanceAccessSelectV1");
    select.replaceChildren(new Option("Select a PBX instance",""));
    select.disabled=true;
    const details=$("instanceAccessDetailsV1");
    details.hidden=true;details.classList.add("hidden");
    $("instanceAccessPbxV1").removeAttribute("href");
    $("instanceAccessMachineV1").removeAttribute("href");
    $("instanceAccessIdentityV1").textContent="";
    $("instanceAccessStatusV1").textContent=message;
    instanceAccessRowsV1=[];
  }

  function renderInstanceAccessV1(){
    const select=$("instanceAccessSelectV1");
    if(instanceAccessScopeV1!==customerId() || !currentAwsConnection?.configured){
      clearInstanceAccessV1("Customer or AWS connection changed. Refresh instances before continuing.");
      return;
    }
    const row=instanceAccessRowsV1.find(x=>x.region+"/"+x.instanceId===select.value);
    const details=$("instanceAccessDetailsV1");
    details.hidden=!row;details.classList.toggle("hidden",!row);
    $("instanceAccessPbxV1").removeAttribute("href");
    $("instanceAccessMachineV1").removeAttribute("href");
    if(!row) return;
    $("instanceAccessIdentityV1").textContent=
      (row.name||"Vodia PBX")+" · "+row.instanceId+" · "+row.region+" · "+row.state;
    const host=row.publicDnsName || row.publicIpAddress;
    if(row.state==="running" && host && /^([a-z0-9.-]+|[0-9.]+)$/i.test(host)){
      $("instanceAccessPbxV1").href="https://"+host+"/";
      $("instanceAccessPbxV1").hidden=false;
    }else{
      $("instanceAccessPbxV1").hidden=true;
    }
    if(/^[-a-z0-9]+$/.test(row.region) && /^i-[0-9a-f]+$/.test(row.instanceId)){
      $("instanceAccessMachineV1").href="https://console.aws.amazon.com/ec2/home?region="+
        encodeURIComponent(row.region)+"#InstanceDetails:instanceId="+encodeURIComponent(row.instanceId);
    }
    reportSize();
  }

  async function refreshInstanceAccessV1(){
    const scope=customerId();
    const request=++instanceAccessRequestV1;
    clearInstanceAccessV1("Checking the selected customer and AWS connection…");
    if(!scope || !currentAwsConnection?.configured){
      $("instanceAccessStatusV1").textContent="Select a customer and connect its AWS account first.";
      return;
    }
    instanceAccessScopeV1=scope;
    $("instanceAccessRefreshV1").disabled=true;
    $("instanceAccessStatusV1").textContent="Loading Vodia Marketplace instances for this customer…";
    try{
      const result=await callTool("aws_list_customer_ec2_instances",{
        customerId:scope,includeTerminated:false
      });
      if(result?.isError) throw new Error(toolErrorText(result)||"EC2 inventory unavailable.");
      if(request!==instanceAccessRequestV1 || scope!==customerId() ||
         !currentAwsConnection?.configured) return;
      const data=dataFrom(result);
      const errors=Array.isArray(data?.regionErrors)?data.regionErrors:[];
      const rows=Array.isArray(data?.instances)?data.instances:[];
      instanceAccessRowsV1=rows.filter(row=>
        row?.managedByVodia===true &&
        row.vodiaMarketplaceProductId===VODIA_MARKETPLACE_PRODUCT_ID &&
        row.vodiaMspCustomerId===scope &&
        row.state!=="terminated" &&
        /^i-[0-9a-f]+$/.test(row.instanceId||"") &&
        /^[-a-z0-9]+$/.test(row.region||""));
      const select=$("instanceAccessSelectV1");
      for(const row of instanceAccessRowsV1){
        const label=(row.name||"Vodia PBX")+" · "+row.instanceId+" · "+row.region+" · "+row.state;
        select.add(new Option(label,row.region+"/"+row.instanceId));
      }
      select.disabled=instanceAccessRowsV1.length===0;
      $("instanceAccessStatusV1").textContent=instanceAccessRowsV1.length+
        " matching Vodia PBX instance(s)."+
        (errors.length?" "+errors.length+" region(s) could not be checked; refresh or inspect AWS before relying on this list.":"")+
        (instanceAccessRowsV1.length?" Choose the exact instance to manage.":
          " Older or untagged deployments need their ownership verified in AWS before they can appear here.");
    }catch(error){
      if(request===instanceAccessRequestV1 && scope===customerId()){
        clearInstanceAccessV1(error?.message||"EC2 inventory unavailable.");
      }
    }finally{
      if(request===instanceAccessRequestV1){
        $("instanceAccessRefreshV1").disabled=false;
        reportSize();
      }
    }
  }

  function installInstanceAccessNavigationV1(){
    const makeButton=(mount)=>{
      const button=document.createElement("button");
      button.className="secondary";button.type="button";
      button.textContent="Manage an existing PBX instance";
      button.addEventListener("click",()=>setStep(5));
      mount?.appendChild(button);
    };
    makeButton($("customerPanel"));
    makeButton($("reviewStepPanel"));
    $("instanceAccessBackV1").addEventListener("click",()=>setStep(1));
    $("instanceAccessRefreshV1").addEventListener("click",refreshInstanceAccessV1);
    $("instanceAccessSelectV1").addEventListener("change",renderInstanceAccessV1);
  }

'''
s=replace_once(s,'  function setStep(step){',logic+'  function setStep(step){','instance access functions')
s=replace_once(s,'  consolidateGuidedLayout();',
               '  consolidateGuidedLayout();\n  installInstanceAccessNavigationV1();',
               'access navigation initialization')

old_uris=re.findall(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html',t)
if len(old_uris)!=1:
    raise SystemExit(f'PATCH ERROR: expected one guided resource URI, found {len(old_uris)}')
# v82 updates the connector only, so its guided UI resource may still say v81.
t=t.replace(old_uris[0],new_uri,1)
ui.write_text(s)
resource.write_text(t)
print('PASS: staged page 5 with instance selection, PBX link and machine link')
PY

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
html=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',html,re.S|re.I)
if not scripts: raise SystemExit('VALIDATION ERROR: inline script missing')
Path(sys.argv[2]).write_text('\n'.join(scripts))
for marker in ('VODIA_INSTANCE_ACCESS_CARD_V1', 'instanceAccessPanelV1:step===5',
               'aws_list_customer_ec2_instances','row.vodiaMspCustomerId===scope'):
    if marker not in html: raise SystemExit('VALIDATION ERROR: missing '+marker)
PY
node --check "$TMP/staged/inline.js"
node --check "$TMP/staged/msp-guided-app-v1.js"
echo "PASS: staged UI and guided resource JavaScript parse"

if [[ "$MODE" == --dry-run ]]; then
  echo "DRY RUN PASS: $CURRENT instance access card is ready; live files unchanged."
  exit 0
fi

BACKUP_DIR="$BACKUP_ROOT/vodia-mcp-instance-access-v1-$STAMP"
mkdir -p "$BACKUP_DIR"
cp -a "$UI" "$BACKUP_DIR/msp-guided-app.html"
cp -a "$GUIDED" "$BACKUP_DIR/msp-guided-app-v1.js"
INSTALLED=1
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app.html" "$UI"
install -o root -g root -m 0644 "$TMP/staged/msp-guided-app-v1.js" "$GUIDED"
systemctl restart "$SERVICE"
HEALTH=""
for _ in {1..20}; do
  if HEALTH="$(curl -fsS "$HEALTH_URL" 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || fail "MCP health check failed"
grep -Fq "\"version\":\"$CURRENT\"" <<<"$HEALTH" || fail "health reports an unexpected version"
grep -Fq 'VODIA_INSTANCE_ACCESS_CARD_V1' "$UI" || fail "live card not present"
echo "PASS: instance access card installed; MCP remains at $CURRENT"
echo "Backup: $BACKUP_DIR"
echo "Open Vodia Setup in a NEW message to load the updated UI resource."
