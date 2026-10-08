import {
  createCipheriv, createDecipheriv, randomBytes
} from "node:crypto";
import {
  existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync
} from "node:fs";
import { dirname } from "node:path";
import { fromTemporaryCredentials } from "@aws-sdk/credential-providers";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";
import {
  requireCustomerAccess,
  getCustomerDeletePreview,
  getOrganizationDeletePreview,
  deleteCustomerRecord,
  deleteOrganizationRecord
} from "./msp-authz-v1.js";

const STORE_PATH = process.env.VODIA_MSP_CUSTOMER_CONNECTION_STORE || "/var/lib/vodia-mcp/msp-customer-connections.enc";
const KEY_PATH = process.env.VODIA_MSP_CUSTOMER_CONNECTION_KEY_FILE || "/var/lib/vodia-mcp/msp-customer-connections.key";
const REGION = process.env.VODIA_MCP_AWS_MARKETPLACE_DISCOVERY_REGION || "us-east-1";
const PROVIDER_ROLE_ARN = process.env.VODIA_MCP_AWS_PROVIDER_ROLE_ARN || "arn:aws:iam::963966408518:role/VodiaMCPChimeRole";
const DEPLOYMENT_ROLE_NAME = "VodiaMCPDeploymentRole";

const DEPLOYMENT_POLICY = {
  Version: "2012-10-17",
  Statement: [
    {
      Sid: "MarketplaceRead",
      Effect: "Allow",
      Action: [
        "aws-marketplace:SearchListings", "aws-marketplace:GetProduct",
        "aws-marketplace:ListFulfillmentOptions", "aws-marketplace:ListPurchaseOptions",
        "aws-marketplace:GetOffer", "aws-marketplace:GetOfferTerms",
        "aws-marketplace:SearchAgreements", "aws-marketplace:DescribeAgreement",
        "aws-marketplace:GetAgreementTerms", "aws-marketplace:GetAgreementEntitlements",
        "aws-marketplace:ViewSubscriptions"
      ],
      Resource: "*"
    },
    {
      Sid: "MarketplacePurchaseVodiaOnly",
      Effect: "Allow",
      Action: ["aws-marketplace:CreateAgreementRequest", "aws-marketplace:AcceptAgreementRequest"],
      Resource: "*",
      Condition: { "ForAnyValue:StringEquals": { "aws-marketplace:ProductId": ["prod-v5qnz6xf6wu5u"] } }
    },
    {
      Sid: "EC2ReadAndLaunch",
      Effect: "Allow",
      Action: [
        "ec2:DescribeRegions", "ec2:DescribeAvailabilityZones", "ec2:DescribeVpcs",
        "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeKeyPairs",
        "ec2:DescribeImages", "ec2:DescribeInstances", "ec2:DescribeInstanceStatus",
        "ec2:DescribeInstanceTypes", "ec2:RunInstances", "ec2:CreateTags"
      ],
      Resource: "*"
    },
    {
      Sid: "PassVodiaEntitlementRoleOnly",
      Effect: "Allow",
      Action: "iam:PassRole",
      Resource: "arn:aws:iam::*:role/VodiaPBXMarketplaceEntitlementRole"
    }
  ]
};

function ensureParent(path) { mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); }

function keyBytes() {
  ensureParent(KEY_PATH);
  if (!existsSync(KEY_PATH)) writeFileSync(KEY_PATH, randomBytes(32), { mode: 0o600, flag: "wx" });
  chmodSync(KEY_PATH, 0o600);
  const key = readFileSync(KEY_PATH);
  if (key.length !== 32) throw new Error("MSP_CONNECTION_KEY_INVALID");
  return key;
}

function readAll() {
  if (!existsSync(STORE_PATH)) return { version: 1, customers: {} };
  const env = JSON.parse(readFileSync(STORE_PATH, "utf8"));
  if (env?.v !== 1) throw new Error("MSP_CONNECTION_STORE_INVALID");
  const decipher = createDecipheriv("aes-256-gcm", keyBytes(), Buffer.from(env.iv, "base64"));
  decipher.setAuthTag(Buffer.from(env.tag, "base64"));
  const plain = Buffer.concat([decipher.update(Buffer.from(env.data, "base64")), decipher.final()]);
  const parsed = JSON.parse(plain.toString("utf8"));
  if (!parsed.customers) parsed.customers = {};
  return parsed;
}

