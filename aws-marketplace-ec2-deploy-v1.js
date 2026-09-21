import { randomUUID } from "node:crypto";
import { loadAwsConnectionProfile, resolveAwsConnection, sanitizeAwsConnectionProfile, saveAwsConnectionProfile } from "./aws-connection-profile-v1.js";
import { requireCustomerAccess, recordCommercialAudit } from "./msp-authz-v1.js";
import { resolveScopedAwsConnection } from "./msp-customer-connections-v1.js";
import { fromTemporaryCredentials } from "@aws-sdk/credential-providers";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";
import {
  EC2Client,
  DescribeRegionsCommand,
  DescribeVpcsCommand,
  DescribeSubnetsCommand,
  DescribeSecurityGroupsCommand,
  DescribeKeyPairsCommand,
  DescribeInstanceTypesCommand,
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
  SearchAgreementsCommand,
  CreateAgreementRequestCommand,
  AcceptAgreementRequestCommand
} from "@aws-sdk/client-marketplace-agreement";

const AWS_DEPLOY_PLAN_TTL_MS = Number(process.env.VODIA_MCP_AWS_DEPLOY_PLAN_TTL_MS || 15 * 60 * 1000);
const AWS_DISCOVERY_REGION = process.env.VODIA_MCP_AWS_MARKETPLACE_DISCOVERY_REGION || "us-east-1";
const AWS_CONNECT_UI_URI = "ui://vodia/aws-connect/mcp-app.html";
const AWS_CONNECT_UI_HTML = process.env.VODIA_MCP_AWS_CONNECT_UI_HTML || "/opt/vodia-mcp/ui/aws-connect-app.html";
const REQUIRE_MSP_CUSTOMER_CONTEXT = String(process.env.VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT || "").toLowerCase() === "true";
const deploymentPlans = new Map();
const deploymentLocks = new Set();
const marketplacePurchaseQuotes = new Map();
const AWS_MARKETPLACE_QUOTE_TTL_MS = Number(process.env.VODIA_MCP_AWS_MARKETPLACE_QUOTE_TTL_MS || 15 * 60 * 1000);

function resolveToolConnection({ customerId, roleArn, externalId }, extra, allowedRoles = ["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"]) {
  if (customerId) {
    const access = requireCustomerAccess(extra, customerId, allowedRoles);
    const scoped = resolveScopedAwsConnection(customerId);
    return { ...scoped, customerId, access };
  }
  if (REQUIRE_MSP_CUSTOMER_CONTEXT) {
    throw new Error("CUSTOMER_CONTEXT_REQUIRED: select an MSP customer before using AWS tools.");
  }
  return { ...resolveAwsConnection(roleArn, externalId), customerId: null, access: null };
}

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


function offerTermEntries(terms) {
  return (terms || []).map(wrapper => {
    const entry = Object.entries(wrapper || {})[0] || [];
    const [kind, value] = entry;
    return { kind, value: value || {} };
  }).filter(x => x.kind && x.value?.id);
}

