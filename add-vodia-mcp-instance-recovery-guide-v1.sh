#!/usr/bin/env bash
# On-screen recovery instructions for the installed instance access card.
set -Eeuo pipefail
MODE="${1:---explain}"
case "$MODE" in --explain|--dry-run|--apply) ;; *) echo "Usage: bash $0 [--explain|--dry-run|--apply]" >&2; exit 2;; esac

if [[ "$MODE" == --explain ]]; then
  cat <<'TEXT'
Clarify the fifth card: changing a known administrator password happens in
the PBX web UI; forgotten administrator access requires console access to
the SELECTED EC2 machine and planned PBX downtime. The new expandable guide
links to Vodia's documented stop/start/manual recovery procedure. No password
is entered into the MCP; no command is sent to the instance. Only the guided
UI HTML and its cache resource URI change. The Chime patch is unaffected.

--dry-run stages and validates without changing live files.
--apply requires a current verified whole-MCP backup, creates per-file copies,
then installs and restarts; failure restores the previous two files.
TEXT
  exit 0
fi

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
UI="$APP/ui/msp-guided-app.html"
GUIDED="$APP/msp-guided-app-v1.js"
BACKEND="$APP/aws-marketplace-ec2-deploy-v1.js"
VERSION="$APP/version.js"
HEALTH_URL="${VODIA_MCP_HEALTH_URL:-http://127.0.0.1:3100/health}"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
BACKUP_DIR=""
INSTALLED=0
fail(){ echo "FAIL: $*" >&2; exit 1; }
cleanup(){
  rc=$?
  if (( rc != 0 && INSTALLED )); then
    echo "Restoring previous guided UI from $BACKUP_DIR" >&2
    cp -a "$BACKUP_DIR/msp-guided-app.html" "$UI" || true
    cp -a "$BACKUP_DIR/msp-guided-app-v1.js" "$GUIDED" || true
    systemctl restart "$SERVICE" || true
  fi
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "run as root"
for c in python3 node curl systemctl install; do command -v "$c" >/dev/null || fail "$c is required"; done
for f in "$UI" "$GUIDED" "$BACKEND" "$VERSION"; do [[ -f "$f" ]] || fail "missing $f"; done
CURRENT="$(python3 - "$VERSION" <<'PY'
from pathlib import Path
import re,sys
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',Path(sys.argv[1]).read_text())
print(m.group(1) if m else '',end='')
PY
)"
[[ "$CURRENT" == 0.14.9.81 || "$CURRENT" == 0.14.9.82 ]] || fail "unexpected MCP version $CURRENT"
python3 - "$UI" "$BACKEND" <<'PY'
from pathlib import Path
import sys
ui,backend=(Path(f).read_text() for f in sys.argv[1:])
if 'VODIA_INSTANCE_ACCESS_CARD_V1' not in ui or 'VODIA_INSTANCE_ACCESS_INVENTORY_V3' not in backend:
    raise SystemExit('PATCH ERROR: original instance access card/backend missing; no live changes')
PY

if [[ "$MODE" == --apply ]]; then
  POINTER="${VODIA_MCP_FULL_BACKUP_ROOT:-/opt/vodia-mcp-backups}/vodia-mcp-pre-instance-access-v1.latest"
  [[ -f "$POINTER" ]] || fail "create fresh full backup with /tmp/vodia-mcp-backup.sh --create"
  ARCHIVE="$(cat "$POINTER")"
  python3 - "$ARCHIVE" "$CURRENT" "$APP" <<'PY'
from pathlib import Path
import hashlib,json,socket,sys
archive,version,app=Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3])
receipt=Path(str(archive)+'.verified.json')
def check(ok,message):
    if not ok: raise SystemExit('FAIL: '+message)
check(archive.is_file() and receipt.is_file(),'full MCP archive or verified receipt missing')
check(archive.stat().st_uid==0 and receipt.stat().st_uid==0,'archive and receipt must be root-owned')
check(archive.stat().st_mode & 0o777==0o600,'archive must be mode 600')
r=json.loads(receipt.read_text())
check(r.get('format')=='vodia-mcp-pre-instance-access-v1' and r.get('verified') is True,
      'full archive was not verified')
check(r.get('archive')==str(archive.resolve()) and r.get('hostname')==socket.gethostname(),
      'checkpoint archive/host mismatch')
check(r.get('version')==version,'backup version mismatch')
h=hashlib.sha256()
with archive.open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
check(h.hexdigest()==r.get('sha256'),'full archive checksum mismatch')
for rel in ('index.js','version.js','ui/msp-guided-app.html',
            'msp-guided-app-v1.js','aws-marketplace-ec2-deploy-v1.js'):
    path=app/rel
    expected=r.get('files',{}).get('opt/vodia-mcp/'+rel)
    check(path.is_file() and expected and hashlib.sha256(path.read_bytes()).hexdigest()==expected,
          'live code differs from verified full backup: '+rel+'; make a new checkpoint')
