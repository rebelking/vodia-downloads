# Vodia MCP v0.14.1

Small-fix release for the single-administrator Vodia MCP deployment. Multi-user features such as invitations, per-tenant access, and separate approvers remain deferred.

## Fixes

### Dynamic Client Registration (DCR)
- Handle registrations where `token_endpoint_auth_method` is omitted.
- Accept `none` and `client_secret_post` where appropriate.
- Invalid client metadata and redirect URIs should return OAuth-style HTTP 400 responses instead of an internal HTTP 500.
- Unexpected registration exceptions should be logged with their stack trace.
- Request logging should use `req.originalUrl` rather than a hard-coded `/`.
- Add HTTP-level registration tests covering valid and invalid metadata.

### Log redaction
- `vodia_change_applied` must not write the complete extension settings object to journald.
- Audit logs should contain only operation ID, status, tenant, user, changed fields, and the relevant before/after values.
- Secrets and unrelated extension configuration must not be emitted.

### OAuth scope handling
- Effective scopes must be the intersection of requested scopes, role-authorized scopes, and server-supported scopes.
- Do not silently grant scopes that were not requested or are not permitted for the role.

## Package

`vodia-mcp-v0.14.1-complete-api.zip`

## Deployment note

Back up the existing MCP installation and configuration before upgrading. Preserve environment variables, service configuration, OAuth client configuration, and any local policy files. Restart the service after installation and run the OAuth/DCR and read-only API smoke tests before using it against production PBX systems.
