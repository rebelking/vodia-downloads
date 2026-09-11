# Vodia MCP 0.14.2

Vodia MCP 0.14.2 fixes MCP tool-result compatibility for clients that consume the standard `content` array but do not surface `structuredContent`.

## Fixed

- Successful tool results now keep the existing `structuredContent` object and also include the same JSON, pretty-printed, as a second text block in `content`.
- Human-readable one-line summaries remain the first text block.
- Read-only Vodia tools such as `get_system_status`, `get_connector_info`, `get_system_license`, and `get_system_stats` now expose their actual returned fields to Claude and other content-only MCP clients.
- Existing response-size protection still truncates oversized tool results before serialization.
- Added a regression check proving read data is mirrored into text content.

## Compatibility

No database or OAuth schema change is required. Existing users, OAuth clients, tokens, policy settings, and PBX credentials remain compatible with v0.14.1.
