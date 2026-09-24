#!/usr/bin/env bash
# Capture and validate the running Vodia MCP before the instance access UI change.
set -Eeuo pipefail

MODE="${1:---explain}"
case "$MODE" in
  --explain|--create|--verify) ;;
  *) echo "Usage: bash $0 [--explain | --create | --verify ARCHIVE]" >&2; exit 2 ;;
esac

explain(){
  cat <<'TEXT'
Create a verified, root-only rollback checkpoint of the live Vodia MCP.

The backup includes the complete /opt/vodia-mcp application, the complete
/var/lib/vodia-mcp data directory, /etc/vodia-mcp.env, systemd unit and
drop-ins, and optional Caddyfile. It records the running MCP version, briefly
stops the service for a consistent snapshot, restarts it, and confirms the
health version has not changed. The archive is unpacked into a temporary
directory and checked before it is marked verified.

It does NOT apply the instance-access card or change AWS/PBX resources.
Expect a brief MCP interruption while files are copied. The archive contains
credentials and must remain root-only; do not upload it to GitHub.

  sudo bash this-file.sh --create
  sudo bash this-file.sh --verify /opt/vodia-mcp-backups/ARCHIVE.tar.gz

The verified archive path is written to:
  /opt/vodia-mcp-backups/vodia-mcp-pre-instance-access-v1.latest
The card installer requires a verified, matching checkpoint before --apply.
TEXT
}
if [[ "$MODE" == --explain ]]; then explain; exit 0; fi

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
DATA="${VODIA_MCP_DATA_DIR:-/var/lib/vodia-mcp}"
ENV_FILE="${VODIA_MCP_ENV_FILE:-/etc/vodia-mcp.env}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
HEALTH_URL="${VODIA_MCP_HEALTH_URL:-http://127.0.0.1:3100/health}"
BACKUP_ROOT="${VODIA_MCP_FULL_BACKUP_ROOT:-/opt/vodia-mcp-backups}"
LATEST="$BACKUP_ROOT/vodia-mcp-pre-instance-access-v1.latest"
STAGE=""
VERIFY_STAGE=""
ARCHIVE=""
STOPPED=0
ARCHIVE_CREATED=0
VERIFIED=0

