# Tenant country-code regression checklist

Use this after every Vodia MCP version that touches tenant creation, Cloudflare DNS, confirmation handling, or Zod/MCP tool schemas.

## Safety rules

- Use a dedicated test FQDN, for example `country-test-YYYYMMDD.audiomercy.com`.
- Use a valid calling code. For the US, Canada, and Dominican Republic, use `1`.
- Do not use a real customer tenant or a production DNS name for a write test.
- Start with plan-only tests. Apply only the one explicitly designated test plan.
- Record each `changeId`, expiry time, result, and cleanup result in the release notes.

## Baseline checks — no writes

| ID | Action | Expected result |
|---|---|---|
| TC-01 | Confirm the service is active and `CONNECTOR_VERSION` is the release under test. | Service is active; expected version is shown. |
| TC-02 | Call `plan_create_tenant_with_dns` with a valid, unused test FQDN and numeric `country_code: 1`. | Plan is created; `country_code` is returned as `1`; no PBX/DNS write. |
| TC-03 | Repeat TC-02 with invalid country code `978`. | Rejected before a plan is created; no write. |
| TC-04 | Submit the same planned tenant again after it exists. | Duplicate pre-check rejects it; no write. |
| TC-05 | Attempt to apply a plan with an altered confirmation phrase or an expired change ID. | Rejected; no write. |

## Controlled write test

1. Create a fresh plan with `plan_create_tenant_with_dns` and `country_code: 1`.
2. Verify the plan shows all of the following before approval:
   - exact FQDN and DNS A-record address;
   - DNS-only / Auto TTL unless an exception is intentional;
   - calling code `1`;
   - one exact approval phrase and a future expiry time;
   - no existing tenant and no DNS conflict.
3. Apply only that change ID with its exact approval phrase.
4. Require all results below before marking the test passed:

| ID | Verification | Pass condition |
|---|---|---|
| TC-06 | Cloudflare | One DNS-only A record exists for the planned FQDN and IP. |
| TC-07 | Vodia tenant | Tenant exists and has an ID. |
| TC-08 | Country read-back | Vodia reports country code `1`, not merely that a POST was attempted. |
| TC-09 | Result integrity | No warnings; `countryVerified: true`; no partial-state error. |

## Failure and recovery scenarios

| ID | Scenario | Required behavior |
|---|---|---|
| TC-10 | Invalid/missing country code | Reject before plan creation. |
| TC-11 | DNS name conflict | Reject before plan creation. |
| TC-12 | Existing tenant | Reject before plan creation. |
| TC-13 | Tenant cannot be verified after DNS creation | Remove the newly-created DNS record and return an error. |
| TC-14 | Tenant exists but country write/read-back fails | Return `PARTIAL TENANT + DNS CREATION`; retain the verified tenant and DNS; do not create accounts automatically. |
| TC-15 | MCP client submits numeric `1` although its cached schema is stale | Coerce to text, validate, and plan successfully. |

## Cleanup

After TC-06 through TC-09 pass, plan removal of the test tenant and its Cloudflare A record. Review the exact targets, approve the cleanup, then independently verify both objects are gone. Do not reuse the same test FQDN until deletion has been confirmed.

## Current baseline

| Field | Result |
|---|---|
| Version | `0.14.9.2` |
| Date | 2026-09-17 |
| Test tenant | `country-test-20260917.audiomercy.com` |
| Calling code | `1` |
| DNS result | DNS-only A record created for `159.89.184.169` |
| Tenant result | Created and verified, Vodia tenant ID `71` |
| Country result | Read-back confirmed as `1` |
| Overall | PASS |
