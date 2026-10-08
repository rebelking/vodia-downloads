import {
  createCipheriv,
  createDecipheriv,
  randomBytes
} from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  chmodSync
} from "node:fs";
import { dirname } from "node:path";

const STORE_PATH = process.env.VODIA_MCP_AWS_CONNECTION_STORE || "/var/lib/vodia-mcp/aws-connection-profile.enc";
const KEY_PATH = process.env.VODIA_MCP_AWS_CONNECTION_KEY_FILE || "/var/lib/vodia-mcp/aws-connection.key";

function ensureParent(path) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
}

function keyBytes() {
  ensureParent(KEY_PATH);
  if (!existsSync(KEY_PATH)) {
    writeFileSync(KEY_PATH, randomBytes(32), { mode: 0o600, flag: "wx" });
  }
  chmodSync(KEY_PATH, 0o600);
  const key = readFileSync(KEY_PATH);
  if (key.length !== 32) throw new Error("AWS_CONNECTION_KEY_INVALID: expected a 32-byte AES key.");
  return key;
}

export function saveAwsConnectionProfile(profile) {
  const roleArn = String(profile?.roleArn || "").trim();
  const externalId = String(profile?.externalId || "").trim();
  if (!/^arn:aws:iam::\d{12}:role\/(?:[^/]+\/)*VodiaMCPDeploymentRole$/.test(roleArn)) {
    throw new Error("INVALID_CUSTOMER_ROLE: roleArn must target a role named VodiaMCPDeploymentRole.");
  }
  if (externalId.length < 8) {
    throw new Error("EXTERNAL_ID_REQUIRED: a customer-specific STS External ID of at least 8 characters is required.");
  }

  const payload = {
    version: 1,
    roleArn,
    externalId,
    account: profile?.account || null,
    assumedRoleArn: profile?.assumedRoleArn || null,
    savedAt: new Date().toISOString()
  };

  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyBytes(), iv);
  const plaintext = Buffer.from(JSON.stringify(payload), "utf8");
  const ciphertext = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();

  ensureParent(STORE_PATH);
  writeFileSync(
    STORE_PATH,
    JSON.stringify({
      v: 1,
      iv: iv.toString("base64"),
      tag: tag.toString("base64"),
      data: ciphertext.toString("base64")
    }),
    { mode: 0o600 }
  );
  chmodSync(STORE_PATH, 0o600);
  return sanitizeAwsConnectionProfile(payload);
}

export function loadAwsConnectionProfile() {
  if (!existsSync(STORE_PATH)) return null;
  const envelope = JSON.parse(readFileSync(STORE_PATH, "utf8"));
  if (envelope?.v !== 1) throw new Error("AWS_CONNECTION_STORE_INVALID: unsupported profile format.");

  const decipher = createDecipheriv(
    "aes-256-gcm",
    keyBytes(),
    Buffer.from(envelope.iv, "base64")
  );
  decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.data, "base64")),
    decipher.final()
  ]);
  return JSON.parse(plaintext.toString("utf8"));
}

export function sanitizeAwsConnectionProfile(profile) {
  if (!profile) return null;
  return {
    configured: true,
    roleArn: profile.roleArn,
    account: profile.account || null,
    assumedRoleArn: profile.assumedRoleArn || null,
    savedAt: profile.savedAt || null,
    externalIdConfigured: Boolean(profile.externalId)
  };
}

export function resolveAwsConnection(roleArn, externalId) {
  const explicitRole = String(roleArn || "").trim();
  const explicitExternal = String(externalId || "").trim();
  if (explicitRole || explicitExternal) {
    if (!explicitRole || !explicitExternal) {
      throw new Error("AWS_CONNECTION_INCOMPLETE: provide both roleArn and externalId, or omit both to use the saved AWS connection.");
    }
    return { roleArn: explicitRole, externalId: explicitExternal, source: "explicit" };
  }

  const saved = loadAwsConnectionProfile();
  if (!saved?.roleArn || !saved?.externalId) {
    throw new Error("AWS_CONNECTION_REQUIRED: no saved AWS connection is configured. Open Connect AWS Account and test/save the connection first.");
  }
  return { roleArn: saved.roleArn, externalId: saved.externalId, source: "saved" };
}
