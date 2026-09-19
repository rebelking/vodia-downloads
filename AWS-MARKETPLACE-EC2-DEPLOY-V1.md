# Vodia MCP — AWS Marketplace + EC2 Deployment v1

## Purpose

This phase lets the Vodia MCP connect to a customer's AWS account with STS, verify that the customer has an active AWS Marketplace agreement for the Vodia product, validate an EC2 launch, and deploy the subscribed Vodia Marketplace AMI only after explicit approval.

As of **v0.14.9.27**, Marketplace commercial acceptance can stay inside the MCP/chat flow. The MCP presents the live Vodia offer, creates an AWS-calculated quote, requires explicit customer approval, accepts that specific agreement request, verifies the resulting subscription, and only then hands off to the separate EC2 deployment approval.

## Current Vodia Marketplace product

Public listing:

- **Vodia Prepaid Offer**
- Seller: **Vodia Networks Inc**
- Delivery: **Amazon Machine Image (AMI)**
- Current public listing shows Ubuntu 26.04 LTS and x86-64 delivery.
- Public Marketplace page: `https://aws.amazon.com/marketplace/pp/prodview-k4gepe5tujjgy`

The Marketplace page states that deployed Vodia instances need an IAM role with the AWS managed policy:

`arn:aws:iam::aws:policy/AWSMarketplaceGetEntitlements`

## Security model

```text
Vodia MCP EC2
  |
  | existing instance role
  v
VodiaMCPChimeRole
  |
  | sts:AssumeRole + unique customer External ID
  v
Customer AWS account
  |
  v
VodiaMCPDeploymentRole
  |
  +--> Marketplace read / agreement verification
  +--> EC2 discovery
  +--> EC2 RunInstances after approval
  +--> iam:PassRole ONLY to VodiaPBXMarketplaceEntitlementRole
               |
               v
       New Vodia PBX EC2 instance
```

No customer access key or secret key is stored by this phase.

## Files

- `aws-marketplace-ec2-deploy-v1.js`
  - MCP tool module.
- `upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh`
  - guarded installer for a v0.14.9.16 base.
- `aws-marketplace-vodia-customer-trust-policy-v1.json`
  - customer-side cross-account trust template.
- `aws-marketplace-vodia-deployment-role-policy-v1.json`
  - customer-side deployment permissions.
- `aws-marketplace-vodia-pbx-entitlement-role-trust-v1.json`
  - trust policy for the role attached to the deployed PBX EC2 instance.

## New MCP tools

### Read-only / discovery

- `aws_check_customer_connection`
- `aws_marketplace_search_vodia`
- `aws_marketplace_get_offer`
- `aws_marketplace_present_vodia_offer`
- `aws_marketplace_check_subscription`
- `aws_list_deployment_regions`
- `aws_discover_deployment_network`
- `aws_get_vodia_pbx_deployment_status`

### Guarded Marketplace purchase

- `aws_marketplace_prepare_vodia_purchase`
  - validates the selected live Marketplace dimension/plan
  - creates an AWS Agreement API quote with `CreateAgreementRequest`
  - requests AWS tax estimation
  - returns the AWS-calculated charge summary
  - returns a short-lived exact confirmation string
  - does **not** accept the agreement

- `aws_marketplace_accept_vodia_purchase`
  - requires the exact confirmation string from the prepared quote
  - accepts only that short-lived agreement request
  - can create a billable AWS Marketplace agreement
  - returns the resulting agreement ID and subscription propagation status

Marketplace purchase approval and EC2 deployment approval are deliberately separate.

### Guarded deployment

- `aws_marketplace_plan_vodia_pbx_deployment`
  - verifies ACTIVE Marketplace PurchaseAgreement
  - resolves/validates the Marketplace AMI
  - validates networking and instance-profile parameters through EC2 `RunInstances(DryRun=true)`
  - creates a short-lived plan
  - makes no EC2 changes

- `aws_marketplace_apply_vodia_pbx_deployment`
  - requires the exact approval string from the plan
  - rechecks the active Marketplace agreement immediately before launch
  - launches one EC2 instance
  - removes the plan after use

Example approval string:

```text
APPROVE DEPLOY customer-pbx IN us-east-1
```

Plans expire after 15 minutes by default.

## Customer role

Create a customer role named exactly:

```text
VodiaMCPDeploymentRole
```

Its trust policy must trust:

