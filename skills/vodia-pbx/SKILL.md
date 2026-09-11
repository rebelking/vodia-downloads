---
name: vodia-pbx
version: 0.1.0
description: Operate and troubleshoot a Vodia PBX through the Vodia MCP read, admin, and approver endpoints using inspect-plan-approve-apply-verify safety.
---

# Vodia PBX MCP Skill

Use this skill when the user asks to inspect, troubleshoot, report on, or make controlled changes to a Vodia PBX through the Vodia MCP connector.

## Connector endpoints

For this test deployment:

- Read: `https://mcp-test.tryvodia.com/mcp`
- Admin: `https://mcp-test.tryvodia.com/mcp-admin`
- Approver: `https://mcp-test.tryvodia.com/mcp-approver`
- Default tenant for current testing: `vodiatech.audiomercy.com`

Authentication is OAuth. Prefer Dynamic Client Registration when the MCP client supports it.

Scopes:

- `mcp:read` — read and troubleshooting operations.
- `mcp:admin` — policy-controlled administrative planning and execution tools.
- `mcp:approve` — independent approval tools.

Do not confuse scopes with tools. Each scope gates a larger set of MCP tools.

## Core operating rules

1. Diagnose before changing anything.
2. Use the read endpoint for ordinary troubleshooting and reporting.
3. For changes, use the admin endpoint and follow: **inspect → plan → show exact effect → explicit user approval → apply → verify**.
4. Never bypass a `plan_*` tool by attempting an arbitrary write.
5. Never call `apply_vodia_change` until the user explicitly approves the exact current plan and confirmation string required by that plan.
6. Treat change plans as short-lived and single-use. If the target state changes, create a new plan.
7. After every applied change, re-read the affected PBX object and report whether the intended state actually changed.
8. Never reveal or attempt to reconstruct redacted credentials, tokens, PINs, license keys, MAC addresses, or private/internal IP information.
9. Do not interpret a troubleshooting request as permission to modify the PBX.
10. Prefer dedicated Vodia tools when available. Use catalog discovery and generic readers only when a dedicated tool is insufficient.
11. Respect tenant restrictions on every call. The generic API reader must never be used to bypass tenant policy.
12. Destructive operations such as deletion require the connector's destructive-policy switch plus the exact confirmation demanded by the plan. Never weaken this requirement.

## Read and troubleshooting workflow

For a support investigation:

1. Call `get_connector_info` if connector capabilities or policy are unclear.
2. Gather the smallest relevant set of read-only evidence.
3. Correlate the evidence before drawing a conclusion.
4. Distinguish observed PBX data from inference.
5. If the evidence is incomplete, say what additional MCP operation is needed rather than guessing.

Common dedicated read tools include:

- `get_system_status` — PBX health, version, and system status.
- `get_system_license` — license state and capacity with secrets redacted.
- `get_system_stats` — system call, registration, performance, and quality statistics.
- `get_system_audit_log` — system administrator changes when policy allows system-wide reads.
- `list_domains` — tenants visible to the configured PBX API account.
- `list_extensions` — tenant extensions or a specific extension.
- `list_accounts` — all tenant account types.
- `list_registrations` — phones, applications, and push registrations.
- `list_trunks` — tenant SIP trunks.
- `list_dialplans` — tenant dial plans.
- `get_tenant_cdrs` / `get_specific_cdr` — call detail records.
- `get_tenant_log` / `get_extension_syslog` — troubleshooting logs.
- `get_extension_settings` — redacted account settings.
- `get_tenant_audit_log` — tenant administrator changes.
- `get_extension_call_history` — extension history.
- `get_account_live_calls` — active call legs for one account.
- `list_tenant_live_calls` — tenant-wide live calls grouped by stable call ID.
- `get_extension_registration_history` — SIP registration history.
- `get_voicemail_metadata` — voicemail metadata without audio.
- `get_tenant_stats` / `get_trunk_stats` — tenant or trunk statistics and supported MOS data.
- `get_live_queue_status` / `get_queue_stats` / `get_queue_cdrs` — queue state and analytics.
- `list_park_orbits` / `get_live_park_status` — park orbit configuration and occupancy.

## Catalog and generic read tools

Use these when the required operation is not covered by a dedicated tool:

- `find_read_capabilities` — search the official safe GET catalog.
- `read_vodia_resource` — execute an official GET operation by exact catalog operation ID.
- `find_api_capabilities` — search the complete API catalog on the admin endpoint.
- `inspect_vodia_operation` — inspect method, path, parameters, body schema, response types, risk, and policy.
- `read_vodia_api` — execute a catalogued non-action GET operation under admin policy.
- `read_vodia_binary` — fetch bounded binary resources such as images, audio, voicemail media, or PCAP as base64.

Never reconstruct operation IDs from URL paths. Use the exact `operationId` returned by the loaded Vodia catalog because generated suffixes may change between API specifications.

## Administrative change workflow

Before changing anything, inspect the current object and create the appropriate plan. Important planner tools include:

