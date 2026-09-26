import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, renameSync } from "node:fs";
import { dirname } from "node:path";
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
  DescribeInstanceStatusCommand,
  DescribeInstanceAttributeCommand,
  TerminateInstancesCommand,
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

const VODIA_MARKETPLACE_DEPLOYMENT_LEDGER = process.env.VODIA_MCP_MARKETPLACE_DEPLOYMENT_LEDGER || "/var/lib/vodia-mcp/aws-marketplace-deployments.json";
const AWS_DEPLOY_PLAN_TTL_MS = Number(process.env.VODIA_MCP_AWS_DEPLOY_PLAN_TTL_MS || 15 * 60 * 1000);
const AWS_DISCOVERY_REGION = process.env.VODIA_MCP_AWS_MARKETPLACE_DISCOVERY_REGION || "us-east-1";
const AWS_CONNECT_UI_URI = "ui://vodia/aws-connect/mcp-app.html";
const AWS_CONNECT_UI_HTML = process.env.VODIA_MCP_AWS_CONNECT_UI_HTML || "/opt/vodia-mcp/ui/aws-connect-app.html";
const REQUIRE_MSP_CUSTOMER_CONTEXT = String(process.env.VODIA_MSP_REQUIRE_CUSTOMER_CONTEXT || "").toLowerCase() === "true";
const deploymentPlans = new Map();
const deploymentLocks = new Set();
const terminationPlans = new Map();
const VODIA_TERMINATION_PLAN_TTL_MS = Number(process.env.VODIA_MCP_AWS_TERMINATION_PLAN_TTL_MS || 10 * 60 * 1000);
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
  if (input.agreementId) {
    tags.push({ Key: "VodiaMarketplaceAgreementId", Value: String(input.agreementId).slice(0, 255) });
  }
  if (input.customerId) {
    tags.push({ Key: "VodiaMspCustomerId", Value: String(input.customerId).slice(0, 255) });
  }
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

const VODIA_EC2_LAUNCH_VERIFY_V68 = true;
const VODIA_MARKETPLACE_MONITOR_V69 = true;
const EC2_INSTANCE_ID_PATTERN = /^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/;

const waitForEc2Visibility = (ms) => new Promise(resolve => setTimeout(resolve, ms));

function requiredInstanceTag(instance, key) {
  return (instance?.Tags || []).find(t => t?.Key === key)?.Value || null;
}

async function verifyLaunchedInstance(client, instanceId, expected) {
  if (!EC2_INSTANCE_ID_PATTERN.test(String(instanceId || ""))) {
    throw new Error("EC2_INSTANCE_ID_INVALID: AWS returned an invalid instance ID; deployment result was not accepted.");
  }

  let lastError=null;
  for (let attempt=0;attempt<8;attempt++) {
    if (attempt>0) await waitForEc2Visibility(1000);
    try {
      const out=await client.send(new DescribeInstancesCommand({ InstanceIds: [instanceId] }));
      const instance=(out.Reservations || []).flatMap(r => r.Instances || [])[0];
      if (!instance) throw new Error("EC2_LAUNCH_NOT_VISIBLE: DescribeInstances returned no instance.");
      if (instance.InstanceId !== instanceId) {
        throw new Error("EC2_INSTANCE_ID_MISMATCH: RunInstances and DescribeInstances returned different IDs.");
      }
      const managedBy=requiredInstanceTag(instance,"ManagedBy");
      const name=requiredInstanceTag(instance,"Name");
      const productId=requiredInstanceTag(instance,"VodiaMarketplaceProductId");
      const agreementId=requiredInstanceTag(instance,"VodiaMarketplaceAgreementId");
      const customerId=requiredInstanceTag(instance,"VodiaMspCustomerId");
      if (managedBy !== "VodiaMCP") throw new Error("EC2_TAG_VERIFICATION_FAILED: ManagedBy tag mismatch.");
      if (name !== expected.name) throw new Error("EC2_TAG_VERIFICATION_FAILED: PBX Name tag mismatch.");
      if (productId !== expected.productId) throw new Error("EC2_TAG_VERIFICATION_FAILED: Marketplace product tag mismatch.");
      if (expected.agreementId && agreementId !== expected.agreementId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: Marketplace agreement tag mismatch.");
      }
      if (expected.customerId && customerId !== expected.customerId) {
        throw new Error("EC2_TAG_VERIFICATION_FAILED: MSP customer tag mismatch.");
      }
      return instance;
    } catch (error) {
      lastError=error;
      const message=String(error?.message || error);
      const retryable=/InvalidInstanceID\.NotFound|not visible|returned no instance/i.test(message);
      if (!retryable) throw error;
    }
  }
  throw new Error("EC2_LAUNCH_VERIFICATION_TIMEOUT: instance was launched but AWS did not make it visible for verification: "+String(lastError?.message||lastError||"unknown"));
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
    plan.productId,
    plan.agreementId || "no-agreement"
  ].join("|");
}

