# Upgrade Vodia MCP 0.13.2 to 0.14.0

This release adds OAuth and per-user identity. It preserves the existing Vodia
configuration, static MCP tokens, policy flags, audit log, supervised-learning
state and a complete rollback application directory.

## Before upgrading

Take an EC2 snapshot. Confirm the current version:

```bash
curl -fsS http://127.0.0.1:3100/health
node -p "require('/opt/vodia-mcp/package.json').version"
```

Both should report `0.13.2`.

## Upgrade

After uploading the three v0.14.0 release files to the GitHub download
repository, run:

```bash
cd /tmp
wget -O upgrade-vodia-mcp-v0.14.0.sh \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.0.sh
sudo bash upgrade-vodia-mcp-v0.14.0.sh
```

The script asks for the public MCP base URL and the initial OAuth administrator
when those values do not already exist. The default is
`https://mcp-test.tryvodia.com`.

For non-interactive installation, provide:

```bash
sudo env \
  VODIA_MCP_PUBLIC_BASE_URL=https://mcp-test.tryvodia.com \
  VODIA_OAUTH_ADMIN_EMAIL=admin@example.com \
  VODIA_OAUTH_ADMIN_NAME='PBX Administrator' \
  VODIA_OAUTH_ADMIN_PASSWORD='replace-with-a-long-password' \
  bash upgrade-vodia-mcp-v0.14.0.sh
```

The interactive password prompt is preferred so the password does not remain
in persistent shell history.

## Verify locally

```bash
curl -fsS http://127.0.0.1:3100/health
node -p "require('/opt/vodia-mcp/package.json').version"
sudo systemctl --no-pager --full status vodia-mcp
curl -fsS https://mcp-test.tryvodia.com/.well-known/oauth-authorization-server
curl -fsS https://mcp-test.tryvodia.com/.well-known/oauth-protected-resource/mcp
```

Health and package checks must report `0.14.0`, the service must be active, and
both discovery requests must return JSON with absolute HTTPS URLs.

## Connect Claude

```bash
claude mcp add --transport http vodia https://mcp-test.tryvodia.com/mcp
claude mcp add --transport http vodia-admin https://mcp-test.tryvodia.com/mcp-admin
```

Complete browser login and consent, then use `/mcp` in Claude Code to confirm
the connection.

## Finish migration later

After all static-token clients use individual PATs, set
`LEGACY_STATIC_TOKEN_ENABLED="false"` in `/etc/vodia-mcp.env` and restart the
service. Keep it enabled until every existing client has migrated.

