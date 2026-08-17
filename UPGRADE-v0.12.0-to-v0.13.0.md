# Upgrade Vodia MCP v0.12.0 to v0.13.0

This upgrade preserves the existing PBX credentials, MCP endpoint tokens,
approver identity, supervised-learning catalog, audit logs and Caddy
configuration.

## Before upgrading

On the connector server:

```bash
sudo systemctl status vodia-mcp --no-pager
curl -fsS http://127.0.0.1:3100/health
sudo cp -a /etc/vodia-mcp.env /root/vodia-mcp.env.before-v0.13.0
sudo cp -a /var/lib/vodia-mcp /root/vodia-mcp-state.before-v0.13.0
```

The health response must report version `0.12.0`.

## Upgrade with local release files

Place these two files in the same directory:

- `vodia-mcp-v0.13.0-complete-api.zip`
- `vodia-mcp-v0.13.0-complete-api.sha256`

Then run:

```bash
unzip -q vodia-mcp-v0.13.0-complete-api.zip -d /tmp/vodia-mcp-v0.13.0

sudo env \
  VODIA_MCP_PACKAGE_FILE="$PWD/vodia-mcp-v0.13.0-complete-api.zip" \
  VODIA_MCP_CHECKSUM_FILE="$PWD/vodia-mcp-v0.13.0-complete-api.sha256" \
  bash /tmp/vodia-mcp-v0.13.0/vodia-mcp/upgrade-vodia-mcp-v0.13.0.sh
```

## Validate

```bash
curl -fsS http://127.0.0.1:3100/health
sudo systemctl status vodia-mcp --no-pager
sudo journalctl -u vodia-mcp -n 100 --no-pager
```

Expected connector version: `0.13.0`.

From Codex, verify the new tools without writing:

```text
Using only vodia_test_admin:

1. Call inspect_vodia_operation for post_rest_user_account_buttons.
2. Call get_extension_buttons for 2033@vodiatech.audiomercy.com.
3. Call list_tenant_dids for vodiatech.audiomercy.com.
4. Confirm plan_set_extension_buttons and plan_assign_did are available.

Do not create or apply any change plan.
```

## First controlled button test

Read the entire existing button configuration first. A button POST replaces the
complete profile; it is not a one-button append. Create the plan with
`replace_all: true`, review every slot, and apply only with the exact
`REPLACE BUTTONS ...` phrase returned by the planner.

## First controlled DID test

Use `plan_assign_did` with one test DID and extension. Review whether
`outbound` is true or false, then apply only with the exact
`ASSIGN DID ...` phrase returned by the planner.

## Rollback

The upgrader prints the retained directory, for example:

```text
/opt/vodia-mcp.previous-YYYYMMDD-HHMMSS
```

If rollback is required:

```bash
sudo systemctl stop vodia-mcp
sudo mv /opt/vodia-mcp /opt/vodia-mcp.failed-v0.13.0
sudo mv /opt/vodia-mcp.previous-YYYYMMDD-HHMMSS /opt/vodia-mcp
sudo cp -a /root/vodia-mcp.env.before-v0.13.0 /etc/vodia-mcp.env
sudo systemctl daemon-reload
sudo systemctl restart vodia-mcp
curl -fsS http://127.0.0.1:3100/health
```