fail(){ echo "FAIL: $*" >&2; exit 1; }
cleanup(){
  local rc=$?
  trap - EXIT
  if (( STOPPED )); then
    echo "Attempting to restart $SERVICE after backup error…" >&2
    systemctl restart "$SERVICE" || true
  fi
  if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
  if [[ -n "$VERIFY_STAGE" && -d "$VERIFY_STAGE" ]]; then rm -rf -- "$VERIFY_STAGE"; fi
  if (( ARCHIVE_CREATED && ! VERIFIED )); then
    # Never leave an apparently complete archive if integrity verification fails.
    rm -f -- "$ARCHIVE" "$ARCHIVE.sha256" "$ARCHIVE.verified.json"
  fi
  exit "$rc"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "run as root"
for c in python3 node curl systemctl tar sha256sum stat cmp; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done

health_version(){
  curl -fsS --max-time 8 "$HEALTH_URL" | python3 -c \
    'import json,sys; v=json.load(sys.stdin).get("version",""); assert v; print(v)'
}

verify_archive(){
  local archive="$1" checkpoint="$1.verified.json" unpack manifest_version
  [[ -f "$archive" && -f "$archive.sha256" ]] || fail "archive or checksum missing"
  [[ "$(stat -c %u "$archive")" == 0 ]] || fail "backup archive must be root owned"
  [[ "$(stat -c %a "$archive")" == 600 ]] || fail "backup archive must be mode 600"
  ( cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive.sha256")" )
  tar -tzf "$archive" >/dev/null || fail "archive listing failed"
  unpack="$(mktemp -d "$BACKUP_ROOT/.verify.XXXXXXXX")"
  VERIFY_STAGE="$unpack"
  tar -C "$unpack" -xzf "$archive" --no-same-owner
  for item in "opt/vodia-mcp/index.js" "opt/vodia-mcp/version.js" \
              "opt/vodia-mcp/ui/msp-guided-app.html" \
              "opt/vodia-mcp/msp-guided-app-v1.js" \
              "etc/vodia-mcp.env" "var/lib/vodia-mcp/auth.db" \
              "MANIFEST.json" "CHECKSUMS.sha256" "RESTORE.txt"; do
    [[ -f "$unpack/$item" ]] || fail "missing $item in archive"
  done
  ( cd "$unpack" && sha256sum -c CHECKSUMS.sha256 >/dev/null ) || fail "file checksum validation failed"
  node --check "$unpack/opt/vodia-mcp/index.js" >/dev/null
  node --check "$unpack/opt/vodia-mcp/version.js" >/dev/null
  node --check "$unpack/opt/vodia-mcp/msp-guided-app-v1.js" >/dev/null
  python3 - "$unpack/var/lib/vodia-mcp/auth.db" "$unpack/MANIFEST.json" <<'PY'
import json,sqlite3,sys
from pathlib import Path
database,manifest=Path(sys.argv[1]),json.loads(Path(sys.argv[2]).read_text())
assert manifest.get('format')=='vodia-mcp-pre-instance-access-v1'
assert manifest.get('version') in ('0.14.9.81','0.14.9.82')
assert manifest.get('health_before')==manifest.get('version')
assert manifest.get('health_after')==manifest.get('version')
with sqlite3.connect(f'file:{database}?mode=ro',uri=True) as con:
    result=con.execute('PRAGMA quick_check').fetchone()
assert result==('ok',),f'auth.db quick_check failed: {result}'
print('PASS: extracted code, SQLite database, manifest and file checksums')
PY
  if [[ "$MODE" == --create ]]; then
    python3 - "$archive" "$unpack/MANIFEST.json" "$checkpoint" <<'PY'
import hashlib,json,os,socket,sys
from pathlib import Path
archive,manifest_path,receipt_path=map(Path,sys.argv[1:])
manifest=json.loads(manifest_path.read_text())
h=hashlib.sha256()
with archive.open('rb') as f:
    for block in iter(lambda:f.read(1024*1024),b''): h.update(block)
receipt={'format':'vodia-mcp-pre-instance-access-v1',
         'archive':str(archive.resolve()),'sha256':h.hexdigest(),
         'hostname':socket.gethostname(),'version':manifest['version'],
         'files':manifest['files'],'verified':True}
receipt_path.write_text(json.dumps(receipt,sort_keys=True,indent=2)+'\n')
os.chmod(receipt_path,0o600)
PY
  fi
  rm -rf -- "$unpack"
  VERIFY_STAGE=""
  echo "PASS: archive unpacks and validates: $archive"
}

mkdir -p "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
if [[ "$MODE" == --verify ]]; then
  [[ $# -eq 2 ]] || fail "supply exactly one archive path"
  ARCHIVE="$2"
  [[ "$ARCHIVE" == "$BACKUP_ROOT"/* ]] || fail "archive must be in $BACKUP_ROOT"
  verify_archive "$ARCHIVE"
  exit 0
fi
[[ $# -eq 1 ]] || fail "--create takes no archive argument"

for item in "$APP/package.json" "$APP/index.js" "$APP/version.js" \
            "$APP/ui/msp-guided-app.html" "$APP/msp-guided-app-v1.js" \
            "$ENV_FILE" "$DATA/auth.db"; do
  [[ -f "$item" ]] || fail "required live file missing: $item"
done
[[ "$APP" == /opt/vodia-mcp && "$DATA" == /var/lib/vodia-mcp && \
   "$ENV_FILE" == /etc/vodia-mcp.env ]] || fail "nonstandard app/data/env paths need a tailored restore plan"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active; this is not a known-good checkpoint"
BEFORE="$(health_version)" || fail "local MCP health failed before snapshot"
case "$BEFORE" in 0.14.9.81|0.14.9.82) ;; *) fail "unsupported live MCP version $BEFORE" ;; esac
LIVE_VERSION="$(node -p "require('$APP/package.json').version")" || fail "package version unavailable"
echo "Health version: $BEFORE; package version: $LIVE_VERSION"

STAMP="$(date -u +%Y%m%d-%H%M%S)"
NAME="vodia-mcp-pre-instance-access-v1-$STAMP"
STAGE="$(mktemp -d "$BACKUP_ROOT/.${NAME}.XXXXXXXX")"
chmod 700 "$STAGE"
ARCHIVE="$BACKUP_ROOT/$NAME.tar.gz"
[[ ! -e "$ARCHIVE" ]] || fail "archive exists: $ARCHIVE"

echo "Capturing a consistent MCP snapshot (brief service interruption)…"
STOPPED=1
systemctl stop "$SERVICE"
mkdir -p "$STAGE/opt" "$STAGE/var/lib" "$STAGE/etc" \
         "$STAGE/etc/systemd/system" "$STAGE/lib/systemd/system" \
         "$STAGE/usr/lib/systemd/system"
cp -a "$APP" "$STAGE/opt/vodia-mcp"
cp -a "$DATA" "$STAGE/var/lib/vodia-mcp"
cp -a "$ENV_FILE" "$STAGE/etc/vodia-mcp.env"
for unit in \
  /etc/systemd/system/vodia-mcp.service \
  /lib/systemd/system/vodia-mcp.service \
  /usr/lib/systemd/system/vodia-mcp.service; do
  if [[ -f "$unit" ]]; then cp -a "$unit" "$STAGE${unit}"; fi
done
if [[ -d /etc/systemd/system/vodia-mcp.service.d ]]; then
  cp -a /etc/systemd/system/vodia-mcp.service.d "$STAGE/etc/systemd/system/"
fi
if [[ -f /etc/caddy/Caddyfile ]]; then
  mkdir -p "$STAGE/etc/caddy"
  cp -a /etc/caddy/Caddyfile "$STAGE/etc/caddy/Caddyfile"
fi
systemctl restart "$SERVICE"
STOPPED=0
AFTER=""
for _ in {1..25}; do
  if AFTER="$(health_version 2>/dev/null)"; then break; fi
  sleep 1
done
[[ "$AFTER" == "$BEFORE" ]] || fail "health changed after snapshot: before=$BEFORE after=${AFTER:-unavailable}"
systemctl is-active --quiet "$SERVICE" || fail "service inactive after snapshot"
echo "PASS: MCP running at $AFTER after copy"

python3 - "$STAGE" "$BEFORE" "$LIVE_VERSION" <<'PY'
import hashlib,json,socket,sys
from datetime import datetime,timezone
from pathlib import Path
stage=Path(sys.argv[1]);version,package_version=sys.argv[2:]
files={}
for rel in ['opt/vodia-mcp/index.js','opt/vodia-mcp/version.js',
            'opt/vodia-mcp/ui/msp-guided-app.html',
            'opt/vodia-mcp/msp-guided-app-v1.js',
            'opt/vodia-mcp/aws-marketplace-ec2-deploy-v1.js']:
    file=stage/rel
    if file.is_file(): files[rel]=hashlib.sha256(file.read_bytes()).hexdigest()
manifest={'format':'vodia-mcp-pre-instance-access-v1',
          'created_utc':datetime.now(timezone.utc).isoformat(),
          'hostname':socket.gethostname(),'version':version,
          'package_version':package_version,
          'health_before':version,'health_after':version,'files':files}
p=stage/'MANIFEST.json';p.write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n');p.chmod(0o600)
PY

cat > "$STAGE/RESTORE.txt" <<'TEXT'
This checkpoint includes secrets. Keep archive and checksum root-only on this host.

To restore this version after an unsuccessful UI update:
1. Run backup-vodia-mcp-pre-instance-access-v1.sh --verify ARCHIVE.
2. Save a separate copy of the current (possibly broken) app and data.
3. Extract the verified archive into a new root-only temporary directory.
4. Stop vodia-mcp; move /opt/vodia-mcp and /var/lib/vodia-mcp aside.
5. Copy the saved opt/vodia-mcp, var/lib/vodia-mcp and etc/vodia-mcp.env
   from that directory into their original absolute paths, preserving modes.
6. Restore the saved systemd unit and drop-ins if they changed, run
   systemctl daemon-reload and restart vodia-mcp.
7. Confirm http://127.0.0.1:3100/health reports the archived version,
   then open a fresh Vodia Setup card and verify an authenticated read.
The service environment, data directory and systemd configuration are
included. If restoring Caddyfile, validate it and reload Caddy separately.
TEXT
chmod 600 "$STAGE/RESTORE.txt"
( cd "$STAGE" && find . -type f ! -name CHECKSUMS.sha256 -print0 | sort -z | xargs -0 sha256sum > CHECKSUMS.sha256 )
chmod 600 "$STAGE/CHECKSUMS.sha256"
ARCHIVE_CREATED=1
tar -C "$STAGE" -czpf "$ARCHIVE" .
chmod 600 "$ARCHIVE"
( cd "$BACKUP_ROOT" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE.sha256")" )
chmod 600 "$ARCHIVE.sha256"
verify_archive "$ARCHIVE"
VERIFIED=1
printf '%s\n' "$ARCHIVE" > "$LATEST"
chmod 600 "$LATEST"
echo "VERIFIED BACKUP: $ARCHIVE"
echo "Receipt: $ARCHIVE.verified.json"
echo "Pointer: $LATEST"
echo "The instance-access patch has NOT been applied."
