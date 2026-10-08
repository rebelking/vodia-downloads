# Vodia MCP Unified Control Center v2

## Purpose

This is the new customer-facing Vodia MCP frontend.

It is intentionally separate from the existing `/admin/` diagnostic/configuration page.

## UX rule

The main customer dashboard must not expose raw technical configuration fields.

Do **not** place these on the main screen:

- admin token
- MCP bearer token
- Cloudflare API token
- AWS External ID
- AWS Role ARN
- raw MCP URL
- Microsoft client secret

The customer sees connection state and guided actions instead:

- Connected / Not connected
- Test
- Connect / Manage
- Deploy PBX
- Create tenant
- Configure Teams
- Check PBX health

Raw configuration remains behind protected setup/admin workflows.

## Phase 1 layout

The new control center contains:

1. Connected services
   - Vodia PBX
   - AWS
   - Microsoft 365
   - Cloudflare DNS
2. Service overview
3. Guided workflows
4. PBX health
5. Recent MCP activity
6. Advanced administration link

The right-side connection-settings panel from the legacy control center is removed. All information is presented in one full-width flow.

## Current live wiring

- `/health` is read directly to show MCP state/version/OAuth/mode.
- Existing protected `/admin/` remains available as the advanced fallback.
- Provider cards are structured for the next phase where the existing MCP connection tools are exposed through guided actions.

## Files

- `control-center-v2/index.html`
- `control-center-v2/styles.css`
- `control-center-v2/app.js`

## Next backend wiring

The shell is designed to connect to:

- AWS saved connection profile + `aws_connect_customer_account`
- Cloudflare saved integration status/check
- Microsoft 365 OAuth/tenant status
- PBX health/status
- audited MCP activity

No provider secrets should ever be rendered back into the customer UI.
