# Vodia MCP — Microsoft 365 Phase 1

## Goal

Connect the existing Vodia MCP to Microsoft 365 using a Microsoft Entra application and Microsoft Graph. Phase 1 is read-only.

## Microsoft Entra setup

1. Open Microsoft Entra admin center.
2. Go to **Entra ID > App registrations > New registration**.
3. Name the app **Vodia MCP**.
4. Choose **Single tenant only**.
5. Leave Redirect URI blank.
6. Register the application.
7. Save the **Application (client) ID** and **Directory (tenant) ID**.

## Microsoft Graph application permissions

Go to **Vodia MCP > API permissions > Add a permission > Microsoft Graph > Application permissions**.

Add:

- `User.Read.All`
- `Organization.Read.All`
- `Domain.Read.All`

Then select **Grant admin consent** for the tenant.

## Client secret

Go to **Certificates & secrets > Client secrets > New client secret**.

Create a short-lived lab secret and copy the **secret Value** immediately. Do not place the secret in GitHub, documentation, screenshots, or chat messages.

## Install Phase 1 on the MCP server

Run as root:

```bash
wget -O /root/upgrade-vodia-mcp-microsoft-phase1.sh \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-microsoft-phase1.sh

chmod +x /root/upgrade-vodia-mcp-microsoft-phase1.sh
bash -n /root/upgrade-vodia-mcp-microsoft-phase1.sh \
  && echo "PASS: installer syntax valid"

/root/upgrade-vodia-mcp-microsoft-phase1.sh
```

The installer creates:

```text
/etc/vodia-mcp/microsoft.env
/etc/systemd/system/vodia-mcp.service.d/microsoft.conf
```

The credential file is created with mode `0600`.

## Add the Microsoft credentials

Edit:

```bash
nano /etc/vodia-mcp/microsoft.env
```

Fill only these values:

```bash
MICROSOFT_TENANT_ID=<Directory tenant ID>
MICROSOFT_CLIENT_ID=<Application client ID>
MICROSOFT_CLIENT_SECRET=<Client secret VALUE>
```

Then restart:

```bash
systemctl daemon-reload
systemctl restart vodia-mcp
systemctl status vodia-mcp --no-pager
```

Never commit `/etc/vodia-mcp/microsoft.env` to GitHub.

## MCP tools added

### `microsoft_check_graph_readiness`
Tests OAuth app-only authentication plus organization, domain, user, and license reads.

### `microsoft_get_tenant`
Returns the Microsoft 365 organization and domains.

### `microsoft_list_domains`
Lists tenant domains and verified/default status.

### `microsoft_list_users`
Lists basic Microsoft 365 user identity data and assigned license IDs.

### `microsoft_list_licenses`
Lists subscribed Microsoft 365 SKUs and consumption.

## Safety

Phase 1 is read-only.

It does not:

- create or delete Microsoft users
- assign licenses
- assign phone numbers
- configure Teams Direct Routing
- create PSTN gateways
- create voice routes or policies
- change Vodia PBX configuration

## First test

From Codex or another MCP client, call:

```text
microsoft_check_graph_readiness
```

Expected result:

```text
ready: true
changesMade: false

oauth_client_credentials  PASS
organization_read         PASS
domain_read               PASS
user_read                 PASS
license_read              PASS
```

Then test:

```text
microsoft_get_tenant
microsoft_list_domains
microsoft_list_users
microsoft_list_licenses
```

## Phase 2

After Phase 1 passes, add Microsoft Teams Direct Routing inspection and planning tools. Write operations should remain approval-gated and be added only after read-only validation is stable.
