# Vodia MCP — Cloudflare Phase 1

Cloudflare Phase 1 adds a customer-facing Cloudflare connection to the existing Vodia MCP Control Center.

## Goal

A customer should be able to connect a Cloudflare-managed DNS zone from the Vodia MCP web UI without SSH, manually entering a zone ID, or exposing the API token to Claude, ChatGPT, Codex, or MCP tool results.

## Phase 1 capabilities

- Authenticated Control Center integration card.
- Customer enters a DNS zone and scoped Cloudflare API token.
- Test connection before saving.
- Validate the Cloudflare token.
- Discover the zone automatically by domain name.
- Verify Zone Read access.
- Verify DNS Read access by listing a small sample of records.
- Store the API token encrypted at rest with AES-256-GCM using a key derived from the existing MCP `SESSION_SECRET`.
- Re-check the saved connection without re-entering the token.
- Read saved-zone DNS records through the server-side adapter.
- Disconnect and delete the stored credential.
- Audit connection test/save/disconnect events without logging the token.

## Deliberately deferred

Phase 1 does not create, update, or delete Cloudflare DNS records. It therefore reports DNS Write as `not_tested` rather than claiming the permission exists.

Phase 2 will add guarded DNS planners and apply/verify behavior for A, AAAA, CNAME, TXT and other records required by supported workflows.

## Cloudflare token scope for customers

For the future Direct Routing workflow, the intended token is restricted to the customer's DNS zone with:

- Zone / Zone / Read
- Zone / DNS / Edit
- Include / Specific zone / the customer's domain

The UI never asks the customer for the Cloudflare Zone ID. Vodia MCP discovers it from the domain.

## Security model

The API token is submitted only to the authenticated Control Center backend. It is never registered as an MCP tool argument and is never returned through MCP responses.

Credential flow:

```text
Customer browser
  -> HTTPS Control Center
  -> authenticated /api/integrations/cloudflare
  -> encrypted server-side storage
  -> Cloudflare API adapter
```

AI clients receive only non-secret integration state and DNS data exposed by future MCP tools.

## Install

On a Vodia MCP 0.14.7 or 0.14.8 connector:

```bash
wget -O /root/upgrade-vodia-mcp-cloudflare-phase1.sh \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-cloudflare-phase1.sh
chmod +x /root/upgrade-vodia-mcp-cloudflare-phase1.sh
bash -n /root/upgrade-vodia-mcp-cloudflare-phase1.sh \
  && echo "PASS: installer syntax valid"
/root/upgrade-vodia-mcp-cloudflare-phase1.sh
```

The installer takes a complete application backup before modifying the connector and restores it automatically if validation or service startup fails.

## Test

Open the existing Control Center at `/admin/`.

Under **Integrations → Cloudflare DNS**:

1. Enter the DNS zone, for example `audiomercy.com`.
2. Enter the scoped Cloudflare API token.
3. Select **Test connection**.
4. Confirm Zone Read and DNS Read pass.
5. Select **Save integration**.
6. Select **Check saved connection** to prove the encrypted stored credential works.

Do not paste the Cloudflare API token into Claude, ChatGPT, Codex, GitHub, logs, screenshots, or support messages.

## Next phase

Cloudflare Phase 2 should add the existing Vodia safety model:

```text
DISCOVER -> PLAN -> APPROVE -> APPLY -> VERIFY
```

Planned tools:

- `cloudflare_check_readiness`
- `cloudflare_list_dns_records`
- `cloudflare_plan_create_dns_record`
- `cloudflare_plan_update_dns_record`
- `cloudflare_plan_delete_dns_record`
- `apply_cloudflare_change`

The Teams Direct Routing orchestration can then use Cloudflare for Microsoft domain-verification TXT records and SBC DNS records while keeping DNS changes approval-gated.
