# Vodia MCP v0.14.1 OAuth / DCR Test Checklist

Use these checks after upgrading and before enabling production traffic.

## 1. DCR without token_endpoint_auth_method
Send a valid `POST /register` request that omits `token_endpoint_auth_method`.

Expected: successful client registration when all other metadata is valid. The server must not return HTTP 500 merely because the field is absent.

## 2. Public client (`none`)
Register a client with:

```json
{
  "token_endpoint_auth_method": "none"
}
```

Expected: accepted when permitted by server policy.

## 3. Confidential client (`client_secret_post`)
Register a client with:

```json
{
  "token_endpoint_auth_method": "client_secret_post"
}
```

Expected: accepted and handled according to the configured OAuth policy.

## 4. Invalid metadata
Submit unsupported or malformed registration metadata.

Expected: HTTP 400 with an OAuth-compatible error response. It must not become an unhandled HTTP 500.

## 5. Invalid redirect URI
Submit an invalid or disallowed redirect URI.

Expected: HTTP 400 OAuth error and no client registration.

## 6. Logging
Inspect service logs during the tests.

Expected:
- request path reflects `req.originalUrl`;
- unexpected exceptions include enough stack information for diagnosis;
- secrets are not logged;
- `vodia_change_applied` does not dump the full extension settings object.

## 7. Scope intersection
Request a mixture of allowed, role-disallowed, unsupported, and unrequested scopes.

Expected effective scopes:

`requested ∩ role-authorized ∩ server-supported`

No scope outside that intersection should be granted.

## 8. Vodia read-only smoke test
After OAuth succeeds, verify the enabled read-only MCP operations against a test PBX, including system status, tenant listing, registrations, queue status, and extension status as applicable to the deployment.

## Pass criteria
The release is ready for production only when DCR failures produce controlled 4xx responses, valid registrations succeed, scope enforcement is correct, sensitive extension configuration is absent from journald, and the read-only PBX calls complete successfully.
