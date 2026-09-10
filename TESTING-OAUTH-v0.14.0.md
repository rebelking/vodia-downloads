# Testing Vodia MCP 0.14.0 OAuth

Use the public HTTPS hostname in these examples. OAuth discovery must not be
tested only through `127.0.0.1`, because Claude connects from its own cloud.

## 1. Confirm the release

```bash
curl -fsS http://127.0.0.1:3100/health
node -p "require('/opt/vodia-mcp/package.json').version"
sudo systemctl --no-pager --full status vodia-mcp
```

Expected: version `0.14.0`, `oauthEnabled: true`, and an active service.

## 2. Test the MCP challenge and discovery

```bash
curl -i -X POST https://mcp-test.tryvodia.com/mcp
curl -fsS https://mcp-test.tryvodia.com/.well-known/oauth-protected-resource
curl -fsS https://mcp-test.tryvodia.com/.well-known/oauth-protected-resource/mcp
curl -fsS https://mcp-test.tryvodia.com/.well-known/oauth-authorization-server
```

The first request must return `401` and a `WWW-Authenticate` header containing
`resource_metadata`. Each discovery URL must return `200` JSON with absolute
HTTPS URLs under `https://mcp-test.tryvodia.com`.

## 3. Test dynamic registration

Allowed callback:

```bash
curl -i https://mcp-test.tryvodia.com/register \
  -H 'Content-Type: application/json' \
  --data '{"client_name":"OAuth smoke test","redirect_uris":["https://claude.ai/api/mcp/auth_callback"],"token_endpoint_auth_method":"none","grant_types":["authorization_code","refresh_token"],"response_types":["code"]}'
```

Expected: `201` and a generated `client_id`.

Rejected callback:

```bash
curl -i https://mcp-test.tryvodia.com/register \
  -H 'Content-Type: application/json' \
  --data '{"client_name":"Rejected test","redirect_uris":["https://evil.example/callback"],"token_endpoint_auth_method":"none"}'
```

Expected: `400` with `invalid_redirect_uri`.

## 4. Test Claude.ai

In Claude, open **Customize → Connectors → Add custom connector** and enter:

```text
https://mcp-test.tryvodia.com/mcp
```

Sign in with an OAuth user, approve `mcp:read`, confirm the Vodia tools appear,
and run: `Using Vodia, get the PBX system status. Do not make changes.`

For administrative tools, add a separate connector using
`https://mcp-test.tryvodia.com/mcp-admin` and sign in as an administrator.
PBX writes still require a plan followed by the exact confirmation returned by
that plan.

## 5. Test Claude Code

```bash
claude mcp add --transport http vodia https://mcp-test.tryvodia.com/mcp
claude mcp add --transport http vodia-admin https://mcp-test.tryvodia.com/mcp-admin
```

Complete the loopback browser login, then confirm the connector is connected
and run one harmless read such as system status.

## 6. Test legacy migration behavior

With `LEGACY_STATIC_TOKEN_ENABLED="true"`, an existing bearer-token client must
still connect. After all clients have moved to OAuth or PATs, change it to
`"false"` and restart:

```bash
sudo systemctl restart vodia-mcp
```

The old static token must then receive `401`; OAuth and PAT clients must still
work.

## Troubleshooting

- **Couldn't reach the MCP server:** inspect the 401 challenge, both protected-resource documents, Caddy routing, public TLS, and firewall/WAF access.
- **Authorization failed:** inspect the redirect URI, PKCE verifier, `/token` content type, and OAuth request audit entries.
- **Tools are missing:** verify that the user role and connector endpoint match; `/mcp` is read-only, `/mcp-admin` requires an administrator, and `/mcp-approver` requires an approver or administrator.
- **Very large PBX result:** narrow or paginate the request. OAuth clients default to a 140,000-byte structured-result ceiling.

Do not hard-code an Anthropic IP allowlist from an old document. Verify the
current Claude networking guidance at deployment time; if no supported fixed
range is published for custom connectors, allow public HTTPS to the connector
and rely on OAuth, TLS, rate limiting, and the existing MCP policy controls.