function normalizeVodiaMarketplaceOffer(result) {
  const offer = result.offer || {};
  const entries = offerTermEntries(result.terms);
  const pricing = entries.find(x => x.kind === "configurableUpfrontPricingTerm")?.value || null;
  const support = entries.find(x => x.kind === "supportTerm")?.value || null;
  const legal = entries.find(x => x.kind === "legalTerm")?.value || null;
  const renewal = entries.find(x => x.kind === "renewalTerm")?.value || null;

  const plans = [];
  for (const rc of pricing?.rateCards || []) {
    for (const item of rc.rateCard || []) {
      plans.push({
        dimensionKey: item.dimensionKey,
        displayName: item.displayName || item.dimensionKey,
        description: item.description || null,
        unit: item.unit || null,
        price: item.price || null,
        currencyCode: pricing.currencyCode || null,
        selector: rc.selector || null,
        constraints: rc.constraints || null
      });
    }
  }

  const fulfillment = (result.fulfillmentOptions || []).map(x => {
    const ami = x?.amazonMachineImageFulfillmentOption;
    if (!ami) return null;
    return {
      type: ami.fulfillmentOptionType || null,
      displayName: ami.fulfillmentOptionDisplayName || ami.fulfillmentOptionName || null,
      version: ami.fulfillmentOptionVersion || null,
      operatingSystems: ami.operatingSystems || [],
      recommendedInstanceType: ami.recommendation?.instanceType || null,
      releaseNotes: ami.releaseNotes || null,
      usageInstructions: ami.usageInstructions || null
    };
  }).filter(Boolean);

  const availableOffers = [];
  const seenOffers = new Set();
  for (const option of result.purchaseOptions || []) {
    for (const entity of option.associatedEntities || []) {
      const candidate = entity?.offer;
      if (!candidate?.offerId || seenOffers.has(candidate.offerId)) continue;
      seenOffers.add(candidate.offerId);
      availableOffers.push({
        offerId: candidate.offerId,
        offerName: candidate.offerName || option.purchaseOptionName || candidate.offerId,
        purchaseOptionName: option.purchaseOptionName || null,
        purchaseOptionType: option.purchaseOptionType || null,
        seller: candidate.sellerOfRecord || option.sellerOfRecord || null,
        badges: option.badges || [],
        availableFromTime: option.availableFromTime || null,
        expirationTime: option.expirationTime || null
      });
    }
  }

  return {
    productId: result.productId,
    offerId: result.selectedOfferId || offer.offerId || null,
    agreementProposalId: offer.agreementProposalId || null,
    seller: offer.sellerOfRecord || null,
    pricingModel: offer.pricingModel || null,
    badges: offer.badges || [],
    availableOffers,
    plans,
    autoRenewAvailable: Boolean(renewal || (offer.badges || []).some(b => b?.badgeType === "AUTO_RENEW")),
    refundPolicy: support?.refundPolicy || null,
    legalDocuments: (legal?.documents || []).map(d => ({ type: d.type || null, url: d.url || null })),
    fulfillment
  };
}

function buildRequestedVodiaTerms(terms, { dimensionKey, quantity, selectorValue, autoRenew }) {
  const entries = offerTermEntries(terms);
  const pricingEntry = entries.find(x => x.kind === "configurableUpfrontPricingTerm");
  if (!pricingEntry) throw new Error("UNSUPPORTED_OFFER: configurable upfront pricing term was not found.");

  let selectedRateCard = null;
  let selectedDimension = null;
  for (const rc of pricingEntry.value.rateCards || []) {
    const selector = rc?.selector?.value;
    if (selectorValue && selector !== selectorValue) continue;
    const match = (rc.rateCard || []).find(d => d.dimensionKey === dimensionKey);
    if (match) {
      selectedRateCard = rc;
      selectedDimension = match;
      break;
    }
  }
  if (!selectedDimension || !selectedRateCard) {
    throw new Error(`INVALID_PLAN: dimension ${dimensionKey} is not available for selector ${selectorValue || "default"}.`);
  }

  const requested = [];
  for (const { kind, value } of entries) {
    if (kind === "configurableUpfrontPricingTerm") {
      requested.push({
        id: value.id,
        configuration: {
          configurableUpfrontPricingTermConfiguration: {
            selectorValue: selectedRateCard.selector?.value,
            dimensions: [{ dimensionKey, dimensionValue: quantity }]
          }
        }
      });
    } else if (kind === "renewalTerm") {
      requested.push({
        id: value.id,
        configuration: { renewalTermConfiguration: { enableAutoRenew: Boolean(autoRenew) } }
      });
    } else if (kind === "variablePaymentTerm") {
      throw new Error("UNSUPPORTED_OFFER: variable payment terms require an explicit approval strategy.");
    } else {
      requested.push({ id: value.id });
    }
  }

  return {
    requestedTerms: requested,
    selectedPlan: {
      dimensionKey,
      displayName: selectedDimension.displayName || dimensionKey,
      description: selectedDimension.description || null,
      unit: selectedDimension.unit || null,
      unitPrice: selectedDimension.price || null,
      currencyCode: pricingEntry.value.currencyCode || null,
      quantity,
      selectorValue: selectedRateCard.selector?.value || null,
      autoRenew: Boolean(autoRenew)
    }
  };
}