function writeAll(data) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyBytes(), iv);
  const ciphertext = Buffer.concat([cipher.update(Buffer.from(JSON.stringify(data))), cipher.final()]);
  ensureParent(STORE_PATH);
  writeFileSync(STORE_PATH, JSON.stringify({
    v: 1, iv: iv.toString("base64"), tag: cipher.getAuthTag().toString("base64"), data: ciphertext.toString("base64")
  }), { mode: 0o600 });
  chmodSync(STORE_PATH, 0o600);
}

function customerRecord(data, customerId) {
  data.customers[customerId] ||= {};
  return data.customers[customerId];
}

function buildCustomerCloudShellScript(externalId) {
  const trust = {
    Version: "2012-10-17",
    Statement: [{
      Sid: "TrustVodiaMCP",
      Effect: "Allow",
      Principal: { AWS: PROVIDER_ROLE_ARN },
      Action: "sts:AssumeRole",
      Condition: { StringEquals: { "sts:ExternalId": externalId } }
    }]
  };
  const entitlementTrust = {
    Version: "2012-10-17",
    Statement: [{ Effect: "Allow", Principal: { Service: "ec2.amazonaws.com" }, Action: "sts:AssumeRole" }]
  };
  const q = (value) => `'${JSON.stringify(value).replaceAll("'", "'\\''")}'`;

  return `set -euo pipefail
ROLE_NAME="${DEPLOYMENT_ROLE_NAME}"
ENTITLEMENT_ROLE="VodiaPBXMarketplaceEntitlementRole"
TRUST_FILE="$(mktemp)"
POLICY_FILE="$(mktemp)"
ENTITLEMENT_TRUST_FILE="$(mktemp)"
trap 'rm -f "$TRUST_FILE" "$POLICY_FILE" "$ENTITLEMENT_TRUST_FILE"' EXIT
printf '%s' ${q(trust)} > "$TRUST_FILE"
printf '%s' ${q(DEPLOYMENT_POLICY)} > "$POLICY_FILE"
printf '%s' ${q(entitlementTrust)} > "$ENTITLEMENT_TRUST_FILE"
if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ROLE_NAME" --policy-document "file://$TRUST_FILE"
else
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "file://$TRUST_FILE" >/dev/null
fi
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name VodiaMCPDeploymentRolePolicy --policy-document "file://$POLICY_FILE"
if aws iam get-role --role-name "$ENTITLEMENT_ROLE" >/dev/null 2>&1; then
  aws iam update-assume-role-policy --role-name "$ENTITLEMENT_ROLE" --policy-document "file://$ENTITLEMENT_TRUST_FILE"
else
  aws iam create-role --role-name "$ENTITLEMENT_ROLE" --assume-role-policy-document "file://$ENTITLEMENT_TRUST_FILE" >/dev/null
fi
aws iam attach-role-policy --role-name "$ENTITLEMENT_ROLE" --policy-arn arn:aws:iam::aws:policy/AWSMarketplaceGetEntitlements
aws iam get-instance-profile --instance-profile-name "$ENTITLEMENT_ROLE" >/dev/null 2>&1 || aws iam create-instance-profile --instance-profile-name "$ENTITLEMENT_ROLE" >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name "$ENTITLEMENT_ROLE" --role-name "$ENTITLEMENT_ROLE" 2>/dev/null || true
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Vodia AWS setup complete"
echo "AWS Account ID: $ACCOUNT_ID"
echo "Role ARN: arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"`;
}

function validateAws(roleArn, externalId) {
  const role = String(roleArn || "").trim();
  const ext = String(externalId || "").trim();
  if (!/^arn:aws:iam::\d{12}:role\/(?:[^/]+\/)*VodiaMCPDeploymentRole$/.test(role)) {
    throw new Error("INVALID_CUSTOMER_ROLE: roleArn must target VodiaMCPDeploymentRole.");
  }
  if (ext.length < 8) throw new Error("EXTERNAL_ID_REQUIRED");
  return { roleArn: role, externalId: ext };
}

async function testAws(roleArn, externalId) {
  const credentials = fromTemporaryCredentials({
    params: { RoleArn: roleArn, ExternalId: externalId, RoleSessionName: "vodia-mcp-customer-connect" }
  });
  const out = await new STSClient({ region: REGION, credentials }).send(new GetCallerIdentityCommand({}));
  return { account: out.Account || null, arn: out.Arn || null, userId: out.UserId || null };
}

