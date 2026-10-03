import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { dirname } from "node:path";

const STORE_PATH = process.env.VODIA_PROVIDER_CONNECTION_STORE || "/var/lib/vodia-mcp/provider-connections.enc";
const KEY_PATH = process.env.VODIA_PROVIDER_CONNECTION_KEY_FILE || "/var/lib/vodia-mcp/provider-connections.key";

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
  if (key.length !== 32) throw new Error("PROVIDER_CONNECTION_KEY_INVALID");
  return key;
}

function emptyStore() {
  return { version: 1, providers: {}, updatedAt: null };
}

export function loadProviderConnections() {
  if (!existsSync(STORE_PATH)) return emptyStore();
  const env = JSON.parse(readFileSync(STORE_PATH, "utf8"));
  if (env?.v !== 1) throw new Error("PROVIDER_CONNECTION_STORE_INVALID");

  const decipher = createDecipheriv(
    "aes-256-gcm",
    keyBytes(),
    Buffer.from(env.iv, "base64")
  );
  decipher.setAuthTag(Buffer.from(env.tag, "base64"));
  const plain = Buffer.concat([
    decipher.update(Buffer.from(env.data, "base64")),
    decipher.final()
  ]);
  const parsed = JSON.parse(plain.toString("utf8"));
  return parsed && typeof parsed === "object" ? parsed : emptyStore();
}

export function saveProviderConnections(store) {
  const payload = {
    version: 1,
    providers: store?.providers || {},
    updatedAt: new Date().toISOString()
  };
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", keyBytes(), iv);
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(JSON.stringify(payload), "utf8")),
    cipher.final()
  ]);
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
  return payload;
}

export function saveProviderConnection(provider, values) {
  const store = loadProviderConnections();
  store.providers[provider] = {
    ...(store.providers[provider] || {}),
    ...values,
    updatedAt: new Date().toISOString()
  };
  return saveProviderConnections(store);
}

export function deleteProviderConnection(provider) {
  const store = loadProviderConnections();
  delete store.providers[provider];
  return saveProviderConnections(store);
}

function has(value) {
  return typeof value === "string" ? value.trim().length > 0 : Boolean(value);
}

export function sanitizeProviderConnections(store = loadProviderConnections()) {
  const p = store.providers || {};
  return {
    pbx: {
      configured: Boolean(p.pbx && has(p.pbx.baseUrl) && (has(p.pbx.apiToken) || has(p.pbx.apiUsername))),
      baseUrl: p.pbx?.baseUrl || null,
      apiUsername: p.pbx?.apiUsername || null,
      defaultTenant: p.pbx?.defaultTenant || null,
      apiTokenConfigured: has(p.pbx?.apiToken),
      apiPasswordConfigured: has(p.pbx?.apiPassword),
      updatedAt: p.pbx?.updatedAt || null
    },
    aws: {
      configured: Boolean(p.aws && has(p.aws.roleArn) && has(p.aws.externalId)),
      account: p.aws?.account || null,
      roleArn: p.aws?.roleArn || null,
      externalIdConfigured: has(p.aws?.externalId),
      defaultRegion: p.aws?.defaultRegion || null,
      updatedAt: p.aws?.updatedAt || null
    },
    microsoft: {
      configured: Boolean(p.microsoft && has(p.microsoft.tenantId) && has(p.microsoft.clientId) && has(p.microsoft.clientSecret)),
      tenantId: p.microsoft?.tenantId || null,
      clientId: p.microsoft?.clientId || null,
      clientSecretConfigured: has(p.microsoft?.clientSecret),
      updatedAt: p.microsoft?.updatedAt || null
    },
    cloudflare: {
      configured: Boolean(p.cloudflare && has(p.cloudflare.apiToken) && (has(p.cloudflare.domain) || has(p.cloudflare.zoneId))),
      domain: p.cloudflare?.domain || null,
      zoneId: p.cloudflare?.zoneId || null,
      apiTokenConfigured: has(p.cloudflare?.apiToken),
      updatedAt: p.cloudflare?.updatedAt || null
    }
  };
}
