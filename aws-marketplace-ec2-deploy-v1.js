import { randomUUID } from "node:crypto";
import { loadAwsConnectionProfile, resolveAwsConnection, sanitizeAwsConnectionProfile, saveAwsConnectionProfile } from "./aws-connection-profile-v1.js";
import { fromTemporaryCredentials } from "@aws-sdk/credential-providers";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";
import {
  EC2Client,
  DescribeRegionsCommand,
  DescribeVpcsCommand,
  DescribeSubnetsCommand,
  DescribeSecurityGroupsCommand,
  DescribeKeyPairsCommand,
  DescribeImagesCommand,
  DescribeInstancesCommand,
  RunInstancesCommand
} from "@aws-sdk/client-ec2";
import {
  MarketplaceDiscoveryClient,
  SearchListingsCommand,
  ListPurchaseOptionsCommand,
  GetOfferCommand,
  GetOfferTermsCommand,
  ListFulfillmentOptionsCommand
} from "@aws-sdk/client-marketplace-discovery";
import {
  MarketplaceAgreementClient,
  SearchAgreementsCommand
} from "@aws-sdk/client-marketplace-agreement";

const AWS_DEPLOY_PLAN_TTL_MS = Number(process.env.VODIA_MCP_AWS_DEPLOY_PLAN_TTL_MS || 15 * 60 * 1000);
const AWS_DISCOVERY_REGION = process.env.VODIA_MCP_AWS_MARKETPLACE_DISCOVERY_REGION || "us-east-1";
const AWS_CONNECT_UI_URI = "ui://vodia/aws-connect/mcp-app.html";
const AWS_CONNECT_UI_HTML = process.env.VODIA_MCP_AWS_CONNECT_UI_HTML || "/opt/vodia-mcp/ui/aws-connect-app.html";
const deploymentPlans = new Map();

function customerCredentials(roleArn, externalId) {
  const connection = resolveAwsConnection(roleArn, externalId);
  if (!/^arn:aws:iam::\d{12}:role\/(?:[^/]+\/)*VodiaMCPDeploymentRole$/.test(connection.roleArn)) {
    throw new Error("INVALID_CUSTOMER_ROLE: roleArn must target a role named VodiaMCPDeploymentRole.");
  }
  return fromTemporaryCredentials({
    params: {
      RoleArn: connection.roleArn,
      ExternalId: connection.externalId,
      RoleSessionName: "vodia-mcp-deploy"
    }
  });
}

async function getCustomerIdentity(roleArn, externalId) {
  const credentials = customerCredentials(roleArn, externalId);
  const client = new STSClient({ region: AWS_DISCOVERY_REGION, credentials });
  const out = await client.send(new GetCallerIdentityCommand({}));
  return {
    account: out.Account || null,
    arn: out.Arn || null,
    userId: out.UserId || null
  };
}

function discoveryClient(roleArn, externalId) {
  return new MarketplaceDiscoveryClient({
    region: AWS_DISCOVERY_REGION,
    credentials: customerCredentials(roleArn, externalId)
  });
}

function agreementClient(roleArn, externalId) {
  return new MarketplaceAgreementClient({
    region: AWS_DISCOVERY_REGION,
    credentials: customerCredentials(roleArn, externalId)
  });
}

function ec2Client(roleArn, externalId, region) {
  return new EC2Client({
    region,
    credentials: customerCredentials(roleArn, externalId)
  });
}

async function searchVodiaListings(roleArn, externalId) {
  const client = discoveryClient(roleArn, externalId);
  const out = await client.send(new SearchListingsCommand({
    searchText: "Vodia",
    maxResults: 25,
    sortBy: "RELEVANCE",
    sortOrder: "DESCENDING"
  }));
  return out.listingSummaries || [];
}

