# Vodia MCP — AWS Connect UX v1

## Goal

Remove the need for customers to paste the AWS Role ARN and External ID into every conversational session.

The customer instead opens **Connect AWS Account**, enters the values once, and clicks **Test & Save Connection**.

## User flow

1. Invoke `aws_connect_customer_account`.
2. The MCP host renders the AWS connection App.
3. Customer enters:
   - `VodiaMCPDeploymentRole` ARN
   - customer-specific External ID
4. The App calls `aws_save_customer_connection_profile`.
5. MCP performs a real STS `AssumeRole` test.
6. Only after STS succeeds, the profile is saved.
7. Future Marketplace/EC2 tools can omit `roleArn` and `externalId`; the server resolves the saved connection automatically.

## New tools

- `aws_connect_customer_account` — opens the MCP App.
- `aws_get_customer_connection_profile` — returns safe connection metadata only.
- `aws_save_customer_connection_profile` — STS tests, then saves the connection.

Existing AWS tools remain available and backward-compatible. Explicit `roleArn` + `externalId` still work; when both are omitted, the saved profile is used.

## Storage

The External ID is not an AWS secret key, but it is treated as private customer configuration.

The profile is encrypted at rest with AES-256-GCM.

Default locations:

- encrypted profile: `/var/lib/vodia-mcp/aws-connection-profile.enc`
- encryption key: `/var/lib/vodia-mcp/aws-connection.key`

The state directory is mode `0700`; key/profile files are mode `0600`.

Profile-read tools never return the External ID.

## Safety

- Test & Save performs STS only. It does not create infrastructure.
- Marketplace agreement acceptance is still not automated.
- EC2 launch remains separate and confirmation-gated.
- The existing plan -> DryRun -> exact approval -> apply flow is unchanged.
- The deployment planner freezes the resolved saved connection into the short-lived plan so later profile changes do not silently redirect that plan.

## Installer

`upgrade-vodia-mcp-v0.14.9.18-aws-connect-ux.sh`

Supported base:

- v0.14.9.17
- v0.14.9.17.1

When run on v0.14.9.17, the installer also repairs the duplicate AWS tool registration bug before activating the UX.

## First test

After installation and reconnecting the MCP client:

```text
aws_connect_customer_account
```

Enter the test role:

```text
arn:aws:iam::963966408518:role/VodiaMCPDeploymentRole
```

and the configured test External ID.

Expected UI state after clicking **Test & Save Connection**:

```text
AWS account connected
STS AssumeRole successful
Connection saved securely
```

Then a new session should be able to call:

```text
aws_check_customer_connection
```

with no Role ARN or External ID arguments.
