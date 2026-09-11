#!/usr/bin/env bash
set -euo pipefail

PACKAGE="vodia-mcp-v0.14.1-complete-api.zip"
APP_DIR="${APP_DIR:-/opt/vodia-mcp}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/vodia-mcp-backups}"
SERVICE="${SERVICE:-vodia-mcp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this upgrade script as root (sudo)." >&2
  exit 1
fi

for cmd in unzip systemctl cp mkdir; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

[[ -f "$PACKAGE" ]] || { echo "Package not found in current directory: $PACKAGE" >&2; exit 1; }
[[ -d "$APP_DIR" ]] || { echo "Application directory not found: $APP_DIR" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
echo "Backing up $APP_DIR to $BACKUP_DIR ..."
cp -a "$APP_DIR/." "$BACKUP_DIR/"

echo "Stopping $SERVICE ..."
systemctl stop "$SERVICE"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
unzip -q "$PACKAGE" -d "$TMPDIR"

# Copy release contents over the existing installation without deleting local files.
cp -a "$TMPDIR/." "$APP_DIR/"

if [[ -f "$APP_DIR/package.json" ]] && command -v npm >/dev/null 2>&1; then
  echo "Installing production Node dependencies ..."
  (cd "$APP_DIR" && npm install --omit=dev)
fi

echo "Starting $SERVICE ..."
systemctl start "$SERVICE"
systemctl --no-pager --full status "$SERVICE" || true

echo
echo "Upgrade installed."
echo "Backup: $BACKUP_DIR"
echo "Next: run the OAuth/DCR and Vodia read-only API smoke tests before production use."