async function getMarketplaceOffer(roleArn, externalId, productId, offerId) {
  const client = discoveryClient(roleArn, externalId);
  const options = await client.send(new ListPurchaseOptionsCommand({
    filters: [{ filterType: "PRODUCT_ID", filterValues: [productId] }],
    maxResults: 25
  }));

  let selectedOfferId = String(offerId || "").trim() || null;
  if (!selectedOfferId) {
    for (const option of options.purchaseOptions || []) {
      for (const entity of option.associatedEntities || []) {
        if (entity?.offer?.offerId) {
          selectedOfferId = entity.offer.offerId;
          break;
        }
      }
      if (selectedOfferId) break;
    }
  }

  if (!selectedOfferId) {
    return { productId, purchaseOptions: options.purchaseOptions || [], offer: null, terms: [] };
  }

  const [offer, terms, fulfillment] = await Promise.all([
    client.send(new GetOfferCommand({ offerId: selectedOfferId })),
    client.send(new GetOfferTermsCommand({ offerId: selectedOfferId, maxResults: 25 })),
    client.send(new ListFulfillmentOptionsCommand({ productId, maxResults: 50 }))
  ]);

  return {
    productId,
    selectedOfferId,
    purchaseOptions: options.purchaseOptions || [],
    offer,
    terms: terms.offerTerms || [],
    fulfillmentOptions: fulfillment.fulfillmentOptions || []
  };
}

async function checkSubscription(roleArn, externalId, productId) {
  const client = agreementClient(roleArn, externalId);
  const out = await client.send(new SearchAgreementsCommand({
    catalog: "AWSMarketplace",
    maxResults: 50,
    filters: [
      { name: "PartyType", values: ["Acceptor"] },
      { name: "AgreementType", values: ["PurchaseAgreement"] },
      { name: "ResourceIdentifier", values: [productId] },
      { name: "Status", values: ["ACTIVE"] }
    ]
  }));
  const agreements = out.agreementViewSummaries || [];
  return {
    productId,
    active: agreements.length > 0,
    agreements
  };
}

async function describeNetwork(roleArn, externalId, region) {
  const client = ec2Client(roleArn, externalId, region);
  const [vpcs, subnets, groups, keys] = await Promise.all([
    client.send(new DescribeVpcsCommand({})),
    client.send(new DescribeSubnetsCommand({})),
    client.send(new DescribeSecurityGroupsCommand({})),
    client.send(new DescribeKeyPairsCommand({}))
  ]);
  return {
    region,
    vpcs: (vpcs.Vpcs || []).map(v => ({
      vpcId: v.VpcId,
      cidrBlock: v.CidrBlock,
      isDefault: v.IsDefault,
      state: v.State,
      tags: v.Tags || []
    })),
    subnets: (subnets.Subnets || []).map(s => ({
      subnetId: s.SubnetId,
      vpcId: s.VpcId,
      availabilityZone: s.AvailabilityZone,
      cidrBlock: s.CidrBlock,
      mapPublicIpOnLaunch: s.MapPublicIpOnLaunch,
      availableIpAddressCount: s.AvailableIpAddressCount,
      state: s.State,
      tags: s.Tags || []
    })),
    securityGroups: (groups.SecurityGroups || []).map(g => ({
      groupId: g.GroupId,
      groupName: g.GroupName,
      vpcId: g.VpcId,
      description: g.Description
    })),
    keyPairs: (keys.KeyPairs || []).map(k => ({
      keyName: k.KeyName,
      keyPairId: k.KeyPairId,
      keyFingerprint: k.KeyFingerprint
    }))
  };
}

async function resolveMarketplaceAmi(client, { amiId, productCode }) {
  if (amiId) {
    const out = await client.send(new DescribeImagesCommand({ ImageIds: [amiId] }));
    const image = (out.Images || [])[0];
    if (!image) throw new Error(`AMI_NOT_FOUND: ${amiId}`);
    const marketplaceCodes = (image.ProductCodes || []).filter(p => p.ProductCodeType === "marketplace");
    if (!marketplaceCodes.length) throw new Error(`NOT_MARKETPLACE_AMI: ${amiId} has no Marketplace product code.`);
    if (productCode && !marketplaceCodes.some(p => p.ProductCodeId === productCode)) {
      throw new Error(`PRODUCT_CODE_MISMATCH: ${amiId} is not associated with ${productCode}.`);
    }
    return image;
  }

  const code = String(productCode || process.env.VODIA_AWS_MARKETPLACE_PRODUCT_CODE || "").trim();
  if (!code) {
    throw new Error("MARKETPLACE_PRODUCT_CODE_REQUIRED: pass productCode or set VODIA_AWS_MARKETPLACE_PRODUCT_CODE.");
  }

  const out = await client.send(new DescribeImagesCommand({
    Owners: ["aws-marketplace"],
    Filters: [
      { Name: "product-code", Values: [code] },
      { Name: "state", Values: ["available"] },
      { Name: "architecture", Values: ["x86_64"] }
    ]
  }));
  const images = [...(out.Images || [])].sort((a, b) => String(b.CreationDate || "").localeCompare(String(a.CreationDate || "")));
  if (!images.length) throw new Error(`NO_MARKETPLACE_AMI: no x86_64 AMI found for product code ${code} in this region.`);
  return images[0];
}

