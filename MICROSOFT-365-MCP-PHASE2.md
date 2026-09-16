# Microsoft 365 MCP Phase 2 — Teams Readiness and Deployment Planning

Phase 1 proved that the Vodia MCP can authenticate to the configured Microsoft 365 tenant with app-only OAuth and read organization, domain, user, and license data.

Phase 2 remains read-only. It adds Teams-oriented prerequisite checks and deployment planning without claiming that Teams Direct Routing is already configured.

## Added MCP tools

- `microsoft_get_user`
  - Reads one Microsoft 365 user by UPN.
  - Maps assigned license IDs to tenant SKU part numbers when possible.
  - Makes no changes.

- `microsoft_check_teams_readiness`
  - Reads tenant identity.
  - Finds verified custom Microsoft 365 domains.
  - Reads subscribed SKUs.
  - Optionally checks one user and assigned-license signals.
  - Optionally validates that an SBC FQDN is under a verified custom domain.
  - Does **not** inspect or configure Teams PSTN gateways, voice routes, PSTN usages, or voice-routing policies.

- `microsoft_plan_vodia_teams_user`
  - Builds a read-only plan for a future Teams + Vodia user.
  - Inputs: Microsoft UPN, Vodia tenant, extension, optional DID, SBC FQDN.
  - Returns blockers, warnings, target data, and the ordered Microsoft/Vodia deployment sequence.
  - Makes zero Microsoft or PBX writes.

- `microsoft_get_teams_gap_report`
  - Returns what is implemented now and the next control-plane tools to build.

## Important boundary

Microsoft Graph Phase 1/2 is not the same as the Teams Direct Routing control plane.

Phase 2 deliberately reports:

```text
directRoutingConfigured: NOT_CHECKED
```

until the MCP has a verified Teams control-plane integration for PSTN gateway, voice route, PSTN usage, voice-routing policy, and phone-number state.

## Install

Run on the MCP server:

```bash
wget -O /root/upgrade-vodia-mcp-microsoft-phase2.sh \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-microsoft-phase2.sh

chmod +x /root/upgrade-vodia-mcp-microsoft-phase2.sh

bash -n /root/upgrade-vodia-mcp-microsoft-phase2.sh \
  && echo "PASS: installer syntax valid"

/root/upgrade-vodia-mcp-microsoft-phase2.sh
```

The installer:

1. Requires Microsoft Phase 1 to already be installed.
2. Creates a timestamped backup of `/opt/vodia-mcp/index.js`.
3. Adds the Phase 2 read-only tools.
4. Runs `node --check`.
5. Verifies the safety/boundary markers.
6. Restarts `vodia-mcp`.
7. Automatically restores the backup if JavaScript validation or service startup fails.

## First tests

From Claude, Codex, or another MCP client:

```text
Run microsoft_get_teams_gap_report
```

Then:

```text
Run microsoft_check_teams_readiness
```

For a specific Microsoft user and proposed SBC FQDN:

```text
Run microsoft_check_teams_readiness with:
userPrincipalName: user@example.com
sbcFqdn: teams.example.com
```

Then build a deployment plan:

```text
Run microsoft_plan_vodia_teams_user with:
userPrincipalName: user@example.com
vodiaTenant: example.com
extension: 220
did: +19785550123
sbcFqdn: teams.example.com
```

## Existing Vodia Teams work this phase connects to

The current Vodia MCP already contains the predefined Microsoft Teams SIP-trunk workflow:

- `list_predefined_trunks`
- `get_predefined_trunk_requirements`
- `plan_create_predefined_trunk`

That workflow keeps the existing inspect -> plan -> explicit approval -> apply -> verify model. Phase 2 references it but does not invoke any write automatically.

## Next build

The next Microsoft patch should add **read-only Teams control-plane discovery** after the authentication method is verified for the current Microsoft Teams PowerShell/control-plane tooling:

- `teams_list_pstn_gateways`
- `teams_get_voice_routes`
- `teams_get_voice_policies`
- `teams_get_phone_numbers`
- `teams_check_direct_routing`
- `teams_check_vodia_sbc`

Only after those reads are proven should approval-gated Teams write tools be introduced.
