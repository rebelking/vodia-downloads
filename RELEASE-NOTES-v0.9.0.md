# Vodia MCP 0.9.0 release notes

## Added

- Dedicated live-call planners for hangup, reject, blind transfer, hold,
  resume and remote answer
- Stable call-ID preconditions that tolerate changing `now` and duration fields
- One-minute live-call plans with action-specific confirmations such as
  `HANGUP <call-id>` and `TRANSFER <call-id> TO <destination>`
- Typed dial-plan creation and deletion planners
- Protected tenant-validated binary PCAP download endpoint:
  `/api/pcap/{call-id}?domain={tenant}`
- Connector version in `/health`
- A single connector version constant used by MCP metadata, runtime reporting
  and HTTP user agents

## Fixed

- Live call-control plans no longer fail merely because the PBX changes a
  volatile timestamp between plan and apply
- Call hangup now uses the documented Vodia request body
  `{ "hangup": "<call-id>" }`
- Connector information now reports package version `0.9.0` instead of the
  stale `0.7.0` or `0.8.0` value
- Installer no longer prints bearer tokens by default; credentials remain in
  `/root/vodia-mcp-credentials.txt` with mode `0600`

## Safety behavior

- A live-call apply is rejected if the exact call ID disappears before apply.
- Ordinary configuration writes still compare their complete preimage and
  reject genuinely stale plans.
- Live-call plans remain immutable and single-use.
- PCAP downloads require the dashboard administrator token, verify tenant
  ownership, enforce the configured byte limit, disable caching and write an
  audit event.
- Destructive and critical operations remain disabled by default.

## Known API boundary

The supplied Vodia REST API 70.3 schema still does not document creation of a
brand-new SIP trunk. v0.9 does not invent an unsupported request. Create the
initial trunk in the PBX web interface, then use MCP to read, rename, update,
enable, disable or delete it. A future `plan_create_sip_trunk` tool requires a
published Vodia REST creation operation.

## Compatibility

- Target PBX: Vodia 70.x
- Catalog source: Vodia REST API 70.3
- Runtime: Node.js 18 or newer
- Connector host: Ubuntu/Debian with systemd and Caddy
- Clients: Codex MCP over HTTPS on macOS, Windows or Linux

## Verification completed

- JavaScript and installer shell syntax checks
- Read-only and tenant-isolation regression tests
- Separate read/admin bearer-token tests
- Dynamic connector-version test
- Extension creation and SIP-trunk update plan/apply tests
- Dial-plan creation plan/apply test
- Live hangup test with a changing `now` field
- Disappearing-call rejection test
- Exact dynamic confirmation and single-use tests
- Ordinary stale-configuration protection test
- PCAP parsing, redaction and protected-download tests
- Destructive and critical default-deny tests