function buildRunInstancesParams(input, image) {
  const tags = [
    { Key: "Name", Value: input.name },
    { Key: "ManagedBy", Value: "VodiaMCP" },
    { Key: "VodiaMarketplaceProductId", Value: input.productId }
  ];
  const params = {
    ImageId: image.ImageId,
    InstanceType: input.instanceType,
    MinCount: 1,
    MaxCount: 1,
    IamInstanceProfile: { Name: input.iamInstanceProfileName },
    TagSpecifications: [
      { ResourceType: "instance", Tags: tags },
      { ResourceType: "volume", Tags: tags }
    ]
  };

  if (input.keyName) params.KeyName = input.keyName;

  const securityGroupIds = input.securityGroupIds || [];
  if (input.associatePublicIp) {
    params.NetworkInterfaces = [{
      DeviceIndex: 0,
      SubnetId: input.subnetId,
      Groups: securityGroupIds,
      AssociatePublicIpAddress: true,
      DeleteOnTermination: true
    }];
  } else {
    params.SubnetId = input.subnetId;
    params.SecurityGroupIds = securityGroupIds;
  }

  if (input.storageGiB) {
    params.BlockDeviceMappings = [{
      DeviceName: image.RootDeviceName || "/dev/sda1",
      Ebs: {
        VolumeSize: input.storageGiB,
        VolumeType: "gp3",
        DeleteOnTermination: true
      }
    }];
  }
  return params;
}

async function dryRunLaunch(client, params) {
  try {
    await client.send(new RunInstancesCommand({ ...params, DryRun: true }));
  } catch (error) {
    const code = String(error?.name || error?.Code || "");
    const message = String(error?.message || error);
    if (code === "DryRunOperation" || /DryRunOperation/i.test(message)) return { ok: true };
    throw error;
  }
  return { ok: true };
}

function cleanExpiredPlans() {
  const now = Date.now();
  for (const [id, plan] of deploymentPlans.entries()) {
    if (plan.expiresAt <= now) deploymentPlans.delete(id);
  }
}