- `plan_vodia_change`
- `plan_update_account`
- `plan_create_account`
- `plan_update_tenant_settings`
- `plan_set_extension_buttons`
- `plan_assign_did`
- `plan_provision_mac`
- `plan_clear_mac_provisioning_history`
- `plan_trigger_mac_provisioning`
- `plan_trigger_mac_reboot`
- `plan_update_sip_trunk`
- `plan_set_sip_trunk_enabled`
- `plan_create_dial_plan`
- `plan_update_dial_plan`
- `plan_extension_pcap`
- `plan_trunk_pcap`
- `plan_sip_trace_logging`
- `plan_hangup_call`
- `plan_reject_call`
- `plan_transfer_call`
- `plan_hold_call`
- `plan_resume_call`
- `plan_answer_call`

Potentially destructive planners include:

- `plan_delete_account`
- `plan_delete_dial_plan`
- `plan_delete_sip_trunk`

Do not apply a plan merely because planning succeeded. Present the target, current state, proposed state, risk, expiration, and exact confirmation requirement to the user first.

Apply only with:

- `apply_vodia_change`

After applying, perform a fresh read of the target and report both the requested and observed final state.

## Provisioning rules

For phone/MAC provisioning:

- Call `list_supported_phone_models` before choosing vendor/model values; do not guess strings.
- Use `plan_provision_mac` for creation or update.
- When optional transport/T.38/refresh values are omitted, preserve existing values for existing records and use connector defaults for new records.
- Yealink provisioning requires the complete serial number when the connector asks for it.
- `get_mac_provisioning_history` may be used to validate generated configuration history; authentication material must remain redacted.

## Call troubleshooting

For dropped, failed, or poor-quality calls:

1. Identify tenant, extension/trunk, time window, and call ID when possible.
2. Start with CDR, tenant logs, extension logs, trunk/tenant/system stats, and live state.
3. Use `troubleshoot_dropped_call` on the admin endpoint when appropriate.
4. Use `get_call_sip_trace` only when SIP evidence is required; keep authorization headers and credentials redacted.
5. PCAP changes must use `plan_extension_pcap` or `plan_trunk_pcap`, require approval, and should be disabled after troubleshooting.

For live calls, prefer stable call IDs. Treat normalized `direction` and `durationSeconds` as connector-derived fields and compare against raw PBX evidence if they look inconsistent.

## Queue troubleshooting

For queue problems, correlate:

- `get_live_queue_status`
- `get_queue_stats`
- `get_queue_cdrs`
- agent registrations and extension state
- tenant CDR/log evidence when required

Report answered, abandoned, waiting, agent availability, and time-window context when returned by the PBX. Do not invent metrics that the tool did not return.

## Learned operations

The connector supports supervised learning for additional API operations. Available tools include:

- `list_learned_operations`
- `inspect_learned_operation`
- `propose_learned_operation`
- `test_learned_read`
- `run_learned_read`
- `plan_learned_write`
- `disable_learned_operation`

Independent review/approval tools include:

- `list_learning_proposals`
- `inspect_learning_proposal`
- `approve_learned_operation`

A learned write is still subject to planning and `apply_vodia_change`; approval of a learned operation is not approval to execute a PBX change.

## Security and redaction

The connector should redact sensitive client-visible response fields at the response boundary while preserving raw values internally for policy validation, state hashing, provisioning, and change verification.

Do not expose:

- passwords, PINs, API credentials, Authorization headers, OAuth tokens, or secrets;
- license keys;
- MAC address values when connector policy marks them sensitive;
- private/internal IP addresses when connector policy marks them sensitive.

If `redactionApplied` is present, treat it as an indication that data was actually removed or replaced. Never claim that a redacted value is known.

## Binary results

Some Vodia monitoring/statistics endpoints return PNG or other binary content. Binary responses must be treated as binary/base64 with their actual content type. Never interpret raw PNG bytes as UTF-8 text.

## Recommended behavior for user requests

### Read-only example

User: "Why is extension 2009 not receiving calls?"

Action: inspect extension settings, registration, recent calls, relevant logs and routing evidence. Return diagnosis and evidence. Do not create a change plan unless the user asks to fix it.

### Write example

User: "Change extension 2009's display name to John Smith."

Action:

1. Read extension 2009.
2. Create `plan_update_account` for only the requested field.
3. Show the exact before/after value and confirmation requirement.
4. Wait for explicit approval.
5. Call `apply_vodia_change` with the exact confirmation.
6. Re-read extension 2009 and verify the displayed name.

### Ambiguous write request

User: "Fix extension 2009."

Action: diagnose first. Do not change multiple settings speculatively. Explain the identified issue and propose the smallest corrective change before planning it.

## Reporting style

For investigations, summarize:

- observed evidence;
- likely cause;
- confidence/uncertainty;
- recommended next action;
- whether any PBX state was changed.

For changes, always report:

- target;
- before state;
- approved change;
- result returned by the apply operation;
- independently verified after state.

Never say a PBX change succeeded solely because `apply_vodia_change` returned success; verify it with a fresh read.
