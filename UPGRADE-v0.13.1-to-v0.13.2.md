# Upgrade Vodia MCP 0.13.1 to 0.13.2

Vodia MCP 0.13.2 adds guarded tenant-MAC provisioning, reboot, and history
actions. The upgrade preserves `/etc/vodia-mcp.env`, the systemd service,
audit logs, supervised-learning state, and a rollback copy of v0.13.1.

## Download and verify

```bash
cd /tmp
wget https://raw.githubusercontent.com/rebelking/vodia-downloads/main/vodia-mcp-v0.13.2-complete-api.zip
wget https://raw.githubusercontent.com/rebelking/vodia-downloads/main/vodia-mcp-v0.13.2-complete-api.sha256
sha256sum -c vodia-mcp-v0.13.2-complete-api.sha256
```

The expected verification output is:

```text
vodia-mcp-v0.13.2-complete-api.zip: OK
```

## Run the upgrade

```bash
cd /tmp
unzip -q vodia-mcp-v0.13.2-complete-api.zip -d vodia-mcp-v0.13.2-upgrade
sudo bash /tmp/vodia-mcp-v0.13.2-upgrade/vodia-mcp/upgrade-vodia-mcp-v0.13.2.sh
```

The script accepts only an installed v0.13.1 package. Before switching the
service, it installs production dependencies, audits them, checks JavaScript and
shell syntax, and runs all connector self-tests. Any failure before the switch
leaves the running installation untouched. A failure after the switch triggers
automatic rollback.

## Verify

```bash
curl -fsS http://127.0.0.1:3100/health
node -p "require('/opt/vodia-mcp/package.json').version"
sudo systemctl --no-pager --full status vodia-mcp
```

Both version checks must report `0.13.2`, and the service must show `active
(running)`.

## MCP tools added

- `get_mac_provisioning_history`
- `plan_trigger_mac_provisioning`
- `plan_trigger_mac_reboot`
- `plan_clear_mac_provisioning_history`

Actions still require `apply_vodia_change` with the exact confirmation returned
by the plan. These bounded tools do not require `VODIA_ENABLE_DESTRUCTIVE=true`;
they cannot delete a phone, extension, tenant, or MAC entry.

## Security action after producing portal captures

If a browser HAR or PBX log included a `session=` cookie or phone
`Authorization: Basic ...` header, log out of that PBX browser session and
rotate the affected phone provisioning credential. Do not store the raw capture
in GitHub.