async function findExistingManagedInstance(client, name, productId, customerId=null) {
  const out = await client.send(new DescribeInstancesCommand({
    Filters: [
      { Name: "tag:ManagedBy", Values: ["VodiaMCP"] },
      { Name: "tag:Name", Values: [name] },
      { Name: "tag:VodiaMarketplaceProductId", Values: [productId] },
      { Name: "instance-state-name", Values: ["pending","running","stopping","stopped"] }
    ]
  }));
  let instances = (out.Reservations || []).flatMap(r => r.Instances || []);
  if (customerId) {
    const exact=[];
    const legacy=[];
    for (const instance of instances) {
      const owner=(instance.Tags || []).find(t => t?.Key === "VodiaMspCustomerId")?.Value || null;
      if (owner === customerId) exact.push(instance);
      else if (!owner) legacy.push(instance);
    }
    instances=[...exact,...legacy];
  }
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


function instanceTagValue(instance, key) {
  return (instance?.Tags || []).find(t => t?.Key === key)?.Value || null;
}

const VODIA_AWS_INVENTORY_V71 = true;
const VODIA_AWS_PRODUCT_INVENTORY_V72 = true;
const VODIA_ACTIVE_INVENTORY_STATES = ["pending","running","stopping","stopped","shutting-down"];

function configuredMarketplaceProductCode(){
  return String(process.env.VODIA_AWS_MARKETPLACE_PRODUCT_CODE||"").trim();
}

function instanceMarketplaceProductCodes(instance){
  return (instance?.ProductCodes||[]).map(row=>row?.ProductCodeId).filter(Boolean);
}

function instanceHasConfiguredVodiaProductCode(instance){
  const code=configuredMarketplaceProductCode();
  return Boolean(code&&instanceMarketplaceProductCodes(instance).includes(code));
}

async function describeInstancesPaginated(client,filters){
  const instances=[];
  let nextToken;
  do{
    const out=await client.send(new DescribeInstancesCommand({Filters:filters,MaxResults:1000,NextToken:nextToken}));
    instances.push(...(out.Reservations||[]).flatMap(reservation=>reservation.Instances||[]));
    nextToken=out.NextToken;
  }while(nextToken);
  return instances;
}

function normalizeInventoryInstance(instance, region, duplicateCount=1) {
  const agreementId=instanceTagValue(instance,"VodiaMarketplaceAgreementId");
  const productCodes=instanceMarketplaceProductCodes(instance);
  const marketplaceProductCodeVerified=instanceHasConfiguredVodiaProductCode(instance);
  return {
    instanceId:instance.InstanceId || null,
    pbxName:instanceTagValue(instance,"Name") || "Vodia PBX",
    region,
    availabilityZone:instance.Placement?.AvailabilityZone || null,
    instanceState:instance.State?.Name || null,
    instanceType:instance.InstanceType || null,
    imageId:instance.ImageId || null,
    launchTime:instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : null,
    publicIpAddress:instance.PublicIpAddress || null,
    publicDnsName:instance.PublicDnsName || null,
    privateIpAddress:instance.PrivateIpAddress || null,
    privateDnsName:instance.PrivateDnsName || null,
    vpcId:instance.VpcId || null,
    subnetId:instance.SubnetId || null,
    securityGroupIds:(instance.SecurityGroups || []).map(group=>group.GroupId).filter(Boolean),
    managedBy:instanceTagValue(instance,"ManagedBy"),
    customerId:instanceTagValue(instance,"VodiaMspCustomerId"),
    productId:instanceTagValue(instance,"VodiaMarketplaceProductId"),
    productCodes,
    marketplaceProductCodeVerified,
    agreementId,
    duplicateAgreement:Boolean(agreementId && duplicateCount>1),
    duplicateCount:agreementId ? duplicateCount : 0,
    source:marketplaceProductCodeVerified?"ec2-marketplace-product-code":"ec2-vodia-tags"
  };
}

async function scanVodiaManagedInventory(roleArn, externalId, customerId, productId) {
  const discovery=ec2Client(roleArn,externalId,AWS_DISCOVERY_REGION);
  const regionsOut=await discovery.send(new DescribeRegionsCommand({AllRegions:false}));
  const regions=(regionsOut.Regions || []).map(row=>row.RegionName).filter(Boolean);
  const ledger=loadMarketplaceDeploymentLedger();
  const allowedLegacyIds=new Set(ledger.deployments.filter(row=>
    row?.instanceId && (!customerId || row.customerId===customerId)
  ).map(row=>row.instanceId));
  const checks=await Promise.allSettled(regions.map(async region=>{
    const client=ec2Client(roleArn,externalId,region);
    const stateFilter={Name:"instance-state-name",Values:VODIA_ACTIVE_INVENTORY_STATES};
    const productCode=configuredMarketplaceProductCode();
    const queries=[];
    if(productCode){
      queries.push(describeInstancesPaginated(client,[
        {Name:"product-code",Values:[productCode]},stateFilter
      ]));
    }
    const tagFilters=[{Name:"tag:ManagedBy",Values:["VodiaMCP"]},stateFilter];
    if(productId) tagFilters.push({Name:"tag:VodiaMarketplaceProductId",Values:[productId]});
    queries.push(describeInstancesPaginated(client,tagFilters));
    const sets=await Promise.all(queries);
    const unique=new Map();
    for(const instance of sets.flat()) if(instance?.InstanceId) unique.set(instance.InstanceId,instance);
    return [...unique.values()].map(instance=>({region,instance}));
  }));
  const regionErrors=[];
  const raw=[];
  checks.forEach((check,index)=>{
    if(check.status==="fulfilled") raw.push(...check.value);
    else regionErrors.push({region:regions[index],error:String(check.reason?.message||check.reason)});
  });
  const owned=raw.filter(({instance})=>{
    if(instanceHasConfiguredVodiaProductCode(instance)) return true;
    const taggedCustomer=instanceTagValue(instance,"VodiaMspCustomerId");
    if(!customerId) return true;
    return taggedCustomer===customerId || (!taggedCustomer && allowedLegacyIds.has(instance.InstanceId));
  });
  const agreementCounts=new Map();
  for(const {instance} of owned){
    const agreementId=instanceTagValue(instance,"VodiaMarketplaceAgreementId");
    if(agreementId) agreementCounts.set(agreementId,(agreementCounts.get(agreementId)||0)+1);
  }
  const priority={running:0,pending:1,stopping:2,"shutting-down":3,stopped:4};
  const instances=owned.map(({instance,region})=>{
    const agreementId=instanceTagValue(instance,"VodiaMarketplaceAgreementId");
    return normalizeInventoryInstance(instance,region,agreementCounts.get(agreementId)||1);
  }).sort((a,b)=>{
    const stateDiff=(priority[a.instanceState]??9)-(priority[b.instanceState]??9);
    return stateDiff || new Date(b.launchTime||0)-new Date(a.launchTime||0);
  });
  const duplicateAgreementIds=[...agreementCounts.entries()].filter(([,count])=>count>1).map(([id])=>id);
  return {
    instances,
    activeInstanceCount:instances.length,
    runningInstanceCount:instances.filter(row=>row.instanceState==="running").length,
    stoppedInstanceCount:instances.filter(row=>row.instanceState==="stopped").length,
    duplicateAgreementIds,
    duplicateInstanceCount:instances.filter(row=>row.duplicateAgreement).length,
    marketplaceProductCode:configuredMarketplaceProductCode()||null,
    regionsScanned:regions.length,
    regionErrors,
    checkedAt:new Date().toISOString()
  };
}

function agreementInventoryMatches(inventory, agreementId) {
  return (inventory?.instances || []).filter(row=>row.agreementId===agreementId);
}

function agreementInUseError(agreementId, matches) {
  const targets=matches.map(row=>`${row.instanceId} (${row.region}, ${row.instanceState})`).join(", ");
  return new Error(`MARKETPLACE_AGREEMENT_ALREADY_IN_USE: agreement ${agreementId} is attached to ${matches.length} active EC2 instance(s): ${targets}. Terminate the unwanted instance(s) and wait for AWS confirmation before reusing this subscription.`);
}

function loadMarketplaceDeploymentLedger() {
  try {
    const parsed = JSON.parse(readFileSync(VODIA_MARKETPLACE_DEPLOYMENT_LEDGER, "utf8"));
    if (!parsed || typeof parsed !== "object") return { version: 1, deployments: [] };
    if (!Array.isArray(parsed.deployments)) parsed.deployments = [];
    return { version: 1, deployments: parsed.deployments };
  } catch (error) {
    if (error?.code === "ENOENT") return { version: 1, deployments: [] };
    throw new Error("MARKETPLACE_DEPLOYMENT_LEDGER_READ_FAILED: " + (error?.message || String(error)));
  }
}

function saveMarketplaceDeploymentLedger(ledger) {
  mkdirSync(dirname(VODIA_MARKETPLACE_DEPLOYMENT_LEDGER), { recursive: true, mode: 0o700 });
  const tmp = VODIA_MARKETPLACE_DEPLOYMENT_LEDGER + ".tmp";
  writeFileSync(tmp, JSON.stringify({ version: 1, deployments: ledger.deployments || [] }, null, 2) + "\n", { mode: 0o600 });
  renameSync(tmp, VODIA_MARKETPLACE_DEPLOYMENT_LEDGER);
}

function upsertMarketplaceDeployment(record) {
  const ledger = loadMarketplaceDeploymentLedger();
  const now = new Date().toISOString();
  const key = record.instanceId
    ? (row => row.instanceId === record.instanceId)
    : (row => row.customerId === record.customerId && row.productId === record.productId && row.agreementId === record.agreementId);
  const index = ledger.deployments.findIndex(key);
  if (index >= 0) {
    ledger.deployments[index] = { ...ledger.deployments[index], ...record, updatedAt: now };
  } else {
    ledger.deployments.push({ ...record, createdAt: record.createdAt || now, updatedAt: now });
  }
  saveMarketplaceDeploymentLedger(ledger);
  return index >= 0 ? ledger.deployments[index] : ledger.deployments[ledger.deployments.length - 1];
}

function marketplaceUsageStatusForState(state) {
  const value = String(state || "").toLowerCase();
  if (["pending","running","stopping","shutting-down"].includes(value)) return "IN_USE";
  if (value === "stopped") return "INSTANCE_STOPPED";
  if (value === "terminated") return "INSTANCE_TERMINATED";
  return "RECONCILIATION_NEEDED";
}

function marketplaceUsageView(record, source) {
  if (!record) return { status: "AVAILABLE", source: source || "none" };
  if (record.agreementReleasedAt && String(record.instanceState || "").toLowerCase() === "terminated") {
    return {
      status: "AVAILABLE",
      source: "released-after-termination",
      releasedAt: record.agreementReleasedAt,
      previousDeployment: {
        pbxName: record.name || null,
        instanceId: record.instanceId || null,
        region: record.region || null,
        terminatedAt: record.agreementReleasedAt
      }
    };
  }
  return {
    status: marketplaceUsageStatusForState(record.instanceState),
    source: source || record.source || "ledger",
    pbxName: record.name || null,
    instanceId: record.instanceId || null,
    region: record.region || null,
    instanceState: record.instanceState || null,
    launchTime: record.launchTime || null,
    publicIpAddress: record.publicIpAddress || null,
    publicDnsName: record.publicDnsName || null,
    agreementId: record.agreementId || null
  };
}

async function refreshLedgerDeploymentStatus(roleArn, externalId, record) {
  if (!record?.region || !record?.instanceId) return marketplaceUsageView(record, "ledger");
  try {
    const client = ec2Client(roleArn, externalId, record.region);
    const out = await client.send(new DescribeInstancesCommand({ InstanceIds: [record.instanceId] }));
    const instance = out.Reservations?.[0]?.Instances?.[0];
    if (!instance) {
      const releasedAt = record.releaseAgreementOnTermination ? (record.agreementReleasedAt || new Date().toISOString()) : record.agreementReleasedAt;
      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", agreementReleasedAt: releasedAt || null, source: "ledger-reconciled" });
      return marketplaceUsageView(updated, "ledger-reconciled");
    }
    const updated = upsertMarketplaceDeployment({
      ...record,
      name: instanceTagValue(instance, "Name") || record.name || null,
      instanceState: instance.State?.Name || record.instanceState || null,
      agreementReleasedAt: (record.releaseAgreementOnTermination && instance.State?.Name === "terminated")
        ? (record.agreementReleasedAt || new Date().toISOString())
        : (record.agreementReleasedAt || null),
      publicIpAddress: instance.PublicIpAddress || null,
      publicDnsName: instance.PublicDnsName || null,
      launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : record.launchTime || null,
      source: "ledger-reconciled"
    });
    return marketplaceUsageView(updated, "ledger-reconciled");
  } catch (error) {
    const msg = String(error?.message || error);
    if (/InvalidInstanceID\.NotFound|does not exist/i.test(msg)) {
      const releasedAt = record.releaseAgreementOnTermination ? (record.agreementReleasedAt || new Date().toISOString()) : record.agreementReleasedAt;
      const updated = upsertMarketplaceDeployment({ ...record, instanceState: "terminated", agreementReleasedAt: releasedAt || null, source: "ledger-reconciled" });
      return marketplaceUsageView(updated, "ledger-reconciled");
    }
    return { ...marketplaceUsageView(record, "ledger"), status: "RECONCILIATION_NEEDED", reconciliationError: msg };
  }
}

async function discoverAgreementDeployment(roleArn, externalId, customerId, productId, agreementId) {
  const discovery = ec2Client(roleArn, externalId, AWS_DISCOVERY_REGION);
  const regionsOut = await discovery.send(new DescribeRegionsCommand({ AllRegions: false }));
  const regions = (regionsOut.Regions || []).map(r => r.RegionName).filter(Boolean);

  const checks = await Promise.allSettled(regions.map(async region => {
    const client = ec2Client(roleArn, externalId, region);
    const out = await client.send(new DescribeInstancesCommand({
      Filters: [
        { Name: "tag:ManagedBy", Values: ["VodiaMCP"] },
        { Name: "tag:VodiaMarketplaceProductId", Values: [productId] },
        { Name: "tag:VodiaMarketplaceAgreementId", Values: [agreementId] }
      ]
    }));
    const instances = (out.Reservations || []).flatMap(r => r.Instances || []);
    instances.sort((a,b) => new Date(b.LaunchTime || 0) - new Date(a.LaunchTime || 0));
    return { region, instance: instances[0] || null };
  }));

  const matches = checks
    .filter(x => x.status === "fulfilled" && x.value?.instance)
    .map(x => x.value)
    .sort((a,b) => new Date(b.instance.LaunchTime || 0) - new Date(a.instance.LaunchTime || 0));

  if (!matches.length) return null;
  const { region, instance } = matches[0];
  return upsertMarketplaceDeployment({
    customerId: customerId || null,
    productId,
    agreementId,
    instanceId: instance.InstanceId,
    name: instanceTagValue(instance, "Name") || null,
    region,
    instanceState: instance.State?.Name || null,
    publicIpAddress: instance.PublicIpAddress || null,
    publicDnsName: instance.PublicDnsName || null,
    launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : null,
    source: "ec2-reconciled"
  });
}

async function reconcileMarketplaceAgreementUsage(roleArn, externalId, customerId, productId, agreementId) {
  const ledger = loadMarketplaceDeploymentLedger();
  const rows = ledger.deployments
    .filter(row =>
      row?.agreementId === agreementId &&
      row?.productId === productId &&
      (!customerId || !row.customerId || row.customerId === customerId)
    )
    .sort((a,b) => new Date(b.launchTime || b.createdAt || 0) - new Date(a.launchTime || a.createdAt || 0));

  if (rows[0]) return refreshLedgerDeploymentStatus(roleArn, externalId, rows[0]);

  const discovered = await discoverAgreementDeployment(roleArn, externalId, customerId, productId, agreementId);
  return discovered ? marketplaceUsageView(discovered, "ec2-reconciled") : { status: "AVAILABLE", source: "ec2-scan" };
}

async function enrichMarketplaceSubscriptionUsage(roleArn, externalId, customerId, productId, subscription) {
  const inventory=await scanVodiaManagedInventory(roleArn,externalId,customerId,productId);
  const agreements = [];
  for (const agreement of subscription.agreements || []) {
    const agreementId = agreement?.agreementId;
    let deploymentUsage = { status: "RECONCILIATION_NEEDED", source: "invalid-agreement" };
    if (agreementId) {
      const matches=agreementInventoryMatches(inventory,agreementId);
      if(matches.length){
        const primary=matches[0];
        deploymentUsage={
          status:primary.instanceState==="stopped"?"INSTANCE_STOPPED":"IN_USE",
          source:"ec2-cross-region-inventory",
          pbxName:primary.pbxName,
          instanceId:primary.instanceId,
          region:primary.region,
          instanceState:primary.instanceState,
          launchTime:primary.launchTime,
          publicIpAddress:primary.publicIpAddress,
          publicDnsName:primary.publicDnsName,
          agreementId,
          instanceCount:matches.length,
          duplicateAgreement:matches.length>1,
          instances:matches
        };
      }else{
        deploymentUsage = await reconcileMarketplaceAgreementUsage(roleArn, externalId, customerId, productId, agreementId);
      }
    }
    agreements.push({ ...agreement, deploymentUsage });
  }
  const availableAgreementCount = agreements.filter(a => a.deploymentUsage?.status === "AVAILABLE").length;
  const inUseAgreementCount = agreements.length - availableAgreementCount;
  return { ...subscription, agreements, availableAgreementCount, inUseAgreementCount, inventory };
}


const VODIA_TERMINATE_RELEASE_V70 = true;

function cleanExpiredTerminationPlans() {
  const now=Date.now();
  for (const [id,plan] of terminationPlans.entries()) {
    if (plan.expiresAt <= now) terminationPlans.delete(id);
  }
}

function terminationLedgerRecord(instanceId, customerId) {
  const ledger=loadMarketplaceDeploymentLedger();
  return ledger.deployments.find(row =>
    row?.instanceId === instanceId &&
    (!customerId || !row.customerId || row.customerId === customerId)
  ) || null;
}

function validateTerminationTarget(instance, ledgerRecord, customerId) {
  if (!instance?.InstanceId) throw new Error("INSTANCE_NOT_FOUND: deployment instance is unavailable.");
  const managedBy=requiredInstanceTag(instance,"ManagedBy");
  const taggedCustomer=requiredInstanceTag(instance,"VodiaMspCustomerId");
  const productId=requiredInstanceTag(instance,"VodiaMarketplaceProductId") || ledgerRecord?.productId || null;
  const agreementId=requiredInstanceTag(instance,"VodiaMarketplaceAgreementId") || ledgerRecord?.agreementId || null;
  const marketplaceProductCodeVerified=instanceHasConfiguredVodiaProductCode(instance);
  if (managedBy !== "VodiaMCP" && !marketplaceProductCodeVerified) {
    throw new Error("TERMINATION_NOT_VODIA_MANAGED: instance is neither ManagedBy=VodiaMCP nor verified against the configured Vodia Marketplace product code.");
  }
  if (!marketplaceProductCodeVerified && (!productId || !agreementId)) {
    throw new Error("TERMINATION_MARKETPLACE_BINDING_MISSING: product/agreement binding was not verified.");
  }
  if (!marketplaceProductCodeVerified && customerId && taggedCustomer && taggedCustomer !== customerId) {
    throw new Error("DEPLOYMENT_CUSTOMER_MISMATCH: instance belongs to another MSP customer.");
  }
  if (!marketplaceProductCodeVerified && customerId && !taggedCustomer && !ledgerRecord) {
    throw new Error("DEPLOYMENT_NOT_IN_CUSTOMER_LEDGER: legacy instance is not assigned to the selected customer.");
  }
  return {
    name: requiredInstanceTag(instance,"Name") || ledgerRecord?.name || "Vodia-PBX",
    productId,
    agreementId,
    marketplaceProductCode:configuredMarketplaceProductCode()||null,
    marketplaceProductCodeVerified,
    customerId: customerId || ledgerRecord?.customerId || taggedCustomer || null
  };
}

function terminationVolumeImpact(instance) {
  return (instance?.BlockDeviceMappings || []).map(mapping => ({
    deviceName: mapping.DeviceName || null,
    volumeId: mapping.Ebs?.VolumeId || null,
    deleteOnTermination: Boolean(mapping.Ebs?.DeleteOnTermination),
    status: mapping.Ebs?.Status || null
  }));
}

async function verifyTerminatePermission(client, instanceId) {
  try {
    await client.send(new TerminateInstancesCommand({ InstanceIds:[instanceId], DryRun:true }));
    throw new Error("TERMINATION_DRY_RUN_UNEXPECTED_SUCCESS: AWS did not return DryRunOperation.");
  } catch (error) {
    const code=String(error?.name || error?.Code || error?.code || "");
    const message=String(error?.message || error);
    if (code === "DryRunOperation" || /DryRunOperation/i.test(message)) return true;
    if (code === "UnauthorizedOperation" || /not authorized|UnauthorizedOperation/i.test(message)) {
      throw new Error("TERMINATE_PERMISSION_REQUIRED: VodiaMCPDeploymentRole needs ec2:TerminateInstances. Update the customer CloudFormation stack or role policy, then retry.");
    }
    throw error;
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
        const enriched = await enrichMarketplaceSubscriptionUsage(
          c.roleArn,
          c.externalId,
          c.customerId || null,
          productId,
          result.active ? result : { ...result, agreements: [] }
        );
        const summary = enriched.active
          ? ("Active Marketplace agreement(s) found: " + enriched.availableAgreementCount + " available, " + enriched.inUseAgreementCount + " already assigned.")
          : "No active Marketplace agreement found.";
        return scopedSuccess({ ...enriched, changesMade: false }, { operation: "AWS_MARKETPLACE_CHECK_SUBSCRIPTION", readOnly: true }, summary);
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
        agreementId: z.string().min(3).optional(),
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

        const selectedAgreement = input.agreementId
          ? subscription.agreements.find(a => a?.agreementId === input.agreementId)
          : subscription.agreements[0];
        if (!selectedAgreement) {
          throw new Error("AGREEMENT_NOT_ACTIVE: the selected AWS Marketplace agreement is no longer active. Refresh subscriptions and choose an active agreement.");
        }
        input = { ...input, agreementId: selectedAgreement.agreementId };

        const planningInventory=await scanVodiaManagedInventory(
          input.roleArn,input.externalId,input.customerId||null,input.productId
        );
        const planningMatches=agreementInventoryMatches(planningInventory,selectedAgreement.agreementId);
        if(planningMatches.length) throw agreementInUseError(selectedAgreement.agreementId,planningMatches);
        const selectedUsage = await reconcileMarketplaceAgreementUsage(
          input.roleArn,input.externalId,input.customerId||null,input.productId,selectedAgreement.agreementId
        );
        if (selectedUsage.status !== "AVAILABLE") {
          throw new Error(
            "MARKETPLACE_AGREEMENT_ALREADY_ASSIGNED: agreement " + selectedAgreement.agreementId +
            " is " + selectedUsage.status +
            (selectedUsage.instanceId ? (" on instance " + selectedUsage.instanceId) : "") +
            (selectedUsage.pbxName ? (" (" + selectedUsage.pbxName + ")") : "") +
            ". Create or select another AVAILABLE Marketplace agreement."
          );
        }

        const client = ec2Client(input.roleArn, input.externalId, input.region);
        const existing = await findExistingManagedInstance(client, input.name, input.productId, input.customerId || null);
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
          agreementId: selectedAgreement.agreementId,
          agreementSummary: selectedAgreement,
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
          selectedAgreement: {
            agreementId: selectedAgreement.agreementId || null,
            status: selectedAgreement.status || "ACTIVE",
            startTime: selectedAgreement.startTime || null,
            endTime: selectedAgreement.endTime || null,
            acceptanceTime: selectedAgreement.acceptanceTime || null
          },
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
        if (plan.agreementId && !subscription.agreements.some(a => a?.agreementId === plan.agreementId)) {
          throw new Error("SELECTED_AGREEMENT_NO_LONGER_ACTIVE: refresh Marketplace subscriptions and create a new deployment plan.");
        }

        const client = ec2Client(plan.roleArn, plan.externalId, plan.region);
        const lockKey = deploymentLockKey(plan);
        if (deploymentLocks.has(lockKey)) {
          throw new Error("DEPLOYMENT_ALREADY_IN_PROGRESS: a launch for this PBX is already being processed.");
        }

        deploymentLocks.add(lockKey);
        try {
          const launchInventory=await scanVodiaManagedInventory(
            plan.roleArn,plan.externalId,plan.customerId||null,plan.productId
          );
          const launchMatches=agreementInventoryMatches(launchInventory,plan.agreementId);
          if(launchMatches.length) throw agreementInUseError(plan.agreementId,launchMatches);
          const existing = await findExistingManagedInstance(client, plan.name, plan.productId, plan.customerId || null);
          if (existing) throw duplicateDeploymentError(existing, plan.region, plan.name);

          const clientToken = "vodia-" + planId.replace(/-/g, "");
          const out = await client.send(new RunInstancesCommand({ ...plan.params, ClientToken: clientToken }));
          const launchedInstance = (out.Instances || [])[0];
          const launchedInstanceId = String(launchedInstance?.InstanceId || "");
          if (!launchedInstanceId) throw new Error("EC2_LAUNCH_UNVERIFIED: RunInstances returned no instance ID.");

          const instance = await verifyLaunchedInstance(client, launchedInstanceId, {
            name: plan.name,
            productId: plan.productId,
            agreementId: plan.agreementId || null,
            customerId: plan.customerId || null
          });

          upsertMarketplaceDeployment({
            customerId: plan.customerId || null,
            productId: plan.productId,
            agreementId: plan.agreementId || null,
            instanceId: instance.InstanceId,
            name: plan.name,
            region: plan.region,
            instanceState: instance.State?.Name || "pending",
            publicIpAddress: instance.PublicIpAddress || null,
            publicDnsName: instance.PublicDnsName || null,
            launchTime: instance.LaunchTime ? new Date(instance.LaunchTime).toISOString() : new Date().toISOString(),
            source: "mcp-launch-verified"
          });

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
            agreementId: plan.agreementId || null,
            marketplaceSubscriptionVerifiedBeforeLaunch: true,
            duplicateProtection: true,
            launchVerifiedByDescribeInstances: true,
            instanceIdSource: "DescribeInstances.InstanceId",
            customerTagVerified: Boolean(plan.customerId),
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
    "aws_marketplace_plan_terminate_vodia_pbx",
    {
      title: "Plan Vodia PBX termination",
      description: "Read-only, customer-scoped termination preflight. Verifies Vodia ownership, Marketplace binding, termination protection, EBS volume impact, and ec2:TerminateInstances permission using AWS DryRun. Returns an exact approval phrase; it does not terminate anything.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3),
        instanceId: z.string().regex(/^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async (input, extra) => {
      scopedAudit("aws_marketplace_plan_terminate_vodia_pbx", { customerId:input.customerId||null, region:input.region, instanceId:input.instanceId });
      try {
        cleanExpiredTerminationPlans();
        const c=resolveToolConnection(input,extra,["MSP_ADMIN","CUSTOMER_ADMIN"]);
        const client=ec2Client(c.roleArn,c.externalId,input.region);
        const out=await client.send(new DescribeInstancesCommand({ InstanceIds:[input.instanceId] }));
        const instance=out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${input.instanceId}`);
        const ledgerRecord=terminationLedgerRecord(input.instanceId,c.customerId);
        const target=validateTerminationTarget(instance,ledgerRecord,c.customerId);
        const state=String(instance.State?.Name||"unknown").toLowerCase();
        if (state === "terminated") throw new Error("INSTANCE_ALREADY_TERMINATED: refresh the subscription to reconcile its release state.");
        if (["shutting-down"].includes(state)) throw new Error("INSTANCE_TERMINATION_ALREADY_IN_PROGRESS: wait for AWS to report terminated.");

        const protection=await client.send(new DescribeInstanceAttributeCommand({
          InstanceId:input.instanceId,
          Attribute:"disableApiTermination"
        }));
        if (protection.DisableApiTermination?.Value === true) {
          throw new Error("TERMINATION_PROTECTION_ENABLED: disable EC2 API termination protection in AWS before retrying.");
        }
        await verifyTerminatePermission(client,input.instanceId);

        const volumes=terminationVolumeImpact(instance);
        const deletingVolumes=volumes.filter(volume=>volume.deleteOnTermination);
        const preservedVolumes=volumes.filter(volume=>!volume.deleteOnTermination);
        const planId=randomUUID();
        const confirmation=`TERMINATE VODIA PBX ${target.name} INSTANCE ${input.instanceId} IN ${input.region}`;
        const expiresAt=Date.now()+VODIA_TERMINATION_PLAN_TTL_MS;
        terminationPlans.set(planId,{
          planId,
          customerId:c.customerId||null,
          roleArn:c.roleArn,
          externalId:c.externalId,
          region:input.region,
          instanceId:input.instanceId,
          name:target.name,
          productId:target.productId,
          agreementId:target.agreementId,
          ledgerRecord,
          confirmation,
          createdAt:Date.now(),
          expiresAt
        });
        return scopedSuccess({
          planId,
          expiresAt:new Date(expiresAt).toISOString(),
          confirmation,
          irreversible:true,
          permissionDryRunVerified:true,
          terminationProtection:false,
          deployment:{
            customerId:c.customerId||null,
            name:target.name,
            instanceId:input.instanceId,
            region:input.region,
            state,
            marketplaceAgreementId:target.agreementId,
            marketplaceProductId:target.productId
          },
          volumes,
          volumesDeletedOnTermination:deletingVolumes,
          volumesPreservedAfterTermination:preservedVolumes,
          changesMade:false
        }, { operation:"AWS_MARKETPLACE_PLAN_TERMINATE_VODIA_PBX", readOnly:true }, "Termination preflight passed. No AWS resource was changed. Review volume impact and enter the exact approval phrase to terminate.");
      } catch (error) {
        return failure(error,"AWS Marketplace Vodia PBX termination plan");
      }
    }
  );

  server.registerTool(
    "aws_marketplace_apply_terminate_vodia_pbx",
    {
      title: "Terminate Vodia PBX and release deployment slot",
      description: "Permanently terminates one preflighted customer-owned Vodia EC2 instance after exact approval. The Vodia deployment slot is released only after AWS later reports the instance terminated.",
      inputSchema: {
        planId: z.string().uuid(),
        confirmation: z.string().min(1)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint:false, destructiveHint:true, openWorldHint:true }
    },
    async ({planId,confirmation},extra) => {
      scopedAudit("aws_marketplace_apply_terminate_vodia_pbx",{planId});
      try {
        cleanExpiredTerminationPlans();
        const plan=terminationPlans.get(planId);
        if (!plan) throw new Error("TERMINATION_PLAN_NOT_FOUND_OR_EXPIRED: create a new termination plan.");
        if (confirmation !== plan.confirmation) throw new Error(`CONFIRMATION_MISMATCH: exact confirmation required: ${plan.confirmation}`);
        if (plan.customerId) requireCustomerAccess(extra,plan.customerId,["MSP_ADMIN","CUSTOMER_ADMIN"]);

        const client=ec2Client(plan.roleArn,plan.externalId,plan.region);
        const out=await client.send(new DescribeInstancesCommand({ InstanceIds:[plan.instanceId] }));
        const instance=out.Reservations?.[0]?.Instances?.[0];
        if (!instance) throw new Error(`INSTANCE_NOT_FOUND: ${plan.instanceId}`);
        const currentLedger=terminationLedgerRecord(plan.instanceId,plan.customerId) || plan.ledgerRecord;
        const target=validateTerminationTarget(instance,currentLedger,plan.customerId);
        if (target.name !== plan.name || target.agreementId !== plan.agreementId || target.productId !== plan.productId) {
          throw new Error("TERMINATION_TARGET_CHANGED: instance identity or Marketplace binding changed after planning.");
        }
        const state=String(instance.State?.Name||"unknown").toLowerCase();
        if (state === "terminated") throw new Error("INSTANCE_ALREADY_TERMINATED: no termination request was sent.");
        if (state === "shutting-down") throw new Error("INSTANCE_TERMINATION_ALREADY_IN_PROGRESS: no duplicate request was sent.");

        const terminated=await client.send(new TerminateInstancesCommand({ InstanceIds:[plan.instanceId] }));
        const transition=(terminated.TerminatingInstances||[])[0]||{};
        const now=new Date().toISOString();
        upsertMarketplaceDeployment({
          ...(currentLedger||{}),
          customerId:plan.customerId||currentLedger?.customerId||null,
          productId:plan.productId,
          agreementId:plan.agreementId,
          instanceId:plan.instanceId,
          name:plan.name,
          region:plan.region,
          instanceState:transition.CurrentState?.Name||"shutting-down",
          terminationRequestedAt:now,
          terminationRequestedBy:"mcp-approved-plan",
          releaseAgreementOnTermination:true,
          agreementReleasedAt:null,
          source:"termination-requested"
        });
        terminationPlans.delete(planId);
        return scopedSuccess({
          instanceId:plan.instanceId,
          name:plan.name,
          region:plan.region,
          previousState:transition.PreviousState?.Name||state,
          state:transition.CurrentState?.Name||"shutting-down",
          terminationRequestedAt:now,
          agreementId:plan.agreementId,
          agreementReleasePending:true,
          agreementReleased:false,
          changesMade:true
        }, { operation:"AWS_MARKETPLACE_APPLY_TERMINATE_VODIA_PBX", readOnly:false }, `Termination requested for ${plan.instanceId}. The Vodia deployment slot will be released only after AWS confirms terminated.`);
      } catch (error) {
        return failure(error,"AWS Marketplace Vodia PBX termination apply");
      }
    }
  );

  server.registerTool(
    "aws_get_vodia_pbx_deployment_status",
    {
      title: "Get Vodia PBX deployment status",
      description: "Reads a customer-owned Vodia PBX EC2 deployment, AWS status checks, network addresses, configuration, scheduled events, and Marketplace binding.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        region: z.string().min(3),
        instanceId: z.string().regex(/^(?:i-[0-9a-f]{8}|i-[0-9a-f]{17})$/)
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

        // Customer isolation: v0.14.9.68+ instances carry the customer tag.
        // Legacy instances are accepted only when already reconciled into this
        // customer's Marketplace deployment ledger.
        const ledger = loadMarketplaceDeploymentLedger();
        const ledgerRecord = ledger.deployments.find(row =>
          row?.instanceId === instanceId &&
          (!c.customerId || !row.customerId || row.customerId === c.customerId)
        ) || null;
        const taggedCustomerId = requiredInstanceTag(instance, "VodiaMspCustomerId");
        const marketplaceProductCodeVerified=instanceHasConfiguredVodiaProductCode(instance);
        if (!marketplaceProductCodeVerified && c.customerId && taggedCustomerId && taggedCustomerId !== c.customerId) {
          throw new Error("DEPLOYMENT_CUSTOMER_MISMATCH: instance belongs to another MSP customer.");
        }
        if (!marketplaceProductCodeVerified && c.customerId && !taggedCustomerId && !ledgerRecord) {
          throw new Error("DEPLOYMENT_NOT_IN_CUSTOMER_LEDGER: legacy instance is not assigned to the selected customer.");
        }

        let instanceStatus = null;
        let statusChecksError = null;
        try {
          const statusOut = await client.send(new DescribeInstanceStatusCommand({
            InstanceIds: [instanceId],
            IncludeAllInstances: true
          }));
          instanceStatus = (statusOut.InstanceStatuses || [])[0] || null;
        } catch (statusError) {
          statusChecksError = String(statusError?.message || statusError);
        }

        const systemStatus = instanceStatus?.SystemStatus?.Status || null;
        const ec2InstanceStatus = instanceStatus?.InstanceStatus?.Status || null;
        const checks = [systemStatus, ec2InstanceStatus];
        const checksPassed = checks.filter(value => value === "ok").length;
        const checkedAt = new Date().toISOString();
        const pbxName = requiredInstanceTag(instance, "Name");
        const marketplaceAgreementId = requiredInstanceTag(instance, "VodiaMarketplaceAgreementId") || ledgerRecord?.agreementId || null;
        const marketplaceProductId = requiredInstanceTag(instance, "VodiaMarketplaceProductId") || ledgerRecord?.productId || null;

        let otherAgreementInstances=[];
        if(ledgerRecord?.releaseAgreementOnTermination && instance.State?.Name === "terminated" && marketplaceAgreementId && marketplaceProductId){
          const releaseInventory=await scanVodiaManagedInventory(
            c.roleArn,c.externalId,c.customerId||null,marketplaceProductId
          );
          otherAgreementInstances=agreementInventoryMatches(releaseInventory,marketplaceAgreementId)
            .filter(row=>row.instanceId!==instanceId);
        }
        const agreementReleased = Boolean(
          ledgerRecord?.releaseAgreementOnTermination &&
          instance.State?.Name === "terminated" &&
          otherAgreementInstances.length===0
        );
        const agreementReleasedAt = agreementReleased
          ? (ledgerRecord?.agreementReleasedAt || checkedAt)
          : (ledgerRecord?.agreementReleasedAt || null);

        if (ledgerRecord) {
          upsertMarketplaceDeployment({
            ...ledgerRecord,
            name: pbxName || ledgerRecord.name || null,
            instanceState: instance.State?.Name || ledgerRecord.instanceState || null,
            publicIpAddress: instance.PublicIpAddress || null,
            publicDnsName: instance.PublicDnsName || null,
            lastStatusCheckAt: checkedAt,
            agreementReleasedAt,
            source: agreementReleased ? "termination-confirmed" : "deployment-monitor"
          });
        }

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
          checkedAt,
          pbxName,
          marketplaceAgreementId,
          marketplaceProductId,
          customerOwnershipVerified: Boolean(marketplaceProductCodeVerified || !c.customerId || taggedCustomerId === c.customerId || ledgerRecord),
          marketplaceProductCode:configuredMarketplaceProductCode()||null,
          marketplaceProductCodeVerified,
          statusChecksAvailable: Boolean(instanceStatus),
          statusChecksPassed: checksPassed,
          statusChecksTotal: 2,
          statusCheckSummary: instanceStatus ? `${checksPassed}/2 passed` : "Unavailable",
          systemStatus,
          instanceStatus: ec2InstanceStatus,
          statusChecksError,
          scheduledEvents: (instanceStatus?.Events || []).map(event => ({
            code: event.Code || null,
            description: event.Description || null,
            notBefore: event.NotBefore || null,
            notAfter: event.NotAfter || null
          })),
          monitoringState: instance.Monitoring?.State || null,
          vpcId: instance.VpcId || null,
          subnetId: instance.SubnetId || null,
          securityGroupIds: (instance.SecurityGroups || []).map(group => group.GroupId).filter(Boolean),
          keyName: instance.KeyName || null,
          architecture: instance.Architecture || null,
          platformDetails: instance.PlatformDetails || null,
          rootDeviceName: instance.RootDeviceName || null,
          pbxApplicationReadiness: "NOT_CHECKED",
          terminationRequested: Boolean(ledgerRecord?.terminationRequestedAt),
          agreementReleasePending: Boolean(ledgerRecord?.releaseAgreementOnTermination && !agreementReleased),
          agreementReleased,
          agreementReleasedAt,
          agreementReleaseBlockedByInstances:otherAgreementInstances,
          changesMade: false
        }, { operation: "AWS_EC2_GET_VODIA_PBX_DEPLOYMENT_STATUS", readOnly: true }, `Instance ${instanceId} state: ${instance.State?.Name || "unknown"}.`);
      } catch (error) {
        return failure(error, "AWS Vodia PBX deployment status");
      }
    }
  );
}