export function loadScopedAwsConnection(customerId) {
  const c = readAll().customers?.[customerId]?.aws;
  return c || null;
}

export function sanitizeScopedAwsConnection(connection) {
  if (!connection) return null;
  return {
    configured: true,
    account: connection.account || null,
    roleArn: connection.roleArn || null,
    savedAt: connection.savedAt || null,
    externalIdConfigured: Boolean(connection.externalId)
  };
}

export function resolveScopedAwsConnection(customerId) {
  const c = loadScopedAwsConnection(customerId);
  if (!c?.roleArn || !c?.externalId) throw new Error("CUSTOMER_AWS_CONNECTION_REQUIRED");
  return { roleArn: c.roleArn, externalId: c.externalId, source: "msp-customer", customerId };
}

export async function saveScopedAwsConnection(customerId, roleArn, externalId) {
  const clean = validateAws(roleArn, externalId);
  const identity = await testAws(clean.roleArn, clean.externalId);
  const data = readAll();
  const customer = customerRecord(data, customerId);
  customer.aws = {
    ...clean,
    account: identity.account,
    assumedRoleArn: identity.arn,
    savedAt: new Date().toISOString()
  };
  delete customer.awsOnboarding;
  writeAll(data);
  return { connection: sanitizeScopedAwsConnection(customer.aws), identity };
}

export async function prepareScopedAwsOnboarding(customerId) {
  const data = readAll();
  const customer = customerRecord(data, customerId);

  // v0.14.9.55: never generate a replacement External ID for a customer
  // that already has a saved AWS connection. Verify the canonical saved
  // connection instead and discard any stale pending onboarding state.
  if (customer.aws?.roleArn && customer.aws?.externalId) {
    const identity = await testAws(customer.aws.roleArn, customer.aws.externalId);
    if (customer.awsOnboarding) {
      delete customer.awsOnboarding;
      writeAll(data);
    }
    return {
      alreadyConnected: true,
      reusedExisting: true,
      providerRoleArn: PROVIDER_ROLE_ARN,
      roleName: DEPLOYMENT_ROLE_NAME,
      connection: sanitizeScopedAwsConnection(customer.aws),
      identity,
      externalId: null,
      generatedAt: null,
      cloudShellScript: null
    };
  }

  // Preserve one pending onboarding package across retries. A retry must not
  // silently rotate the External ID while CloudFormation/CloudShell is using it.
  const pending = customer.awsOnboarding;
  const reusable = Boolean(
    pending?.externalId &&
    pending?.providerRoleArn === PROVIDER_ROLE_ARN
  );
  const externalId = reusable
    ? pending.externalId
    : `vodia-${randomBytes(16).toString("hex")}`;

  if (!reusable) {
    customer.awsOnboarding = {
      externalId,
      providerRoleArn: PROVIDER_ROLE_ARN,
      generatedAt: new Date().toISOString()
    };
    writeAll(data);
  }

  return {
    alreadyConnected: false,
    reusedExisting: false,
    providerRoleArn: PROVIDER_ROLE_ARN,
    roleName: DEPLOYMENT_ROLE_NAME,
    externalId,
    generatedAt: customer.awsOnboarding.generatedAt,
    cloudShellScript: buildCustomerCloudShellScript(externalId)
  };
}