print('PASS: current live MCP matches verified full backup')
PY
  systemctl is-active --quiet "$SERVICE" || fail "MCP service is inactive"
  BEFORE_HEALTH="$(curl -fsS "$HEALTH_URL")" || fail "MCP health unavailable"
  [[ "$BEFORE_HEALTH" == *"\"version\":\"$CURRENT\""* ]] || fail "health version mismatch"
fi

mkdir -p "$TMP/staged"
cp -a "$UI" "$TMP/staged/msp-guided-app.html"
cp -a "$GUIDED" "$TMP/staged/msp-guided-app-v1.js"
python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/msp-guided-app-v1.js" "$CURRENT" <<'PY'
from pathlib import Path
import re,sys
ui,resource,version=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
s,t=ui.read_text(),resource.read_text()
marker='VODIA_INSTANCE_RECOVERY_GUIDE_V1'
if marker in s:
    if '-instance-access-v2/mcp-app.html' not in t:
        raise SystemExit('PATCH ERROR: recovery guide installed without updated URI')
    print('PASS: recovery guide already present')
    raise SystemExit(0)
def replace_once(old,new,label):
    global s
    count=s.count(old)
    if count!=1: raise SystemExit(f'PATCH ERROR: {label} anchor expected once, found {count}')
    s=s.replace(old,new,1)
replace_once('Open PBX to change administrator password',
             'Open PBX to change a known administrator password','PBX login action')
anchor='''          <p class="instance-access-help-v1"><a href="https://doc.vodia.com/docs/login" target="_blank" rel="noopener noreferrer">Vodia administrator login instructions</a> · <a href="https://doc.vodia.com/docs/admin-security-users" target="_blank" rel="noopener noreferrer">Create a separate vendor administrator</a></p>'''
guide='''          <!-- VODIA_INSTANCE_RECOVERY_GUIDE_V1 -->
          <details class="instance-access-help-v1" style="margin:12px 0">
            <summary>Lost administrator access? Open recovery steps for this PBX</summary>
            <p>Recovery requires access to this instance's operating system. It stops the PBX service and interrupts calls. Schedule it for a maintenance window. This panel sends no commands and collects no passwords.</p>
            <ol>
              <li>Open <strong>machine access in AWS</strong> above for the selected instance. Connect by your configured SSH or Session Manager access. Verify the instance and PBX service before stopping anything.</li>
              <li>Stop the PBX service. On a Debian installation using the documented service name: <code>sudo systemctl stop pbx</code>.</li>
              <li>In the PBX directory (commonly <code>/usr/local/pbx</code>), start it manually using Vodia's documented Linux recovery option: <code>./pbxctrl --no-daemon --admin-username admin --admin-password</code>. Follow the vendor procedure for the username and password arguments for your installed version.</li>
              <li>Open the PBX web login and set a new administrator password there. Then stop the manual process and start the normal PBX service again. Confirm the service and calls are working.</li>
            </ol>
            <p><a href="https://doc.vodia.com/docs/login#admin-password-reset" target="_blank" rel="noopener noreferrer">Official Vodia administrator recovery procedure</a>. Keep the replacement password out of MCP Debug, shell history and command logs.</p>
          </details>
'''
replace_once(anchor,anchor+'\n'+guide,'recovery guide mount')
old=re.findall(r'ui://vodia/msp-guided/v0\.14\.9\.\d+-instance-access-v1/mcp-app\.html',t)
if len(old)!=1: raise SystemExit(f'PATCH ERROR: guided URI anchor expected once, found {len(old)}')
t=t.replace(old[0],f'ui://vodia/msp-guided/v{version}-instance-access-v2/mcp-app.html',1)
ui.write_text(s)
resource.write_text(t)
print('PASS: staged recovery guide for the selected instance')
PY

python3 - "$TMP/staged/msp-guided-app.html" "$TMP/staged/inline.js" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text()
scripts=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',s,re.S|re.I)
if not scripts: raise SystemExit('PATCH ERROR: inline script missing')
Path(sys.argv[2]).write_text('\n'.join(scripts))
PY
node --check "$TMP/staged/inline.js"
node --check "$TMP/staged/msp-guided-app-v1.js"
echo "PASS: staged guided UI JavaScript parses"
if [[ "$MODE" == --dry-run ]]; then
  echo "DRY RUN PASS: live MCP unchanged; verified recovery guide ready."
  exit 0
fi

BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-instance-recovery-guide-v1-$STAMP"
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
[[ "$HEALTH" == *"\"version\":\"$CURRENT\""* ]] || fail "service health/version check failed"
grep -Fq 'VODIA_INSTANCE_RECOVERY_GUIDE_V1' "$UI" || fail "recovery guide missing after install"
echo "PASS: selected-instance recovery guide installed; MCP remains $CURRENT"
echo "Per-file backup: $BACKUP_DIR"
echo "Open Vodia Setup in a new message to load the updated resource."
