# Vodia MCP v0.14.5

## Predefined SIP trunk creation

- Adds `list_predefined_trunks`.
- Adds `get_predefined_trunk_requirements`.
- Adds `plan_create_predefined_trunk`.
- Adds the first verified predefined template: **Microsoft Teams**.
- Microsoft Teams requires an explicit PBX/SBC FQDN; if it is missing, the
  planner returns `needsInput: true` and the exact question for the AI client
  to ask instead of guessing.
- Uses the Vodia portal-verified create operation
  `POST /rest/domain/{domain}/domain_trunks` with no `trunk` query parameter.
- Preserves the existing immutable plan -> exact approval -> apply -> verify
  workflow.
- Rejects duplicate trunk names before planning.
- Adds portal evidence metadata to the catalog entry so operation inspection no
  longer describes this POST as enable/disable-only.

## Verification evidence

The Microsoft Teams payload and creation semantics were derived from a
sanitized tenant-portal HAR captured against Vodia 70.6.beta on 2026-09-11. The
observed POST returned a numeric trunk id and the subsequent tenant trunk list
contained the newly created Microsoft Teams trunk.

Other predefined providers are intentionally not guessed. They can be added to
the same template framework from additional verified portal/API captures.
