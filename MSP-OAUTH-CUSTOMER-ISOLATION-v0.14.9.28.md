# Vodia MCP v0.14.9.28 — OAuth MSP / Customer Isolation

## Goal

Customers and MSP users connect through OAuth. They never receive or paste the server-wide `MCP_BEARER_TOKEN`.

## Public vs local authentication

The existing legacy bearer token remains usable only on the trusted local MCP core (`127.0.0.1:3100`) so internal sidecars do not break.

A new public gateway listens on `127.0.0.1:3113`. Caddy sends public `/mcp` traffic to this gateway. If a public request presents the legacy server-wide bearer token, the gateway rejects it with `legacy_static_token_not_allowed`. OAuth access tokens are forwarded to the normal MCP OAuth implementation.

This avoids exposing one global customer credential while preserving local service-to-service compatibility.

## MSP authorization model

OAuth identity -> MSP organization -> customer -> role.

Roles:

- `MSP_ADMIN`
- `CUSTOMER_ADMIN`
- `OPERATOR`
- `READ_ONLY`

The first OAuth identity with a stable user claim can create the first MSP organization when the authorization database is empty. After that, membership rules apply.

## New tools

- `msp_get_my_identity`
- `msp_create_organization`
- `msp_create_customer`
- `msp_grant_membership`
- `msp_list_customers`
- `msp_get_commercial_audit`
- `msp_get_customer_aws_connection`
- `msp_save_customer_aws_connection`

## AWS behavior

With `VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT=true`, customer-facing AWS discovery, Marketplace purchase, network planning, deployment planning, deployment apply, and status calls require a customer context.

AWS role ARN and External ID are encrypted per customer in `/var/lib/vodia-mcp/msp-customer-connections.enc`. The encryption key is stored separately in `/var/lib/vodia-mcp/msp-customer-connections.key`.

Marketplace quote preparation requires `MSP_ADMIN` or `CUSTOMER_ADMIN`. Agreement acceptance requires the same roles and creates a commercial audit entry bound to the OAuth subject, organization, customer, product/offer/plan, agreement request, and resulting agreement ID.

EC2 deployment remains a separate approval from Marketplace purchase.

## Important

Do not give customers the legacy MCP bearer token. It is an internal compatibility credential only.
