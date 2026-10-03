import { createDecipheriv } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";

const STORE_PATH = process.env.VODIA_PROVIDER_CONNECTION_STORE || "/var/lib/vodia-mcp/provider-connections.enc";
const KEY_PATH = process.env.VODIA_PROVIDER_CONNECTION_KEY_FILE || "/var/lib/vodia-mcp/provider-connections.key";

function loadStore() {
  if (!existsSync(STORE_PATH) || !existsSync(KEY_PATH)) return null;
  const key = readFileSync(KEY_PATH);
  if (key.length !== 32) throw new Error("PROVIDER_CONNECTION_KEY_INVALID");
  const envelope = JSON.parse(readFileSync(STORE_PATH, "utf8"));
  if (envelope?.v !== 1) throw new Error("PROVIDER_CONNECTION_STORE_INVALID");
  const decipher = createDecipheriv(
    "aes-256-gcm",
    key,
    Buffer.from(envelope.iv, "base64")
  );
  decipher.setAuthTag(Buffer.from(envelope.tag, "base64"));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(envelope.data, "base64")),
    decipher.final()
  ]);
  return JSON.parse(plaintext.toString("utf8"));
}

function setAliases(value, names) {
  if (value === undefined || value === null || String(value) === "") return;
  for (const name of names) process.env[name] = String(value);
}

function applyProviderEnvironment() {
  const store = loadStore();
  const providers = store?.providers || {};
  const pbx = providers.pbx || {};
  const microsoft = providers.microsoft || {};
  const cloudflare = providers.cloudflare || {};

  setAliases(pbx.baseUrl, [
    "VODIA_PBX_URL",
    "VODIA_PBX_BASE_URL",
    "VODIA_BASE_URL",
    "VODIA_URL",
    "PBX_URL",
    "PBX_BASE_URL"
  ]);
  setAliases(pbx.apiUsername, [
    "VODIA_API_USERNAME",
    "VODIA_USERNAME",
    "VODIA_PBX_USERNAME",
    "PBX_API_USERNAME",
    "PBX_USERNAME"
  ]);
  setAliases(pbx.apiToken, [
    "VODIA_API_TOKEN",
    "VODIA_TOKEN",
    "VODIA_PBX_TOKEN",
    "PBX_API_TOKEN",
    "PBX_TOKEN"
  ]);
  setAliases(pbx.apiPassword, [
    "VODIA_API_PASSWORD",
    "VODIA_PASSWORD",
    "VODIA_PBX_PASSWORD",
    "PBX_API_PASSWORD",
    "PBX_PASSWORD"
  ]);
  setAliases(pbx.defaultTenant, [
    "VODIA_DEFAULT_TENANT",
    "VODIA_TENANT",
    "PBX_DEFAULT_TENANT"
  ]);

  setAliases(microsoft.tenantId, [
    "MICROSOFT_TENANT_ID",
    "MS_TENANT_ID",
    "M365_TENANT_ID",
    "AZURE_TENANT_ID",
    "ENTRA_TENANT_ID",
    "GRAPH_TENANT_ID",
    "MS_GRAPH_TENANT_ID"
  ]);
  setAliases(microsoft.clientId, [
    "MICROSOFT_CLIENT_ID",
    "MS_CLIENT_ID",
    "M365_CLIENT_ID",
    "AZURE_CLIENT_ID",
    "ENTRA_CLIENT_ID",
    "GRAPH_CLIENT_ID",
    "MS_GRAPH_CLIENT_ID"
  ]);
  setAliases(microsoft.clientSecret, [
    "MICROSOFT_CLIENT_SECRET",
    "MS_CLIENT_SECRET",
    "M365_CLIENT_SECRET",
    "AZURE_CLIENT_SECRET",
    "ENTRA_CLIENT_SECRET",
    "GRAPH_CLIENT_SECRET",
    "MS_GRAPH_CLIENT_SECRET"
  ]);

  setAliases(cloudflare.apiToken, [
    "CLOUDFLARE_API_TOKEN",
    "CLOUDFLARE_TOKEN",
    "CF_API_TOKEN",
    "CF_TOKEN"
  ]);
  setAliases(cloudflare.zoneId, [
    "CLOUDFLARE_ZONE_ID",
    "CF_ZONE_ID"
  ]);
  setAliases(cloudflare.domain, [
    "CLOUDFLARE_DOMAIN",
    "CLOUDFLARE_ZONE_NAME",
    "CF_DOMAIN"
  ]);

  const configured = [];
  if (pbx.baseUrl && (pbx.apiToken || pbx.apiUsername)) configured.push("pbx");
  if (microsoft.tenantId && microsoft.clientId && microsoft.clientSecret) configured.push("microsoft");
  if (cloudflare.apiToken && (cloudflare.domain || cloudflare.zoneId)) configured.push("cloudflare");

  if (configured.length) {
    process.env.VODIA_PROVIDER_RUNTIME_SOURCE = "encrypted-admin-store";
    process.env.VODIA_PROVIDER_RUNTIME_CONFIGURED = configured.join(",");
  }
}

try {
  applyProviderEnvironment();
} catch (error) {
  console.error("[vodia-provider-runtime] provider environment bridge failed:", error?.message || error);
}
