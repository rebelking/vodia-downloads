# Vodia MCP — Microsoft Teams DNS Provider Selector v1

## Purpose

Adds a read-only planning step before Microsoft Teams Direct Routing DNS work so the administrator explicitly chooses how the SBC hostname will be managed.

Supported choices:

- `vodia` — Vodia-managed DNS / wildcard path
- `cloudflare` — existing saved Cloudflare integration
- `manual` — customer or other external DNS provider

The planner never makes a DNS, Microsoft 365, or PBX change.

## Why this exists

Vodia deployments do not all use the same DNS model. Some use Vodia-managed DNS, some use Cloudflare, and some customers manage DNS elsewhere. Teams Direct Routing also needs the SBC FQDN to belong to a verified Microsoft 365 custom domain, so DNS provider choice and Microsoft-domain validation must happen before any Direct Routing write.

## New MCP tool

`microsoft_plan_teams_dns`

Inputs:

- `sbcFqdn` — required, for example `teams.audiomercy.com`
- `dnsProvider` — optional: `vodia`, `cloudflare`, or `manual`
- `ipv4` — optional public PBX IPv4

If `dnsProvider` is omitted, the tool returns:

- `requiresProviderChoice: true`
- a provider question
- all three provider options
- current Microsoft verified custom-domain match
- current saved Cloudflare availability/zone when the Cloudflare integration exists

This is intentional: the client should ask the administrator instead of silently choosing a provider.

## Install

```bash
wget -O /root/upgrade-vodia-mcp-microsoft-teams-dns-provider-v1.sh \
https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-microsoft-teams-dns-provider-v1.sh

chmod +x /root/upgrade-vodia-mcp-microsoft-teams-dns-provider-v1.sh
bash -n /root/upgrade-vodia-mcp-microsoft-teams-dns-provider-v1.sh \
  && echo "PASS: installer syntax valid"

/root/upgrade-vodia-mcp-microsoft-teams-dns-provider-v1.sh
```

The installer:

1. verifies Microsoft Phase 1 is present;
2. patches a staged copy of `index.js`;
3. validates exact tool registration count;
4. backs up the live file;
5. activates the staged code;
6. restarts `vodia-mcp`;
7. checks `/health` and recent runtime errors.

## First test — force provider question

Ask the MCP client:

```text
Use microsoft_plan_teams_dns with sbcFqdn teams.audiomercy.com and do not choose a DNS provider yet.
```

Expected behavior:

```text
requiresProviderChoice: true
question: Which DNS provider should be used for this Teams SBC hostname?
options:
  - Vodia managed DNS
  - Cloudflare
  - External / manual DNS
changesMade: false
```

## Second test — Cloudflare

```text
Use microsoft_plan_teams_dns for teams.audiomercy.com with dnsProvider cloudflare.
```

The tool should check:

- Microsoft custom-domain verification
- whether the saved Cloudflare integration exists
- whether the saved Cloudflare zone controls the SBC hostname
- blockers/warnings
- proposed guarded sequence

It does not create the A record. Existing Cloudflare plan/approve/apply tools remain the write path.

## Second test — Vodia DNS

```text
Use microsoft_plan_teams_dns for the selected SBC FQDN with dnsProvider vodia.
```

The planner will require the SBC hostname to be under a verified Microsoft custom domain and will tell the administrator to verify Vodia is authoritative for the chosen hostname before any DNS mapping is applied.

## Second test — manual/external DNS

```text
Use microsoft_plan_teams_dns for teams.customer.com with dnsProvider manual and ipv4 203.0.113.10.
```

The result provides the required hostname/target and a verification sequence, but the customer or administrator performs the DNS change at their external provider.

## Safety model

This phase is planning only:

`DISCOVER -> ASK PROVIDER -> PLAN -> VERIFY PREREQUISITES`

Future write phases should continue the established guarded model:

`PLAN -> APPROVE -> APPLY -> VERIFY`

Cloudflare writes should reuse the existing approval-gated Cloudflare workflow rather than introduce a second DNS-write implementation.

## Current Collado Telecom note

The Microsoft tenant currently needs a verified custom domain before a hostname such as `teams.audiomercy.com` can pass the Teams DNS prerequisite. The initial `*.onmicrosoft.com` domain is not treated as a custom Direct Routing SBC domain by this planner.
