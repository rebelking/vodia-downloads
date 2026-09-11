# Vodia MCP 0.14.4

Corrective release for the v0.14.3 validation failure.

## Fixed

- Split PBX reads into an internal raw reader and the public redacted reader.
- Admin planning, precondition hashing, provisioning, and post-write verification now use raw PBX state internally; redaction is applied only when data is returned to an MCP client or audit surface.
- Corrected the redaction regression test: a `mac` field is intentionally replaced as a whole with `[REDACTED]`.
- Updated HTTP self-test version expectations to 0.14.4.
- Retains v0.14.3 fixes for catalog-driven stats operation resolution, binary/base64 handling, live-call normalization, and central sensitive-field redaction.

## Upgrade path

This release upgrades directly from v0.14.2 because v0.14.3 correctly failed validation before replacing the live installation.