function cleanExpiredMarketplaceQuotes() {
  const now = Date.now();
  for (const [id, quote] of marketplacePurchaseQuotes.entries()) {
    if (quote.expiresAt <= now) marketplacePurchaseQuotes.delete(id);
  }
}

async function prepareVodiaMarketplacePurchase(roleArn, externalId, input, customerContext = null) {
  const connection = { roleArn, externalId };
  const result = await getMarketplaceOffer(connection.roleArn, connection.externalId, input.productId, input.offerId);
  const view = normalizeVodiaMarketplaceOffer(result);
  if (!view.agreementProposalId) throw new Error("OFFER_PROPOSAL_ID_MISSING: Marketplace offer did not return an agreementProposalId.");

  const built = buildRequestedVodiaTerms(result.terms, input);
  const client = agreementClient(connection.roleArn, connection.externalId);
  const quote = await client.send(new CreateAgreementRequestCommand({
    clientToken: randomUUID(),
    intent: "NEW",
    agreementProposalIdentifier: view.agreementProposalId,
    requestedTerms: built.requestedTerms,
    taxConfiguration: { taxEstimation: "ENABLED" }
  }));

  if (!quote.agreementRequestId) throw new Error("QUOTE_UNVERIFIED: AWS returned no agreementRequestId.");

  cleanExpiredMarketplaceQuotes();
  const expiresAt = Date.now() + AWS_MARKETPLACE_QUOTE_TTL_MS;
  const charge = quote.chargeSummary || {};
  const amount = charge.newAgreementValueAfterTax || charge.newAgreementValue || built.selectedPlan.unitPrice || "AWS-calculated";
  const currency = charge.currencyCode || built.selectedPlan.currencyCode || "USD";
  const confirmation = `ACCEPT VODIA ${built.selectedPlan.displayName} FOR ${currency} ${amount}`;

  marketplacePurchaseQuotes.set(quote.agreementRequestId, {
    agreementRequestId: quote.agreementRequestId,
    roleArn: connection.roleArn,
    externalId: connection.externalId,
    productId: input.productId,
    offerId: view.offerId,
    customerId: customerContext?.customerId || null,
    preparedBy: customerContext?.subject || null,
    selectedPlan: built.selectedPlan,
    confirmation,
    createdAt: Date.now(),
    expiresAt
  });

  return {
    agreementRequestId: quote.agreementRequestId,
    expiresAt: new Date(expiresAt).toISOString(),
    confirmation,
    product: view,
    selectedPlan: built.selectedPlan,
    chargeSummary: charge,
    changesMade: false
  };
}

