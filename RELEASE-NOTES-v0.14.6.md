# Vodia MCP v0.14.6

## Predefined SIP trunks

- Keeps the verified Microsoft Teams predefined trunk template introduced in v0.14.5.
- Adds a second verified template: **Amazon Chime / Amazon Chime SDK Voice Connector**.
- Both templates use the guarded `plan_create_predefined_trunk` → explicit approval → `apply_vodia_change` workflow.
- Missing provider-specific values are returned as questions for the MCP client to ask instead of guessed.

### Microsoft Teams required input

- PBX/SBC FQDN.

### Amazon Chime required input

- Voice Connector hostname, such as `abc123.voiceconnector.chime.aws`.
- SIP username/account.
- SIP password.

Optional Amazon Chime inputs include trunk name, DID, and allowed signaling addresses. The captured Vodia transaction's signaling CIDRs (`3.80.16.0/23 99.77.253.0/24`) are used as the template default when no override is supplied.

The Amazon Chime template is based on a successful Vodia 70.6.beta portal transaction captured on 2026-09-11. The create request used `POST /rest/domain/{domain}/domain_trunks` and the resulting trunk was visible in the subsequent domain trunk list.

## Security

- SIP passwords are accepted only as planner input and remain redacted from public change-plan previews and audit output.
- Creation remains plan/approve/apply/verify; this release does not add unrestricted raw POST access.

## AWS discovery

This release does **not** automatically connect to AWS. It prepares the MCP template so a later AWS connector/SDK integration can populate the Voice Connector hostname and related values before planning.
