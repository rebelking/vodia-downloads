# Vodia MCP - AWS Customer IAM Setup

This document records the AWS IAM configuration used by the Vodia MCP AWS Marketplace + EC2 deployment flow introduced in **v0.14.9.17**.

## Current status

The MCP-side AWS work is installed and active.

- Vodia MCP version: `0.14.9.17`
- MCP EC2 role: `VodiaMCPChimeRole`
- Customer/destination role: `VodiaMCPDeploymentRole`
- Customer inline policy: `VodiaMCPDeploymentRolePolicy`
- Test External ID: `vodia-test-customer-001`
- Test account: `963966408518`

The MCP-side role already has permission to call `sts:AssumeRole` against a role named `VodiaMCPDeploymentRole`.

The important distinction is:

```text
MCP side
VodiaMCPChimeRole
    |
    | sts:AssumeRole permission
    v
Customer / destination AWS account
VodiaMCPDeploymentRole
    |
    | trust policy allows VodiaMCPChimeRole
    v
Temporary STS credentials
```

Both sides are required. The MCP-side permission allows the attempt; the destination role trust policy allows entry.

## 1. VodiaMCPDeploymentRole trust relationship

AWS Console path:

```text
IAM -> Roles -> VodiaMCPDeploymentRole
    -> Trust relationships
    -> Edit trust policy
```

Current test trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::963966408518:role/VodiaMCPChimeRole"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "vodia-test-customer-001"
        }
      }
    }
  ]
}
```

For production customer onboarding, use a **unique External ID per customer**.

## 2. VodiaMCPDeploymentRole permissions

AWS Console path:

```text
IAM -> Roles -> VodiaMCPDeploymentRole
    -> Permissions
    -> VodiaMCPDeploymentRolePolicy
    -> Edit
    -> JSON
```

Policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "MarketplaceRead",
      "Effect": "Allow",
      "Action": [
        "aws-marketplace:SearchListings",
        "aws-marketplace:GetProduct",
        "aws-marketplace:ListFulfillmentOptions",
        "aws-marketplace:ListPurchaseOptions",
        "aws-marketplace:GetOffer",
        "aws-marketplace:GetOfferTerms",
        "aws-marketplace:SearchAgreements",
        "aws-marketplace:DescribeAgreement",
        "aws-marketplace:GetAgreementTerms",
        "aws-marketplace:GetAgreementEntitlements",
        "aws-marketplace:ViewSubscriptions"
      ],
      "Resource": "*"
    },
    {
      "Sid": "EC2ReadAndLaunch",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeRegions",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceTypes",
        "ec2:RunInstances",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PassVodiaEntitlementRoleOnly",
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/VodiaPBXMarketplaceEntitlementRole"
    }
  ]
}
```

Do **not** attach `AdministratorAccess`. The role is intentionally limited to Marketplace read/check operations, EC2 discovery and launch, tagging, and `iam:PassRole` only for the Vodia PBX Marketplace entitlement role.

## 3. Naming correction recorded

During setup, a role was accidentally created with the policy-style name:

```text
VodiaMCPDeploymentPolicy
```

That role is not part of the intended design and can be deleted.

The intended structure is:

```text
IAM Role
└── VodiaMCPDeploymentRole
    ├── Trust relationship
    │   └── trusts VodiaMCPChimeRole with External ID
    └── Inline policy
        └── VodiaMCPDeploymentRolePolicy
```

## 4. First MCP connection test

Reconnect or start a fresh MCP client session after the IAM changes.

Call:

```text
aws_check_customer_connection
```

Inputs:

```text
roleArn:
arn:aws:iam::963966408518:role/VodiaMCPDeploymentRole

externalId:
vodia-test-customer-001
```

Expected result:

- STS `AssumeRole` succeeds.
- The MCP receives temporary AWS credentials for `VodiaMCPDeploymentRole`.
- No PBX is launched by this test.

## 5. Validation sequence after the connection passes

Run the tools in this order:

```text
aws_marketplace_search_vodia
        |
        v
aws_marketplace_check_subscription
        |
        v
aws_list_deployment_regions
        |
        v
aws_discover_deployment_network
        |
        v
aws_marketplace_plan_vodia_pbx_deployment
        |
        v
EC2 DryRun only
        |
        v
APPROVE DEPLOY <name> IN <region>
        |
        v
aws_marketplace_apply_vodia_pbx_deployment
        |
        v
aws_get_vodia_pbx_deployment_status
```

The deployment planner verifies an ACTIVE Marketplace agreement and performs an EC2 DryRun before the explicit deployment approval.

## 6. PBX Marketplace entitlement role

Before an actual PBX launch, create:

```text
VodiaPBXMarketplaceEntitlementRole
```

The role must trust:

```text
ec2.amazonaws.com
```

Attach the AWS managed policy:

```text
AWSMarketplaceGetEntitlements
```

Then create/use an EC2 instance profile for this role and pass that instance profile during the PBX deployment plan.

## Security model

- No customer static AWS access keys are stored by the MCP.
- Cross-account access uses temporary AWS STS credentials.
- A unique External ID is used per customer.
- Marketplace subscription/terms acceptance is separate from EC2 deployment approval.
- v0.14.9.17 does not automatically accept Marketplace commercial terms.
- EC2 launch requires the exact short-lived approval string generated by the deployment plan.
