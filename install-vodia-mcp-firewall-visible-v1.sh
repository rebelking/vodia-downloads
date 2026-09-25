#!/usr/bin/env bash
# Moves firewall preset controls into visible one-click Step 3 on MCP 0.14.9.84.
set -Eeuo pipefail
MODE=${1:---dry-run}
[[ $MODE == --dry-run || $MODE == --apply ]] || { echo 'Usage: sudo bash script [--dry-run|--apply]' >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
APP=/opt/vodia-mcp
PAYLOAD_URL=https://raw.githubusercontent.com/rebelking/vodia-downloads/649792993b8d7f6e9ec9ad8def6643a264a53730/patches/vodia-mcp-firewall-visible-v1.tar.gz.b64
PAYLOAD_SHA=87015dd83734c2901e4bcf516c982e6f87b815ed60097b4e57aadb7896b5c624
STAGE=$(mktemp -d /tmp/vodia-firewall-visible-v1.XXXXXXXX)
chmod 700 "$STAGE"
PATCH_STARTED=0
cleanup(){
  local rc=$?
  trap - EXIT
  if (( PATCH_STARTED && rc != 0 )); then
    echo 'Patch interrupted; restoring the four prepatch application files…' >&2
    for file in aws-marketplace-ec2-deploy-v1.js ui/msp-guided-app.html msp-guided-app-v1.js version.js; do
      if [[ -f "$STAGE/rollback/$file" ]]; then
        cp -p "$STAGE/rollback/$file" "$APP/$file" || true
      fi
    done
    systemctl restart vodia-mcp || true
  fi
  rm -rf -- "$STAGE"
  exit "$rc"
}
trap cleanup EXIT
fail(){ echo "PATCH ERROR: $*" >&2; exit 1; }
for bin in curl tar sha256sum python3 node systemctl base64; do command -v "$bin" >/dev/null || fail "$bin unavailable"; done
curl -fLsS --retry 2 -o "$STAGE/payload.b64" "$PAYLOAD_URL" || fail 'payload download failed'
base64 -d "$STAGE/payload.b64" > "$STAGE/payload.tar.gz" || fail 'payload decoding failed'
echo "$PAYLOAD_SHA  $STAGE/payload.tar.gz" | sha256sum -c - || fail 'patch payload checksum differs'
mkdir "$STAGE/files"
tar -xzf "$STAGE/payload.tar.gz" -C "$STAGE/files" --no-same-owner || fail 'payload extraction failed'
for file in aws-marketplace-ec2-deploy-v1.js ui/msp-guided-app.html msp-guided-app-v1.js version.js; do
  [[ -f "$APP/$file" && -f "$STAGE/files/$file" ]] || fail "missing required $file"
done
python3 - "$APP" "$STAGE/files" <<'PY'
import hashlib,sys
from pathlib import Path
app,stage=map(Path,sys.argv[1:])
expected={
'aws-marketplace-ec2-deploy-v1.js':'da6a603eacee35e5d5f4c70e61b6ae520c771ff2306b21677b7e13045276de24',
'ui/msp-guided-app.html':'017d42a83cad3f558ecad844a4b7202db53318cdf03bc737b53fb33fec12dbc7',
'msp-guided-app-v1.js':'111b80edd277b494c6cc5198eee3833a08458e0f1ec7c9c5e6c82b95afbdd3c1',
'version.js':'baac24cd5b7a5a01e4652a29aad243abe18cc6b6fd4dbe8e49950488af0a499a'}
for file,sha in expected.items():
  got=hashlib.sha256((app/file).read_bytes()).hexdigest()
  if got!=sha: raise SystemExit(f'PATCH ERROR: live {file} differs from verified source; no files changed')
assert 'VODIA_FIREWALL_PRESETS_V84' in (stage/'aws-marketplace-ec2-deploy-v1.js').read_text()
assert '0.14.9.85' in (stage/'version.js').read_text()
print('PASS: live 0.14.9.84 source matches verified code-only archive')
PY
node --input-type=module --check < "$STAGE/files/aws-marketplace-ec2-deploy-v1.js"
node --input-type=module --check < "$STAGE/files/msp-guided-app-v1.js"
node --input-type=module --check < "$STAGE/files/version.js"
python3 - "$STAGE/files/ui/msp-guided-app.html" "$STAGE/ui-check.js" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
assert text.count('<script>')==1 and text.count('</script>')==1
Path(sys.argv[2]).write_text(text.split('<script>')[1].split('</script>')[0])
PY
node --check "$STAGE/ui-check.js"
echo 'PASS: backend, UI, resource and version parse'
if [[ $MODE == --dry-run ]]; then
  echo 'DRY RUN PASS: live MCP unchanged; --apply creates a new full backup and installs the patch.'
  exit 0
fi
systemctl is-active --quiet vodia-mcp || fail 'MCP service is not active'
before=$(curl -fsS --max-time 8 http://127.0.0.1:3100/health | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])')
[[ $before == 0.14.9.84 ]] || fail "expected health 0.14.9.84; got $before"
backup_tool="$STAGE/files/tools/backup-mcp-before-firewall-visible-v1.sh"
[[ -f $backup_tool ]] || fail 'full backup helper missing'
chmod 700 "$backup_tool"
echo 'Creating a fresh, verified full MCP backup (brief service interruption)…'
bash "$backup_tool" --create || fail 'full backup did not verify'
archive=$(cat /opt/vodia-mcp-backups/vodia-mcp-pre-firewall-visible-v1.latest)
bash "$backup_tool" --verify "$archive" || fail 'full backup verification failed'
python3 - "$archive.verified.json" "$APP" <<'PY'
import hashlib,json,sys
from pathlib import Path
receipt=json.loads(Path(sys.argv[1]).read_text());app=Path(sys.argv[2])
assert receipt['verified'] and receipt['version']=='0.14.9.84'
for path in ['aws-marketplace-ec2-deploy-v1.js','ui/msp-guided-app.html','msp-guided-app-v1.js','version.js']:
  assert receipt['files']['opt/vodia-mcp/'+path]==hashlib.sha256((app/path).read_bytes()).hexdigest(),path
print('PASS: new full backup matches the live application')
PY
rollback="$STAGE/rollback"
mkdir -p "$rollback/ui"
for file in aws-marketplace-ec2-deploy-v1.js ui/msp-guided-app.html msp-guided-app-v1.js version.js; do
  cp -p "$APP/$file" "$rollback/$file"
done
install_files(){
  for file in aws-marketplace-ec2-deploy-v1.js ui/msp-guided-app.html msp-guided-app-v1.js version.js; do
    install -o "$(stat -c %u "$APP/$file")" -g "$(stat -c %g "$APP/$file")" -m "$(stat -c %a "$APP/$file")" "$1/$file" "$APP/$file.vodia-firewall-new"
    mv -f "$APP/$file.vodia-firewall-new" "$APP/$file"
  done
}
echo 'Installing the four reviewed code files…'
PATCH_STARTED=1
install_files "$STAGE/files"
if systemctl restart vodia-mcp; then
  after=''
  for attempt in {1..20}; do
    after=$(curl -fsS --max-time 4 http://127.0.0.1:3100/health 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["version"])' 2>/dev/null) && break
    sleep 1
  done
  if [[ $after == 0.14.9.85 ]]; then
    PATCH_STARTED=0
    echo "PASS: One-click firewall selector visible; MCP health $after"
    echo "Full verified backup: $archive"
    echo 'Open Vodia Setup in a NEW message to refresh the card.'
    exit 0
  fi
fi
echo 'Health check failed; restoring four original files…' >&2
fail "patch reverted to 0.14.9.84; verified full backup: $archive"
