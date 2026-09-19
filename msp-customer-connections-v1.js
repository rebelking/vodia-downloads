import {
  createCipheriv, createDecipheriv, randomBytes
} from "node:crypto";
import {
  existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync
} from "node:fs";
import { dirname } from "node:path";
import { fromTemporaryCredentials } from "@aws-sdk/credential-providers";
import { STSClient, GetCallerIdentityCommand } from "@aws-sdk/client-sts";
import { requireCustomerAccess } from "./msp-authz-v1.js";

const STORE_PATH = process.env.VODIA_MSP_CUSTOMER_CONNECTION_STORE || "/var/lib/vodia-mcp/msp-customer-connections.enc";
const KEY_PATH = process.env.VODIA_MSP_CUSTOMER_CONNECTION_KEY_FILE || "/var/lib/vodia-mcp/msp-customer-connections.key";
const REGION = process.env.VODIA_MCP_AWS_MARKETPLACE_DISCOVERY_REGION || "us-east-1";

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
  data.customers[customerId] ||= {};
  data.customers[customerId].aws = {
    ...clean,
    account: identity.account,
    assumedRoleArn: identity.arn,
    savedAt: new Date().toISOString()
  };
  writeAll(data);
  return { connection: sanitizeScopedAwsConnection(data.customers[customerId].aws), identity };
}

export function registerMspCustomerConnectionTools(server, ctx) {
  const { z, toolOutputSchema, scopedAudit, scopedSuccess, failure } = ctx;

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
}
