# Vodia MCP 0.13.2

Vodia MCP 0.13.2 adds guarded actions for tenant provisioned devices, based on
requests captured from the Vodia PBX 70.5 tenant MAC portal.

## Added

- `get_mac_provisioning_history`
- `plan_trigger_mac_provisioning`
- `plan_trigger_mac_reboot`
- `plan_clear_mac_provisioning_history`

The corresponding apply step remains `apply_vodia_change`. Plans are immutable,
single-use, tenant-scoped, short-lived, and require the exact confirmation text
returned by the planner.

## Verified Vodia requests

| Portal action | Verified request |
|---|---|
| Trigger Provisioning | `GET /rest/domain/{domain}/check-sync?mac={MAC}&reboot=false` |
| Trigger Reboot | `GET /rest/domain/{domain}/check-sync?mac={MAC}&reboot=true` |
| Clear history | `GET /rest/domain/{domain}/generated?mac={MAC}&reset=1` |
| Read history | `GET /rest/domain/{domain}/generated?mac={MAC}` |

The reboot capture returned `true`, logged `Resync device initiated`, and was
followed by the selected phone downloading its generated configuration.

## Safety and security

- A target MAC must already exist in the requested tenant.
- Trigger Provisioning uses `reboot=false`; Trigger Reboot uses `reboot=true`.
- Reboot plans warn that active calls may be interrupted.
- Clear history removes provisioning diagnostics only; it does not remove the
  phone, MAC entry, extension, or button configuration.
- Basic authorization strings embedded inside provisioning-history text are now
  redacted in addition to Bearer, Digest, private-key, and sensitive-key data.
- Start Pairing and Update Cloud Provisioning are not included because their
  action requests have not yet been captured and verified.

## Upgrade

Use `upgrade-vodia-mcp-v0.13.2.sh`. It expects v0.13.1, verifies the release
checksum, runs the production audit and complete self-test suite, preserves
configuration and supervised-learning state, and retains the previous
application directory for rollback.