export function registerAwsMarketplaceDeployTools(server, ctx) {
  const { z, toolOutputSchema, scopedAudit, scopedSuccess, failure } = ctx;

  // v0.14.9.18 AWS connection onboarding MCP App.
  server.registerResource(
    "Vodia AWS connection",
    AWS_CONNECT_UI_URI,
    { mimeType: "text/html;profile=mcp-app" },
    async () => {
      const { readFile } = await import("node:fs/promises");
      const html = await readFile(AWS_CONNECT_UI_HTML, "utf8");
      return { contents: [{ uri: AWS_CONNECT_UI_URI, mimeType: "text/html;profile=mcp-app", text: html }] };
    }
  );

  server.registerTool(
    "aws_connect_customer_account",
    {
      title: "Connect AWS account",
      description: "Opens the Vodia AWS connection UI. Customers enter the VodiaMCPDeploymentRole ARN and External ID once, test STS AssumeRole, and save the connection for future AWS deployment sessions.",
      inputSchema: {},
      outputSchema: toolOutputSchema,
      _meta: { ui: { resourceUri: AWS_CONNECT_UI_URI }, "ui/resourceUri": AWS_CONNECT_UI_URI },
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
    },
    async () => {
      try {
        const profile = sanitizeAwsConnectionProfile(loadAwsConnectionProfile());
        return scopedSuccess(
          { profile, changesMade: false },
          { operation: "AWS_CONNECTION_UI", readOnly: true },
          profile?.configured ? "AWS connection profile loaded." : "AWS connection setup is ready."
        );
      } catch (error) {
        return failure(error, "AWS connection profile load");
      }
    }
  );

  server.registerTool(
    "aws_get_customer_connection_profile",
    {
      title: "Get saved AWS connection",
      description: "Returns the saved AWS customer connection metadata without returning the External ID. Read-only.",
      inputSchema: {},
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
    },
    async () => {
      try {
        const profile = sanitizeAwsConnectionProfile(loadAwsConnectionProfile());
        return scopedSuccess({ profile, changesMade: false }, { operation: "AWS_CONNECTION_PROFILE_GET", readOnly: true }, profile?.configured ? "Saved AWS connection found." : "No saved AWS connection is configured.");
      } catch (error) {
        return failure(error, "AWS connection profile read");
      }
    }
  );

  server.registerTool(
    "aws_save_customer_connection_profile",
    {
      title: "Test and save AWS connection",
      description: "Tests STS AssumeRole with the supplied VodiaMCPDeploymentRole ARN and External ID. Only after the STS check succeeds, saves an encrypted connection profile for reuse by future AWS tools.",
      inputSchema: {
        roleArn: z.string().min(20),
        externalId: z.string().min(8)
      },
      outputSchema: toolOutputSchema,
      _meta: { ui: { resourceUri: AWS_CONNECT_UI_URI, visibility: ["app"] }, "ui/resourceUri": AWS_CONNECT_UI_URI },
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId }) => {
      scopedAudit("aws_save_customer_connection_profile", { roleArn });
      try {
        const identity = await getCustomerIdentity(roleArn, externalId);
        const profile = saveAwsConnectionProfile({
          roleArn,
          externalId,
          account: identity.account,
          assumedRoleArn: identity.arn
        });
        return scopedSuccess({ profile, identity, changesMade: true }, { operation: "AWS_CONNECTION_PROFILE_SAVE", readOnly: false }, "AWS connection tested successfully and saved.");
      } catch (error) {
        return failure(error, "AWS connection test/save");
      }
    }
  );

  server.registerTool(
    "aws_check_customer_connection",
    {
      title: "Check customer AWS connection",
      description: "Assumes the customer's VodiaMCPDeploymentRole and returns the temporary STS caller identity. If roleArn/externalId are omitted, uses the saved AWS connection profile. Makes no infrastructure changes.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId }) => {
      scopedAudit("aws_check_customer_connection", { roleArn });
      try {
        const identity = await getCustomerIdentity(roleArn, externalId);
        return scopedSuccess({ identity, changesMade: false }, { operation: "AWS_STS_CUSTOMER_CHECK", readOnly: true }, "Customer AWS role assumed successfully.");
      } catch (error) {
        return failure(error, "AWS customer connection check");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_search_vodia",
    {
      title: "Search Vodia in AWS Marketplace",
      description: "Searches AWS Marketplace Discovery in the customer's account for Vodia listings. Uses the saved AWS connection when roleArn/externalId are omitted. Read-only.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId }) => {
      scopedAudit("aws_marketplace_search_vodia", { roleArn });
      try {
        const listings = await searchVodiaListings(roleArn, externalId);
        return scopedSuccess({ listings, discoveryRegion: AWS_DISCOVERY_REGION, changesMade: false }, { operation: "AWS_MARKETPLACE_SEARCH_VODIA", readOnly: true }, `Found ${listings.length} Marketplace listing(s) matching Vodia.`);
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia search");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_get_offer",
    {
      title: "Get AWS Marketplace Vodia offer",
      description: "Reads available purchase options, offer terms, and fulfillment options for a Marketplace product. Does not subscribe or accept terms.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional().optional(),
        productId: z.string().min(3),
        offerId: z.string().optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId, productId, offerId }) => {
      scopedAudit("aws_marketplace_get_offer", { roleArn, productId, offerId: offerId || null });
      try {
        const result = await getMarketplaceOffer(roleArn, externalId, productId, offerId);
        return scopedSuccess({ ...result, changesMade: false }, { operation: "AWS_MARKETPLACE_GET_OFFER", readOnly: true }, "Marketplace purchase options and terms loaded; nothing was accepted.");
      } catch (error) {
        return failure(error, "AWS Marketplace offer discovery");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_check_subscription",
    {
      title: "Check AWS Marketplace subscription",
      description: "Checks for an ACTIVE PurchaseAgreement for the specified Marketplace product in the customer's account. Read-only.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional().optional(),
        productId: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId, productId }) => {
      scopedAudit("aws_marketplace_check_subscription", { roleArn, productId });
      try {
        const result = await checkSubscription(roleArn, externalId, productId);
        return scopedSuccess({ ...result, changesMade: false }, { operation: "AWS_MARKETPLACE_CHECK_SUBSCRIPTION", readOnly: true }, result.active ? "Active Marketplace agreement found." : "No active Marketplace agreement found.");
      } catch (error) {
        return failure(error, "AWS Marketplace subscription check");
      }
    }
  );

  server.registerTool(
    "aws_list_deployment_regions",
    {
      title: "List AWS deployment regions",
      description: "Lists EC2 regions available to the customer account. Read-only.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId }) => {
      scopedAudit("aws_list_deployment_regions", { roleArn });
      try {
        const client = ec2Client(roleArn, externalId, AWS_DISCOVERY_REGION);
        const out = await client.send(new DescribeRegionsCommand({ AllRegions: false }));
        const regions = (out.Regions || []).map(r => ({ regionName: r.RegionName, endpoint: r.Endpoint, optInStatus: r.OptInStatus }));
        return scopedSuccess({ regions, changesMade: false }, { operation: "AWS_EC2_LIST_REGIONS", readOnly: true }, `Found ${regions.length} available EC2 region(s).`);
      } catch (error) {
        return failure(error, "AWS EC2 region discovery");
      }
    }
  );

  server.registerTool(
    "aws_discover_deployment_network",
    {
      title: "Discover AWS deployment network",
      description: "Lists VPCs, subnets, security groups, and key pairs in a selected customer region. Read-only.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional().optional(),
        region: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId, region }) => {
      scopedAudit("aws_discover_deployment_network", { roleArn, region });
      try {
        const result = await describeNetwork(roleArn, externalId, region);
        return scopedSuccess({ ...result, changesMade: false }, { operation: "AWS_EC2_DISCOVER_NETWORK", readOnly: true }, "Customer VPC, subnet, security-group, and key-pair inventory loaded.");
      } catch (error) {
        return failure(error, "AWS deployment network discovery");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_plan_vodia_pbx_deployment",
    {
      title: "Plan Vodia PBX deployment on AWS",
      description: "Creates a short-lived deployment plan only after an ACTIVE AWS Marketplace agreement is verified. Performs EC2 RunInstances DryRun to validate IAM, Marketplace entitlement, AMI, network, instance profile, and launch parameters. Makes no EC2 changes.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional().optional(),
        productId: z.string().min(3),
        productCode: z.string().optional(),
        amiId: z.string().optional(),
        region: z.string().min(3),
        subnetId: z.string().min(3),
        securityGroupIds: z.array(z.string()).min(1),
        instanceType: z.string().min(3),
        iamInstanceProfileName: z.string().min(1),
        keyName: z.string().optional(),
        storageGiB: z.number().int().min(8).max(16384).optional(),
        associatePublicIp: z.boolean().default(true),
        name: z.string().min(1).max(128)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async (input) => {
      const resolvedConnection = resolveAwsConnection(input.roleArn, input.externalId);
      input = { ...input, roleArn: resolvedConnection.roleArn, externalId: resolvedConnection.externalId };
      scopedAudit("aws_marketplace_plan_vodia_pbx_deployment", {
        roleArn: input.roleArn,
        productId: input.productId,
        region: input.region,
        subnetId: input.subnetId,
        instanceType: input.instanceType,
        name: input.name
      });
      try {
        cleanExpiredPlans();
        const subscription = await checkSubscription(input.roleArn, input.externalId, input.productId);
        if (!subscription.active) {
          throw new Error("SUBSCRIPTION_REQUIRED: no ACTIVE AWS Marketplace PurchaseAgreement was found for this product. Accept the Marketplace offer first.");
        }

        const client = ec2Client(input.roleArn, input.externalId, input.region);
        const image = await resolveMarketplaceAmi(client, input);
        const params = buildRunInstancesParams(input, image);
        await dryRunLaunch(client, params);

        const planId = randomUUID();
        const confirmation = `APPROVE DEPLOY ${input.name} IN ${input.region}`;
        const expiresAt = Date.now() + AWS_DEPLOY_PLAN_TTL_MS;
        deploymentPlans.set(planId, {
          planId,
          roleArn: input.roleArn,
          externalId: input.externalId,
          productId: input.productId,
          region: input.region,
          name: input.name,
          imageId: image.ImageId,
          imageName: image.Name || null,
          productCodes: image.ProductCodes || [],
          params,
          confirmation,
          createdAt: Date.now(),
          expiresAt
        });

        return scopedSuccess({
          planId,
          expiresAt: new Date(expiresAt).toISOString(),
          confirmation,
          subscriptionVerified: true,
          dryRunVerified: true,
          deployment: {
            name: input.name,
            region: input.region,
            imageId: image.ImageId,
            imageName: image.Name || null,
            instanceType: input.instanceType,
            subnetId: input.subnetId,
            securityGroupIds: input.securityGroupIds,
            associatePublicIp: input.associatePublicIp,
            storageGiB: input.storageGiB || null,
            iamInstanceProfileName: input.iamInstanceProfileName
          },
          changesMade: false
        }, { operation: "AWS_MARKETPLACE_PLAN_VODIA_PBX_DEPLOYMENT", readOnly: true }, "Deployment plan validated. No instance has been launched. Use the exact confirmation string with the apply tool.");
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia PBX deployment plan");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_apply_vodia_pbx_deployment",
    {
      title: "Deploy Vodia PBX on AWS",
      description: "Approval-gated EC2 launch for a previously validated Vodia Marketplace deployment plan. Requires the exact confirmation string returned by the planner.",
      inputSchema: {
        planId: z.string().uuid(),
        confirmation: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
    },
    async ({ planId, confirmation }) => {
      scopedAudit("aws_marketplace_apply_vodia_pbx_deployment", { planId });
      try {
        cleanExpiredPlans();
        const plan = deploymentPlans.get(planId);
        if (!plan) throw new Error("PLAN_NOT_FOUND_OR_EXPIRED: create a new deployment plan.");
        if (confirmation !== plan.confirmation) throw new Error(`CONFIRMATION_MISMATCH: exact confirmation required: ${plan.confirmation}`);

        const subscription = await checkSubscription(plan.roleArn, plan.externalId, plan.productId);
        if (!subscription.active) throw new Error("SUBSCRIPTION_NO_LONGER_ACTIVE: deployment aborted.");

        const client = ec2Client(plan.roleArn, plan.externalId, plan.region);
        const out = await client.send(new RunInstancesCommand(plan.params));
        const instance = (out.Instances || [])[0];
        if (!instance?.InstanceId) throw new Error("EC2_LAUNCH_UNVERIFIED: RunInstances returned no instance ID.");

        deploymentPlans.delete(planId);
        return scopedSuccess({
          instanceId: instance.InstanceId,
          state: instance.State?.Name || "pending",
          privateIpAddress: instance.PrivateIpAddress || null,
          publicIpAddress: instance.PublicIpAddress || null,
          privateDnsName: instance.PrivateDnsName || null,
          publicDnsName: instance.PublicDnsName || null,
          imageId: plan.imageId,
          region: plan.region,
          name: plan.name,
          marketplaceSubscriptionVerifiedBeforeLaunch: true,
          changesMade: true
        }, { operation: "AWS_MARKETPLACE_APPLY_VODIA_PBX_DEPLOYMENT", readOnly: false }, `Vodia PBX EC2 instance ${instance.InstanceId} launched in ${plan.region}.`);
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia PBX deployment apply");
      }
    }
  );

  server.registerTool(
    "aws_get_vodia_pbx_deployment_status",
    {
      title: "Get Vodia PBX deployment status",
      description: "Reads the EC2 state and network addresses of a deployed Vodia PBX instance.",
      inputSchema: {
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional().optional(),
        region: z.string().min(3),
        instanceId: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ roleArn, externalId, region, instanceId }) => {
      scopedAudit("aws_get_vodia_pbx_deployment_status", { roleArn, region, instanceId });
      try {
        const client = ec2Client(roleArn, externalId, region);
        const out = await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
        const instance = out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${instanceId}`);
        return scopedSuccess({
          instanceId,
          state: instance.State?.Name || null,
          imageId: instance.ImageId || null,
          instanceType: instance.InstanceType || null,
          availabilityZone: instance.Placement?.AvailabilityZone || null,
          privateIpAddress: instance.PrivateIpAddress || null,
          publicIpAddress: instance.PublicIpAddress || null,
          privateDnsName: instance.PrivateDnsName || null,
          publicDnsName: instance.PublicDnsName || null,
          launchTime: instance.LaunchTime || null,
          changesMade: false
        }, { operation: "AWS_EC2_GET_VODIA_PBX_DEPLOYMENT_STATUS", readOnly: true }, `Instance ${instanceId} state: ${instance.State?.Name || "unknown"}.`);
      } catch (error) {
        return failure(error, "AWS Vodia PBX deployment status");
      }
    }
  );
}
