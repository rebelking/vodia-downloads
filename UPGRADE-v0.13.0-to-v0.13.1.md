# Upgrade Vodia MCP v0.13.0 to v0.13.1

This patch corrects phone provisioning to use the Vodia UI endpoint and payload.
It preserves the environment file, systemd service configuration, tokens,
allowed-domain policy, and supervised-learning state.

## Upgrade from GitHub

Run on the Vodia MCP Linux host:

```bash
cd /tmp
wget https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.13.1.sh
sudo bash upgrade-vodia-mcp-v0.13.1.sh
```

The script downloads and verifies:

- `vodia-mcp-v0.13.1-complete-api.zip`
- `vodia-mcp-v0.13.1-complete-api.sha256`

It requires an existing v0.13.0 installation. It builds and tests the
replacement before stopping the running service and automatically rolls back if
the service does not return a v0.13.1 health response.

## Verify

```bash
curl -fsS http://127.0.0.1:3100/health
sudo systemctl --no-pager --full status vodia-mcp
```

Expected connector version: `0.13.1`.

Restart the Codex client so it reloads the MCP tool definitions. Then create a
Fanvil plan without applying it:

```text
Using only vodia_test_admin, call plan_provision_mac for the intended tenant,
MAC, extension, vendor Fanvil, and model V64. Show the complete redacted plan.
Do not call apply_vodia_change.
```

Confirm that the plan uses `post_rest_system_prov_phones`, singular `extension`,
and contains no `refresh`, `template`, or `extensions` field. Apply only after a
human verifies the MAC, tenant, extension, vendor, and model.

## Rollback

The successful upgrade reports the timestamped previous application directory
and configuration backups. To roll back later, stop the service, move the
current `/opt/vodia-mcp` aside, restore the reported previous directory as
`/opt/vodia-mcp`, restore the matching environment and service backups, run
`systemctl daemon-reload`, and restart `vodia-mcp`.
