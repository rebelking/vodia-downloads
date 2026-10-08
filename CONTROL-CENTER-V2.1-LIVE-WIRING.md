# Control Center v2.1 live wiring

This phase keeps the unified customer frontend and wires its read-only/status actions to the existing MCP tools through a local loopback control API.

## Live calls

- PBX: `get_system_status`
- AWS profile: `aws_get_customer_connection_profile`
- AWS test: `aws_check_customer_connection`
- Cloudflare: `cloudflare_check_connection`
- Microsoft 365: `microsoft_check_graph_readiness`
- Activity: sanitized tail of the existing audit JSONL

## Architecture

```text
Browser /control/
   -> HTTPS /control-api/*
   -> Caddy
   -> 127.0.0.1:3110 vodia-control-api
   -> authenticated local MCP /mcp
   -> existing MCP tools
```

The sidecar receives the existing `MCP_BEARER_TOKEN` through the service environment. It listens on loopback only.

No provider secret, bearer token, AWS External ID, Role ARN, Cloudflare token, or Microsoft secret is returned to the browser.

## Safety

This phase wires only read-only/check operations from the dashboard.

Write workflows remain on the existing MCP plan/approval/apply path.