export async function completeScopedAwsOnboarding(customerId, accountId) {
  const account = String(accountId || "").trim();
  if (!/^\d{12}$/.test(account)) throw new Error("INVALID_AWS_ACCOUNT_ID: enter the 12-digit AWS account ID printed by CloudShell.");
  const data = readAll();
  const customer = customerRecord(data, customerId);

  // v0.14.9.55 recovery path: if this customer is already connected to the
  // same AWS account, verify the saved External ID and ignore stale onboarding.
  if (customer.aws?.roleArn && customer.aws?.externalId) {
    const savedAccount = String(customer.aws.account || customer.aws.roleArn.match(/^arn:aws:iam::(\d{12}):role\//)?.[1] || "");
    if (savedAccount === account) {
      const identity = await testAws(customer.aws.roleArn, customer.aws.externalId);
      if (customer.awsOnboarding) {
        delete customer.awsOnboarding;
        writeAll(data);
      }
      return {
        connection: sanitizeScopedAwsConnection(customer.aws),
        identity,
        reusedExisting: true,
        changesMade: false
      };
    }
  }

  const pending = customer.awsOnboarding;
  if (!pending?.externalId) throw new Error("AWS_ONBOARDING_NOT_PREPARED: generate the hosted AWS setup first.");
  const roleArn = `arn:aws:iam::${account}:role/${DEPLOYMENT_ROLE_NAME}`;
  return saveScopedAwsConnection(customerId, roleArn, pending.externalId);
}

// v0.14.9.52 guarded deletion helpers
function removeScopedAwsConnections(customerIds) {
  const ids = [...new Set((customerIds || []).map(String))];
  if (!ids.length) return { removed: [], backup: {} };
  const data = readAll();
  const backup = {};
  const removed = [];
  for (const id of ids) {
    if (data.customers?.[id]) {
      backup[id] = data.customers[id];
      delete data.customers[id];
      removed.push(id);
    }
  }
  if (removed.length) writeAll(data);
  return { removed, backup };
}

function restoreScopedAwsConnections(backup) {
  const entries = Object.entries(backup || {});
  if (!entries.length) return;
  const data = readAll();
  for (const [id, value] of entries) data.customers[id] = value;
  writeAll(data);
}

function scopedAwsDependency(customerId) {
  return sanitizeScopedAwsConnection(loadScopedAwsConnection(customerId));
}

export function registerMspCustomerConnectionTools(server, ctx) {
  const { z, toolOutputSchema, scopedAudit, scopedSuccess, failure } = ctx;

  server.registerTool("msp_plan_delete_customer", {
    title: "Plan customer deletion",
    description: "Previews deletion of one MSP customer. Read-only. Shows memberships, retained audit rows, saved AWS connection dependency, and the exact confirmation phrase.",
    inputSchema: { customerId: z.string().uuid() },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async ({ customerId }, extra) => {
    try {
      const preview = getCustomerDeletePreview(extra, customerId);
      const awsConnection = scopedAwsDependency(customerId);
      return scopedSuccess({
        ...preview,
        awsConnection,
        awsConnectionMustBeDetached: Boolean(awsConnection),
        changesMade: false
      }, { operation: "MSP_CUSTOMER_DELETE_PLAN", readOnly: true },
      awsConnection
        ? "Customer deletion planned. A saved AWS connection exists; apply requires detachAwsConnection=true."
        : "Customer deletion planned. No saved AWS connection dependency was found.");
    } catch (error) { return failure(error, "MSP customer deletion plan"); }
  });

  server.registerTool("msp_apply_delete_customer", {
    title: "Delete MSP customer",
    description: "Permanently deletes one MSP customer after exact confirmation. Requires MSP_ADMIN. If a saved AWS connection exists, detachAwsConnection=true is required. Detaching only removes Vodia's saved connection metadata; it does not delete AWS IAM roles, EC2 instances, DNS, or other cloud resources.",
    inputSchema: {
      customerId: z.string().uuid(),
      confirmation: z.string().min(10),
      detachAwsConnection: z.boolean().default(false)
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }
  }, async ({ customerId, confirmation, detachAwsConnection }, extra) => {
    let removed = { removed: [], backup: {} };
    try {
      const preview = getCustomerDeletePreview(extra, customerId);
      if (confirmation !== preview.confirmation) throw new Error(`CONFIRMATION_REQUIRED: exact phrase is ${preview.confirmation}`);
      const awsConnection = scopedAwsDependency(customerId);
      if (awsConnection && !detachAwsConnection) {
        throw new Error("CUSTOMER_AWS_CONNECTION_DEPENDENCY: rerun with detachAwsConnection=true after reviewing the deletion plan.");
      }
      if (awsConnection) removed = removeScopedAwsConnections([customerId]);
      try { deleteCustomerRecord(extra, customerId); }
      catch (error) { restoreScopedAwsConnections(removed.backup); throw error; }

      scopedAudit("msp_apply_delete_customer", {
        organizationId: preview.customer.organizationId,
        customerId,
        customerName: preview.customer.name,
        awsConnectionDetached: Boolean(awsConnection),
        subject: preview.requestedBy
      });

      return scopedSuccess({
        deleted: {
          customerId,
          customerName: preview.customer.name,
          organizationId: preview.customer.organizationId,
          organizationName: preview.customer.organizationName
        },
        awsConnectionDetached: Boolean(awsConnection),
        externalCloudResourcesDeleted: false,
        retainedCommercialAuditRows: preview.commercialAuditCount,
        changesMade: true
      }, { operation: "MSP_CUSTOMER_DELETE_APPLY", readOnly: false },
      "MSP customer deleted. External cloud resources were not deleted.");
    } catch (error) { return failure(error, "MSP customer deletion apply"); }
  });

  server.registerTool("msp_plan_delete_organization", {
    title: "Plan organization deletion",
    description: "Previews deletion of an MSP organization and all customers/memberships that would cascade. Read-only. Shows saved AWS connection dependencies and the exact confirmation phrase.",
    inputSchema: { organizationId: z.string().uuid() },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async ({ organizationId }, extra) => {
    try {
      const preview = getOrganizationDeletePreview(extra, organizationId);
      const customerDependencies = preview.customers.map(c => ({
        customerId: c.id,
        customerName: c.name,
        awsConnection: scopedAwsDependency(c.id)
      }));
      const awsConnectionCount = customerDependencies.filter(x => x.awsConnection).length;
      return scopedSuccess({
        ...preview,
        customerDependencies,
        awsConnectionCount,
        awsConnectionsMustBeDetached: awsConnectionCount > 0,
        lastOrganizationDeleteBlocked: preview.organizationCount <= 1,
        changesMade: false
      }, { operation: "MSP_ORGANIZATION_DELETE_PLAN", readOnly: true },
      preview.organizationCount <= 1
        ? "Organization deletion cannot be applied because this is the final MSP organization."
        : awsConnectionCount
          ? `Organization deletion planned. ${awsConnectionCount} saved AWS connection(s) require explicit detachment.`
          : "Organization deletion planned. No saved AWS connection dependencies were found.");
    } catch (error) { return failure(error, "MSP organization deletion plan"); }
  });

  server.registerTool("msp_apply_delete_organization", {
    title: "Delete MSP organization",
    description: "Permanently deletes an MSP organization after exact confirmation. Customers and memberships cascade. Requires MSP_ADMIN. The final remaining organization cannot be deleted. Saved AWS connections require detachAwsConnections=true. Detaching does not delete external AWS resources.",
    inputSchema: {
      organizationId: z.string().uuid(),
      confirmation: z.string().min(10),
      detachAwsConnections: z.boolean().default(false)
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false }
  }, async ({ organizationId, confirmation, detachAwsConnections }, extra) => {
    let removed = { removed: [], backup: {} };
    try {
      const preview = getOrganizationDeletePreview(extra, organizationId);
      if (preview.organizationCount <= 1) {
        throw new Error("LAST_ORGANIZATION_DELETE_BLOCKED: create another organization before deleting the final MSP organization.");
      }
      if (confirmation !== preview.confirmation) throw new Error(`CONFIRMATION_REQUIRED: exact phrase is ${preview.confirmation}`);

      const customerIds = preview.customers.map(c => c.id);
      const awsDependencies = customerIds
        .map(id => ({ customerId: id, connection: scopedAwsDependency(id) }))
        .filter(x => x.connection);
      if (awsDependencies.length && !detachAwsConnections) {
        throw new Error(`ORGANIZATION_AWS_CONNECTION_DEPENDENCY: ${awsDependencies.length} saved AWS connection(s) exist; rerun with detachAwsConnections=true after reviewing the deletion plan.`);
      }

      if (awsDependencies.length) removed = removeScopedAwsConnections(customerIds);
      try { deleteOrganizationRecord(extra, organizationId); }
      catch (error) { restoreScopedAwsConnections(removed.backup); throw error; }

      scopedAudit("msp_apply_delete_organization", {
        organizationId,
        organizationName: preview.organization.name,
        deletedCustomerCount: preview.customerCount,
        detachedAwsConnectionCount: awsDependencies.length,
        subject: preview.requestedBy
      });

      return scopedSuccess({
        deleted: {
          organizationId,
          organizationName: preview.organization.name,
          customerCount: preview.customerCount,
          customerIds
        },
        detachedAwsConnectionCount: awsDependencies.length,
        externalCloudResourcesDeleted: false,
        retainedCommercialAuditRows: preview.commercialAuditCount,
        changesMade: true
      }, { operation: "MSP_ORGANIZATION_DELETE_APPLY", readOnly: false },
      "MSP organization deleted. Customers/memberships cascaded; external cloud resources were not deleted.");
    } catch (error) { return failure(error, "MSP organization deletion apply"); }
  });

  server.registerTool("msp_get_customer_aws_connection", {
    title: "Get customer AWS connection",
    description: "Returns sanitized AWS connection metadata for a customer the OAuth identity can access. External ID is never returned.",
    inputSchema: { customerId: z.string().uuid() },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async ({ customerId }, extra) => {
    try {
      requireCustomerAccess(extra, customerId);
      return scopedSuccess({ customerId, connection: sanitizeScopedAwsConnection(loadScopedAwsConnection(customerId)), changesMade: false },
        { operation: "MSP_CUSTOMER_AWS_CONNECTION_GET", readOnly: true },
        loadScopedAwsConnection(customerId) ? "Customer AWS connection found." : "Customer AWS connection is not configured.");
    } catch (error) { return failure(error, "MSP customer AWS connection read"); }
  });

  server.registerTool("msp_save_customer_aws_connection", {
    title: "Connect customer AWS account",
    description: "Tests STS AssumeRole and saves the AWS role/External ID encrypted for exactly one customer. Requires MSP or customer administrator OAuth access.",
    inputSchema: {
      customerId: z.string().uuid(),
      roleArn: z.string().min(20),
      externalId: z.string().min(8)
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
  }, async ({ customerId, roleArn, externalId }, extra) => {
    try {
      const access = requireCustomerAccess(extra, customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      const result = await saveScopedAwsConnection(customerId, roleArn, externalId);
      scopedAudit("msp_save_customer_aws_connection", { customerId, subject: access.identity.subject, account: result.identity.account });
      return scopedSuccess({ customerId, connection: result.connection, identity: result.identity, changesMade: true },
        { operation: "MSP_CUSTOMER_AWS_CONNECTION_SAVE", readOnly: false },
        "Customer AWS connection tested and saved.");
    } catch (error) { return failure(error, "MSP customer AWS connection save"); }
  });

  server.registerTool("msp_prepare_customer_aws_onboarding", {
    title: "Prepare customer AWS setup",
    description: "Generates a customer-specific External ID and a one-command AWS CloudShell setup script. The generated values are scoped to exactly one customer.",
    inputSchema: { customerId: z.string().uuid() },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, async ({ customerId }, extra) => {
    try {
      const access = requireCustomerAccess(extra, customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      const onboarding = await prepareScopedAwsOnboarding(customerId);
      scopedAudit("msp_prepare_customer_aws_onboarding", {
        customerId,
        subject: access.identity.subject,
        alreadyConnected: Boolean(onboarding.alreadyConnected)
      });
      return scopedSuccess({
        customerId,
        onboarding,
        changesMade: !onboarding.alreadyConnected
      },
        { operation: "MSP_CUSTOMER_AWS_ONBOARDING_PREPARE", readOnly: false },
        onboarding.alreadyConnected
          ? "Existing customer AWS connection verified. No new External ID or AWS setup was generated."
          : "Customer AWS onboarding package generated.");
    } catch (error) { return failure(error, "MSP customer AWS onboarding preparation"); }
  });

  server.registerTool("msp_complete_customer_aws_onboarding", {
    title: "Verify customer AWS setup",
    description: "Derives the fixed Vodia deployment role ARN from the customer's AWS account ID, tests STS with the stored customer-specific External ID, and saves the verified connection.",
    inputSchema: { customerId: z.string().uuid(), accountId: z.string().regex(/^\d{12}$/) },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: true }
  }, async ({ customerId, accountId }, extra) => {
    try {
      const access = requireCustomerAccess(extra, customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      const result = await completeScopedAwsOnboarding(customerId, accountId);
      scopedAudit("msp_complete_customer_aws_onboarding", { customerId, subject: access.identity.subject, account: result.identity.account });
      return scopedSuccess({ customerId, connection: result.connection, identity: result.identity, changesMade: true },
        { operation: "MSP_CUSTOMER_AWS_ONBOARDING_COMPLETE", readOnly: false },
        "Customer AWS account verified and connected.");
    } catch (error) { return failure(error, "MSP customer AWS onboarding completion"); }
  });
}
