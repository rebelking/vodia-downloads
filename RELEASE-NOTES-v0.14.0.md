# Vodia MCP 0.14.0

Vodia MCP 0.14.0 adds individual identity and a built-in OAuth authorization
server while preserving the v0.13.2 MCP endpoints, PBX policies, supervised
learning state, static-token migration path and plan/apply protections.

## New capabilities

- OAuth discovery for `/mcp`, `/mcp-admin` and `/mcp-approver`.
- Authorization Code flow with mandatory S256 PKCE.
- Dynamic registration restricted to approved Claude callbacks and loopback callbacks when enabled.
- Individual users with viewer, administrator and approver roles.
- Password hashing with maintained bcrypt at cost 12.
- CSRF-protected login and consent forms, SDK IP rate limiting, per-account failure tracking and a 15-minute lockout after five failures.
- Opaque access and refresh tokens stored only as SHA-256 hashes.
- Refresh-token rotation and token-family revocation on reuse.
- Immediate access, refresh, PAT and browser-session invalidation when a user is disabled or their role changes.
- Personal access tokens for header-based Codex, Claude Code and Copilot usage.
- A configurable 140,000-byte OAuth tool-result ceiling with truncation guidance for oversized PBX responses.
- Connected-app and PAT revocation.
- User, role, client, scope and authentication type in tool audit events.
- OAuth user management in the existing control center.
- CLI user bootstrap and management through `auth-cli.js`.

## Compatibility

- `/mcp` remains strict read-only.
- `/mcp-admin` keeps the existing policy-controlled plans and apply tools.
- `/mcp-approver` keeps supervised-learning approval separate.
- Static tokens remain accepted by default during migration.
- The existing `ADMIN_TOKEN` remains the break-glass dashboard credential.
- Caddy continues to terminate TLS and proxy to `127.0.0.1:3100`.

## Runtime change

Node.js 22.13 or newer is required because authentication persistence uses the
built-in `node:sqlite` module. The installer and upgrade script enforce this.

## Verification

The release includes unit and HTTP integration coverage for redirect URI
validation, login, consent, PKCE, OAuth discovery, dynamic registration, MCP
tool listing with OAuth, single-use codes, refresh rotation/reuse detection,
PATs, disabled users, legacy migration tokens and unknown-client behavior.

## Deliberately retained and deferred

- Existing v0.13.2 action tools remain available only on `/mcp-admin`; OAuth does not add or weaken any write capability.
- PAT creation is performed by an administrator in the control center or CLI. A separate self-service end-user account portal is deferred.
- MFA, SSO/OIDC federation, Vodia-account authentication and Client ID Metadata Documents remain future work.
- Public Claude.ai/Desktop/mobile and Claude Code acceptance tests must be run against the deployed HTTPS service; the packaged automated tests cannot substitute for that external validation.
