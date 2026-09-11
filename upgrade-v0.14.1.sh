#!/usr/bin/env bash
set -Eeuo pipefail

PACKAGE="vodia-mcp-v0.14.1-complete-api.zip"
APP_DIR="${APP_DIR:-/opt/vodia-mcp}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/vodia-mcp-backups}"
SERVICE="${SERVICE:-vodia-mcp}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${BACKUP_ROOT}/${STAMP}"
TMPDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this upgrade script as root (sudo)." >&2
  exit 1
fi

for cmd in unzip systemctl cp mkdir node npm find chmod chown; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

[[ -f "$PACKAGE" ]] || { echo "Package not found in current directory: $PACKAGE" >&2; exit 1; }
[[ -d "$APP_DIR" ]] || { echo "Application directory not found: $APP_DIR" >&2; exit 1; }

mkdir -p "$BACKUP_DIR"
echo "Backing up $APP_DIR to $BACKUP_DIR ..."
cp -a "$APP_DIR/." "$BACKUP_DIR/"

unzip -q "$PACKAGE" -d "$TMPDIR"
RELEASE_DIR="$TMPDIR/vodia-mcp"
[[ -f "$RELEASE_DIR/package.json" ]] || { echo "Release package is missing vodia-mcp/package.json" >&2; exit 1; }

PACKAGE_VERSION="$(node -p "require('$RELEASE_DIR/package.json').version")"
[[ "$PACKAGE_VERSION" == "0.14.1" ]] || { echo "Expected package version 0.14.1, found $PACKAGE_VERSION" >&2; exit 1; }

echo "Stopping $SERVICE ..."
systemctl stop "$SERVICE"

# The release ZIP contains a top-level vodia-mcp/ directory. Copy the CONTENTS
# of that directory into /opt/vodia-mcp rather than nesting vodia-mcp/vodia-mcp.
echo "Installing Vodia MCP $PACKAGE_VERSION ..."
cp -a "$RELEASE_DIR/." "$APP_DIR/"

cd "$APP_DIR"
echo "Installing locked production Node dependencies ..."
npm ci --omit=dev

# systemd runs the service as User=vodiamcp. Keep application files root-owned
# but ensure the service user can traverse directories and read the application.
chown -R root:root "$APP_DIR"
find "$APP_DIR" -type d -exec chmod 755 {} \;
find "$APP_DIR" -type f -exec chmod 644 {} \;
find "$APP_DIR" -type f -name "*.sh" -exec chmod 755 {} \;

INSTALLED_VERSION="$(node -p "require('$APP_DIR/package.json').version")"
[[ "$INSTALLED_VERSION" == "0.14.1" ]] || {
  echo "Installed version check failed: expected 0.14.1, found $INSTALLED_VERSION" >&2
  echo "Backup retained at $BACKUP_DIR" >&2
  exit 1
}

echo "Starting $SERVICE ..."
systemctl restart "$SERVICE"
sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
  echo "Service failed to start. Backup retained at $BACKUP_DIR" >&2
  systemctl --no-pager --full status "$SERVICE" || true
  exit 1
fi

HEALTH="$(curl -fsS http://127.0.0.1:3100/health)"
HEALTH_VERSION="$(node -e 'const d=JSON.parse(process.argv[1]);process.stdout.write(String(d.version||""))' "$HEALTH")"
[[ "$HEALTH_VERSION" == "0.14.1" ]] || {
  echo "Health check version mismatch: expected 0.14.1, found ${HEALTH_VERSION:-unknown}" >&2
  echo "$HEALTH" >&2
  exit 1
}

systemctl --no-pager --full status "$SERVICE" || true

echo
echo "Upgrade completed successfully."
echo "Installed version: $INSTALLED_VERSION"
echo "Health version: $HEALTH_VERSION"
echo "Backup: $BACKUP_DIR"
echo "Next: run the OAuth/DCR and Vodia read-only API smoke tests before production use."
