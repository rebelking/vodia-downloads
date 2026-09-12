# Vodia MCP v0.14.8

Installer-hardening release. No predefined trunk behavior changes from v0.14.7.

## Fixes

- Uses one checksum naming convention everywhere: `vodia-mcp-v0.14.8-complete-api.zip.sha256`.
- Local-package fallback now defaults to `<package>.zip.sha256`, matching published release assets.
- Startup readiness waits up to 30 seconds for `/health` without printing expected transient connection-refused errors while Node is starting.
- If readiness ultimately fails, the upgrader prints the last 40 `vodia-mcp` journal lines before rollback.
- Upgrade accepts installed versions v0.14.4 through v0.14.7.

## Unchanged functionality

- Microsoft Teams predefined SIP trunk template.
- Amazon Chime predefined SIP trunk template.
- `list_predefined_trunks`.
- `get_predefined_trunk_requirements`.
- `plan_create_predefined_trunk`.
- inspect → plan → explicit approval → apply → verify write policy.