```text
arn:aws:iam::963966408518:role/VodiaMCPChimeRole
```

and require a unique External ID for that customer.

Use:

`aws-marketplace-vodia-customer-trust-policy-v1.json`

Attach the deployment policy:

`aws-marketplace-vodia-deployment-role-policy-v1.json`

## PBX EC2 entitlement role

Create a separate role in the customer account:

```text
VodiaPBXMarketplaceEntitlementRole
```

Trust principal:

```text
ec2.amazonaws.com
```

Attach AWS managed policy:

```text
arn:aws:iam::aws:policy/AWSMarketplaceGetEntitlements
```

Create an EC2 instance profile for this role. The PBX should use this entitlement role/profile when Marketplace entitlement checks are required. The deployment planner now accepts the instance profile name as optional at schema level so discovery/validation is not blocked by IAM listing permissions; production Vodia Marketplace deployments should still attach the entitlement profile when the AMI/license flow requires it.

The customer deployment role is permitted to `iam:PassRole` only for this Vodia PBX entitlement role.

## Install on the MCP test server

The installer currently defaults its module source to the test branch:

```text
feature/aws-marketplace-ec2-deploy-v1
```

Run:

```bash
wget -O /root/upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/feature/aws-marketplace-ec2-deploy-v1/upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh

chmod +x /root/upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh
bash -n /root/upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh \
  && echo "PASS: installer syntax valid"

/root/upgrade-vodia-mcp-v0.14.9.17-aws-marketplace-ec2-deploy-v1.sh
```

The installer:

1. requires current MCP version 0.14.9.16;
2. backs up `index.js`, `version.js`, package files, and any prior deployment module;
3. installs only the AWS SDK clients required by this phase;
4. installs the Marketplace/EC2 module;
5. registers the tools;
6. performs static safety checks;
7. restarts the MCP;
8. requires health to report version 0.14.9.17;
9. rolls back application files if activation fails.

## Recommended validation order

1. Run `aws_check_customer_connection`.
2. Confirm the returned STS ARN belongs to the customer's `VodiaMCPDeploymentRole`.
3. Run `aws_marketplace_search_vodia`.
4. Identify the Vodia Marketplace product ID.
5. Run `aws_marketplace_get_offer` and review the offer/fulfillment data.
6. Run `aws_marketplace_check_subscription`.
7. Confirm `active: true`.
8. Run `aws_list_deployment_regions`.
9. Run `aws_discover_deployment_network` for the selected region.
10. Create/confirm the PBX entitlement instance profile.
11. Run `aws_marketplace_plan_vodia_pbx_deployment`.
12. Confirm:
    - Marketplace agreement verified;
    - AMI is a Marketplace AMI;
    - DryRun passes;
    - correct region/VPC/subnet/security groups;
    - correct instance type/storage;
    - correct entitlement instance profile.
13. Submit the exact `APPROVE DEPLOY ...` string.
14. Run `aws_marketplace_apply_vodia_pbx_deployment`.
15. Run `aws_get_vodia_pbx_deployment_status` until the instance is running.
16. Test the Vodia PBX on its public DNS/IP.
17. Confirm the PBX can read Marketplace entitlement.

## Product code note

AWS Marketplace **product ID** and **AMI product code** are different values.

The Agreement API uses the Marketplace product ID. EC2 AMI discovery can use the AMI product code.

For v1, either:

- pass a known Marketplace `amiId`, or
- pass/set the Vodia AMI product code with `productCode` / `VODIA_AWS_MARKETPLACE_PRODUCT_CODE`.

The planner validates that a supplied AMI has a Marketplace product code.

## Not included in v1

- unattended or silent acceptance of Marketplace terms;
- automatic creation of customer IAM roles;
- automatic creation of the PBX entitlement role/profile;
- automatic security-group creation;
- terminate/replace/resize actions;
- DNS and Vodia tenant configuration after EC2 launch.

Those should remain separate guarded phases.

## Current purchase flow

```text
discover offer
  -> display live pricing/EULA/terms in chat
  -> customer selects Vodia plan
  -> create AWS quote/agreement request
  -> display AWS-calculated charges
  -> explicit commercial approval
  -> accept agreement request
  -> verify ACTIVE agreement
  -> hand off to deployment planner
  -> separate EC2 deployment approval
```

Subscription acceptance and EC2 deployment remain two separate approvals.
