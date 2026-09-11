# Vodia MCP 0.14.3

Focused interoperability, stats, binary-response, live-call normalization, and redaction maintenance release.

## Fixed
- Dedicated stats tools now resolve their operation IDs from the loaded catalog by GET path/query capability instead of depending on generated numeric suffixes.
- Non-JSON upstream responses are handled by content type. Text remains text; binary/image bodies are returned as base64 with `contentType` and `encoding` metadata instead of being coerced into UTF-8 strings.
- Tenant live-call legs derive `durationSeconds` from `now - connect` when available and derive direction from tenant extension membership rather than trusting the PBX leg-level `inbound` flag.
- Central redaction now removes MAC addresses and RFC-1918/loopback/link-local IPv4 values, and applies operation-aware license-key redaction.
- `redactionApplied` now reflects whether the returned payload was actually changed by redaction.

## Deliberately deferred
Per-user tenant scoping remains a separate authorization change. Static `VODIA_ALLOWED_DOMAINS` enforcement remains unchanged in this release.