async function acceptVodiaMarketplacePurchase(agreementRequestId, confirmation, extra) {
  cleanExpiredMarketplaceQuotes();
  const pending = marketplacePurchaseQuotes.get(agreementRequestId);
  if (!pending) throw new Error("QUOTE_NOT_FOUND_OR_EXPIRED: create a new Marketplace purchase quote.");
  if (confirmation !== pending.confirmation) {
    throw new Error(`CONFIRMATION_MISMATCH: exact confirmation required: ${pending.confirmation}`);
  }
  let commercialAccess = null;
  if (pending.customerId) {
    commercialAccess = requireCustomerAccess(extra, pending.customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
  } else if (REQUIRE_MSP_CUSTOMER_CONTEXT) {
    throw new Error("CUSTOMER_CONTEXT_REQUIRED: quote is not bound to an MSP customer.");
  }

  const client = agreementClient(pending.roleArn, pending.externalId);
  const out = await client.send(new AcceptAgreementRequestCommand({ agreementRequestId }));
  if (!out.agreementId) throw new Error("AGREEMENT_ACCEPT_UNVERIFIED: AWS returned no agreementId.");

  marketplacePurchaseQuotes.delete(agreementRequestId);
  let audit = null;
  let auditError = null;
  if (pending.customerId) {
    try {
      audit = recordCommercialAudit(extra, {
        customerId: pending.customerId,
        action: "AWS_MARKETPLACE_ACCEPT_AGREEMENT",
        resource: out.agreementId,
        details: {
          productId: pending.productId,
          offerId: pending.offerId,
          plan: pending.selectedPlan?.displayName || pending.selectedPlan?.dimensionKey || null,
          agreementRequestId
        }
      });
    } catch (error) {
      // Never report the AWS purchase itself as failed merely because local audit persistence failed.
      auditError = String(error?.message || error);
    }
  }
  let subscriptionActive = false;
  try {
    const subscription = await checkSubscription(pending.roleArn, pending.externalId, pending.productId);
    subscriptionActive = Boolean(subscription.active);
  } catch {
    // Agreement acceptance succeeded. Subscription propagation can be checked separately.
  }
  return {
    agreementId: out.agreementId,
    productId: pending.productId,
    offerId: pending.offerId,
    customerId: pending.customerId || null,
    acceptedBy: commercialAccess?.identity?.subject || null,
    selectedPlan: pending.selectedPlan,
    subscriptionActive,
    audit,
    auditError,
    changesMade: true
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
  const preferredInstanceTypes = [
    "t3.micro",
    "t3.small",
    "t3.medium",
    "t3.large",
    "c7i-flex.large",
    "m7i-flex.large"
  ];
  const freePlanEligible = new Set(["t3.micro", "t3.small", "c7i-flex.large", "m7i-flex.large"]);
  let instanceTypes = [];
  let instanceTypesWarning = null;
  try {
    const types = await client.send(new DescribeInstanceTypesCommand({
      Filters: [{ Name: "instance-type", Values: preferredInstanceTypes }]
    }));
    const order = new Map(preferredInstanceTypes.map((name, index) => [name, index]));
    instanceTypes = (types.InstanceTypes || [])
      .filter(t => (t.ProcessorInfo?.SupportedArchitectures || []).includes("x86_64"))
      .map(t => ({
        instanceType: t.InstanceType,
        vcpus: t.VCpuInfo?.DefaultVCpus || null,
        memoryMiB: t.MemoryInfo?.SizeInMiB || null,
        currentGeneration: Boolean(t.CurrentGeneration),
        freePlanEligible: freePlanEligible.has(t.InstanceType),
        recommended: t.InstanceType === "t3.medium"
      }))
      .sort((a, b) => (order.get(a.instanceType) ?? 999) - (order.get(b.instanceType) ?? 999));
  } catch (error) {
    instanceTypesWarning = `Instance-type discovery failed: ${error?.message || String(error)}`;
  }
  return {
    region,
    instanceTypes,
    instanceTypesWarning,
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
    TagSpecifications: [
      { ResourceType: "instance", Tags: tags },
      { ResourceType: "volume", Tags: tags }
    ]
  };

  if (input.iamInstanceProfileName) params.IamInstanceProfile = { Name: input.iamInstanceProfileName };
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

function deploymentLockKey(plan) {
  return [
    plan.customerId || plan.roleArn,
    plan.region,
    String(plan.name || "").trim().toLowerCase(),
    plan.productId
  ].join("|");
}

async function findExistingManagedInstance(client, name, productId) {
  const out = await client.send(new DescribeInstancesCommand({
    Filters: [
      { Name: "tag:ManagedBy", Values: ["VodiaMCP"] },
      { Name: "tag:Name", Values: [name] },
      { Name: "tag:VodiaMarketplaceProductId", Values: [productId] },
      { Name: "instance-state-name", Values: ["pending","running","stopping","stopped"] }
    ]
  }));
  const instances = (out.Reservations || []).flatMap(r => r.Instances || []);
  instances.sort((a,b) => new Date(b.LaunchTime || 0) - new Date(a.LaunchTime || 0));
  return instances[0] || null;
}

function duplicateDeploymentError(instance, region, name) {
  const id = instance?.InstanceId || "unknown";
  const state = instance?.State?.Name || "unknown";
  return new Error(
    `DUPLICATE_DEPLOYMENT_BLOCKED: VodiaMCP already has PBX "${name}" in ${region} (${id}, state=${state}). Use the existing instance, rename the new PBX, or explicitly remove the old deployment first.`
  );
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId }, extra) => {
      scopedAudit("aws_check_customer_connection", { customerId: customerId || null, roleArn });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const identity = await getCustomerIdentity(c.roleArn, c.externalId);
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId }, extra) => {
      scopedAudit("aws_marketplace_search_vodia", { customerId: customerId || null, roleArn });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const listings = await searchVodiaListings(c.roleArn, c.externalId);
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        offerId: z.string().optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, productId, offerId }, extra) => {
      scopedAudit("aws_marketplace_get_offer", { customerId: customerId || null, roleArn, productId, offerId: offerId || null });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const result = await getMarketplaceOffer(c.roleArn, c.externalId, productId, offerId);
        return scopedSuccess({ ...result, changesMade: false }, { operation: "AWS_MARKETPLACE_GET_OFFER", readOnly: true }, "Marketplace purchase options and terms loaded; nothing was accepted.");
      } catch (error) {
        return failure(error, "AWS Marketplace offer discovery");
      }
    }
  );


  server.registerTool(
    "aws_marketplace_present_vodia_offer",
    {
      title: "Present Vodia AWS Marketplace offer",
      description: "Returns a customer-facing summary of the Vodia Marketplace offer: plans, current AWS Marketplace prices, seller, renewal availability, refund policy, legal documents, and AMI details. Read-only and suitable for showing directly in chat before purchase.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        offerId: z.string().optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, productId, offerId }, extra) => {
      scopedAudit("aws_marketplace_present_vodia_offer", { customerId: customerId || null, roleArn, productId, offerId: offerId || null });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const raw = await getMarketplaceOffer(c.roleArn, c.externalId, productId, offerId);
        const offer = normalizeVodiaMarketplaceOffer(raw);
        return scopedSuccess({ offer, changesMade: false }, { operation: "AWS_MARKETPLACE_PRESENT_VODIA_OFFER", readOnly: true }, "Vodia Marketplace plans and terms are ready to present to the customer.");
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia offer presentation");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_prepare_vodia_purchase",
    {
      title: "Prepare Vodia Marketplace purchase",
      description: "Creates an AWS Marketplace agreement request that acts as a quote. It validates the selected Vodia plan against the live offer, asks AWS to calculate charges and taxes, and returns the exact terms plus a confirmation string. It does not accept the agreement or create a subscription.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        offerId: z.string().optional(),
        dimensionKey: z.string().min(1),
        quantity: z.number().int().min(1).default(1),
        selectorValue: z.string().optional(),
        autoRenew: z.boolean()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
    },
    async (input, extra) => {
      scopedAudit("aws_marketplace_prepare_vodia_purchase", {
        customerId: input.customerId || null,
        roleArn: input.roleArn,
        productId: input.productId,
        offerId: input.offerId || null,
        dimensionKey: input.dimensionKey,
        quantity: input.quantity,
        autoRenew: input.autoRenew
      });
      try {
        const c = resolveToolConnection(input, extra, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
        const result = await prepareVodiaMarketplacePurchase(c.roleArn, c.externalId, input, {
          customerId: c.customerId,
          subject: c.access?.identity?.subject || null
        });
        return scopedSuccess(result, { operation: "AWS_MARKETPLACE_PREPARE_VODIA_PURCHASE", readOnly: false }, "AWS Marketplace quote created. No agreement has been accepted. Present the quote and terms to the customer and require explicit approval.");
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia purchase preparation");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_accept_vodia_purchase",
    {
      title: "Accept Vodia Marketplace purchase",
      description: "Financially consequential action. Accepts a previously prepared AWS Marketplace agreement request only when the exact confirmation string from the quote is supplied. This can create a billable Marketplace agreement.",
      inputSchema: {
        agreementRequestId: z.string().min(3),
        confirmation: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true }
    },
    async ({ agreementRequestId, confirmation }, extra) => {
      scopedAudit("aws_marketplace_accept_vodia_purchase", { agreementRequestId });
      try {
        const result = await acceptVodiaMarketplacePurchase(agreementRequestId, confirmation, extra);
        return scopedSuccess(result, { operation: "AWS_MARKETPLACE_ACCEPT_VODIA_PURCHASE", readOnly: false }, "Vodia AWS Marketplace agreement accepted. Charges may now apply according to the accepted quote.");
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia purchase acceptance");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_check_subscription",
    {
      title: "Check AWS Marketplace subscription",
      description: "Checks for an ACTIVE PurchaseAgreement for the specified Marketplace product in the customer's account. Read-only.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, productId }, extra) => {
      scopedAudit("aws_marketplace_check_subscription", { customerId: customerId || null, roleArn, productId });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const result = await checkSubscription(c.roleArn, c.externalId, productId);
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional()
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId }, extra) => {
      scopedAudit("aws_list_deployment_regions", { customerId: customerId || null, roleArn });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const client = ec2Client(c.roleArn, c.externalId, AWS_DISCOVERY_REGION);
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, region }, extra) => {
      scopedAudit("aws_discover_deployment_network", { customerId: customerId || null, roleArn, region });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const result = await describeNetwork(c.roleArn, c.externalId, region);
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3),
        productCode: z.string().optional(),
        amiId: z.string().optional(),
        region: z.string().min(3),
        subnetId: z.string().min(3),
        securityGroupIds: z.array(z.string()).min(1),
        instanceType: z.string().min(3),
        iamInstanceProfileName: z.string().min(1).optional(),
        keyName: z.string().optional(),
        storageGiB: z.number().int().min(8).max(16384).optional(),
        associatePublicIp: z.boolean().default(true),
        name: z.string().min(1).max(128)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async (input, extra) => {
      const resolvedConnection = resolveToolConnection(input, extra, ["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR"]);
      input = { ...input, customerId: resolvedConnection.customerId, roleArn: resolvedConnection.roleArn, externalId: resolvedConnection.externalId };
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
          throw new Error("SUBSCRIPTION_REQUIRED: no ACTIVE AWS Marketplace PurchaseAgreement was found. Present the live offer, prepare an AWS quote, obtain explicit customer approval, and accept the quote before planning deployment.");
        }

        const client = ec2Client(input.roleArn, input.externalId, input.region);
        const existing = await findExistingManagedInstance(client, input.name, input.productId);
        if (existing) throw duplicateDeploymentError(existing, input.region, input.name);

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
          customerId: input.customerId || null,
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
    async ({ planId, confirmation }, extra) => {
      scopedAudit("aws_marketplace_apply_vodia_pbx_deployment", { planId });
      try {
        cleanExpiredPlans();
        const plan = deploymentPlans.get(planId);
        if (!plan) throw new Error("PLAN_NOT_FOUND_OR_EXPIRED: create a new deployment plan.");
        if (confirmation !== plan.confirmation) throw new Error(`CONFIRMATION_MISMATCH: exact confirmation required: ${plan.confirmation}`);
        if (plan.customerId) {
          requireCustomerAccess(extra, plan.customerId, ["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR"]);
        } else if (REQUIRE_MSP_CUSTOMER_CONTEXT) {
          throw new Error("CUSTOMER_CONTEXT_REQUIRED: deployment plan is not bound to an MSP customer.");
        }

        const subscription = await checkSubscription(plan.roleArn, plan.externalId, plan.productId);
        if (!subscription.active) throw new Error("SUBSCRIPTION_NO_LONGER_ACTIVE: deployment aborted.");

        const client = ec2Client(plan.roleArn, plan.externalId, plan.region);
        const lockKey = deploymentLockKey(plan);
        if (deploymentLocks.has(lockKey)) {
          throw new Error("DEPLOYMENT_ALREADY_IN_PROGRESS: a launch for this PBX is already being processed.");
        }

        deploymentLocks.add(lockKey);
        try {
          const existing = await findExistingManagedInstance(client, plan.name, plan.productId);
          if (existing) throw duplicateDeploymentError(existing, plan.region, plan.name);

          const clientToken = "vodia-" + planId.replace(/-/g, "");
          const out = await client.send(new RunInstancesCommand({ ...plan.params, ClientToken: clientToken }));
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
            duplicateProtection: true,
            changesMade: true
          }, { operation: "AWS_MARKETPLACE_APPLY_VODIA_PBX_DEPLOYMENT", readOnly: false }, `Vodia PBX EC2 instance ${instance.InstanceId} launched in ${plan.region}.`);
        } finally {
          deploymentLocks.delete(lockKey);
        }
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
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3),
        instanceId: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, region, instanceId }, extra) => {
      scopedAudit("aws_get_vodia_pbx_deployment_status", { customerId: customerId || null, roleArn, region, instanceId });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const client = ec2Client(c.roleArn, c.externalId, region);
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
