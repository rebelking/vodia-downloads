#!/usr/bin/env bash
# Copy the code-only firewall collector archive to an SSH user's private home.
# The archive remains on this EC2 host; this script does not send it to GitHub.
set -Eeuo pipefail

usage() {
  echo "Usage: sudo bash $0 [--user ubuntu] [--archive /tmp/vodia-mcp-firewall-code-YYYYMMDD-HHMMSS.tar.gz]" >&2
  exit 2
}

TARGET_USER=ubuntu
ARCHIVE=/tmp/vodia-mcp-firewall-code-20260924-203445.tar.gz
while (($#)); do
  case "$1" in
    --user) (($# >= 2)) || usage; TARGET_USER="$2"; shift 2 ;;
    --archive) (($# >= 2)) || usage; ARCHIVE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

((EUID == 0)) || { echo 'Run with sudo or as root.' >&2; exit 1; }
[[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { echo 'Invalid SSH username.' >&2; exit 1; }
[[ -f "$ARCHIVE" && ! -L "$ARCHIVE" ]] || { echo "Archive not found: $ARCHIVE" >&2; exit 1; }
PASSWD_RECORD="$(getent passwd "$TARGET_USER")" || { echo "SSH user not found: $TARGET_USER" >&2; exit 1; }
IFS=: read -r _ _ _ _ _ USER_HOME _ <<< "$PASSWD_RECORD"
[[ -d "$USER_HOME" && ! -L "$USER_HOME" ]] || { echo 'SSH user home is missing or a symlink.' >&2; exit 1; }

# Verify the bundle contains exactly the four code files from the collector.
python3 - "$ARCHIVE" <<'PY'
import sys, tarfile
required = {
    'aws-marketplace-ec2-deploy-v1.js',
    'ui/msp-guided-app.html',
    'msp-guided-app-v1.js',
    'version.js',
}
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    members = archive.getmembers()
    if len(members) != len(required) or any(
        not member.isfile() or member.name not in required for member in members
    ):
        raise SystemExit('Archive is not the expected four-file code bundle; no copy made.')
print('PASS: archive contains the four expected code files.')
PY

DESTINATION="$USER_HOME/$(basename "$ARCHIVE")"
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || {
  echo "Destination already exists; refusing to overwrite: $DESTINATION" >&2; exit 1;
}
install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0600 "$ARCHIVE" "$DESTINATION"
echo "Private SSH download path: $DESTINATION"
sha256sum "$DESTINATION"
echo "From your own computer, use SFTP or scp to download $TARGET_USER@MCP_PUBLIC_IP:$DESTINATION"
echo 'Then attach the downloaded .tar.gz file in this chat.'
