import http from "node:http";
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import {
  loadProviderConnections,
  saveProviderConnection,
  deleteProviderConnection,
  sanitizeProviderConnections
} from "./provider-connections-store-v1.js";

const HOST = process.env.VODIA_ADMIN_CONNECTIONS_HOST || "127.0.0.1";
const PORT = Number(process.env.VODIA_ADMIN_CONNECTIONS_PORT || 3112);
const ADMIN_KEY_FILE = process.env.VODIA_ADMIN_CONNECTIONS_KEY_FILE || "/var/lib/vodia-mcp/admin-connections.key";
const MCP_URL = process.env.VODIA_CONTROL_MCP_URL || "http://127.0.0.1:3100/mcp";
const MCP_TOKEN = process.env.MCP_BEARER_TOKEN || "";
const SESSION_TTL_MS = 8 * 60 * 60 * 1000;
const sessions = new Map();

function json(res, status, body, extra = {}) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff",
    "referrer-policy": "no-referrer",
    ...extra
  });
  res.end(JSON.stringify(body));
}

function hash(value) {
  return createHash("sha256").update(String(value || ""), "utf8").digest();
}

function readAdminKey() {
  return readFileSync(ADMIN_KEY_FILE, "utf8").trim();
}

function secureEqual(a, b) {
  const aa = hash(a), bb = hash(b);
  return aa.length === bb.length && timingSafeEqual(aa, bb);
}

function parseCookies(req) {
  return Object.fromEntries(
    String(req.headers.cookie || "")
      .split(";")
      .map((x) => x.trim())
      .filter(Boolean)
      .map((x) => {
        const i = x.indexOf("=");
        return [decodeURIComponent(i < 0 ? x : x.slice(0, i)), decodeURIComponent(i < 0 ? "" : x.slice(i + 1))];
      })
  );
}

function getSession(req) {
  const id = parseCookies(req).vodia_admin_connections || "";
  const s = sessions.get(id);
  if (!s || s.expiresAt < Date.now()) {
    if (id) sessions.delete(id);
    return null;
  }
  return { id, ...s };
}

function requireSession(req, res, csrf = false) {
  const s = getSession(req);
  if (!s) {
    json(res, 401, { ok: false, error: "ADMIN_AUTH_REQUIRED" });
    return null;
  }
  if (csrf && req.headers["x-vodia-csrf"] !== s.csrf) {
    json(res, 403, { ok: false, error: "CSRF_REQUIRED" });
    return null;
  }
  return s;
}

async function body(req, max = 64 * 1024) {
  let text = "";
  for await (const chunk of req) {
    text += chunk;
    if (Buffer.byteLength(text) > max) throw new Error("REQUEST_TOO_LARGE");
  }
  if (!text) return {};
  return JSON.parse(text);
}

function validate(provider, v) {
  const clean = {};
  if (provider === "pbx") {
    clean.baseUrl = String(v.baseUrl || "").trim().replace(/\/$/, "");
    clean.apiUsername = String(v.apiUsername || "").trim();
    clean.defaultTenant = String(v.defaultTenant || "").trim();
    if (v.apiToken !== undefined) clean.apiToken = String(v.apiToken || "").trim();
    if (v.apiPassword !== undefined) clean.apiPassword = String(v.apiPassword || "");
    if (!/^https:\/\//i.test(clean.baseUrl)) throw new Error("PBX_BASE_URL_MUST_USE_HTTPS");
    if (!clean.apiUsername && !clean.apiToken) throw new Error("PBX_API_CREDENTIAL_REQUIRED");
  } else if (provider === "aws") {
    clean.roleArn = String(v.roleArn || "").trim();
    clean.externalId = String(v.externalId || "").trim();
    clean.defaultRegion = String(v.defaultRegion || "us-east-1").trim();
    if (!/^arn:aws:iam::\d{12}:role\/(?:[^/]+\/)*VodiaMCPDeploymentRole$/.test(clean.roleArn)) throw new Error("INVALID_AWS_ROLE_ARN");
    if (clean.externalId.length < 8) throw new Error("AWS_EXTERNAL_ID_TOO_SHORT");
  } else if (provider === "microsoft") {
    clean.tenantId = String(v.tenantId || "").trim();
    clean.clientId = String(v.clientId || "").trim();
    if (v.clientSecret !== undefined) clean.clientSecret = String(v.clientSecret || "").trim();
    if (!/^[0-9a-f-]{36}$/i.test(clean.tenantId)) throw new Error("INVALID_MICROSOFT_TENANT_ID");
    if (!/^[0-9a-f-]{36}$/i.test(clean.clientId)) throw new Error("INVALID_MICROSOFT_CLIENT_ID");
  } else if (provider === "cloudflare") {
    clean.domain = String(v.domain || "").trim().toLowerCase();
    clean.zoneId = String(v.zoneId || "").trim();
    if (v.apiToken !== undefined) clean.apiToken = String(v.apiToken || "").trim();
    if (!clean.domain && !clean.zoneId) throw new Error("CLOUDFLARE_DOMAIN_OR_ZONE_REQUIRED");
  } else {
    throw new Error("UNKNOWN_PROVIDER");
  }
  return clean;
}

function mergeSecret(provider, clean) {
  const existing = loadProviderConnections().providers?.[provider] || {};
  const secretKeys = {
    pbx: ["apiToken", "apiPassword"],
    aws: ["externalId"],
    microsoft: ["clientSecret"],
    cloudflare: ["apiToken"]
  }[provider] || [];
  for (const key of secretKeys) {
    if ((!Object.prototype.hasOwnProperty.call(clean, key) || clean[key] === "") && existing[key]) {
      clean[key] = existing[key];
    }
  }
  return clean;
}

function parseMcpBody(text, contentType) {
  if ((contentType || "").includes("text/event-stream")) {
    const payloads = text.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim()).filter(Boolean);
    for (let i = payloads.length - 1; i >= 0; i--) {
      try { return JSON.parse(payloads[i]); } catch {}
    }
    throw new Error("MCP_SSE_PARSE_FAILED");
  }
  return JSON.parse(text);
}

async function mcpPost(message, sessionId) {
  if (!MCP_TOKEN) throw new Error("MCP_BEARER_TOKEN_MISSING");
  const headers = {
    authorization: `Bearer ${MCP_TOKEN}`,
    "content-type": "application/json",
    accept: "application/json, text/event-stream"
  };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  const r = await fetch(MCP_URL, { method: "POST", headers, body: JSON.stringify(message) });
  const text = await r.text();
  if (!r.ok) throw new Error(`MCP_HTTP_${r.status}`);
  return { body: text ? parseMcpBody(text, r.headers.get("content-type")) : null, sessionId: r.headers.get("mcp-session-id") || sessionId || null };
}

async function callTool(name, args = {}) {
  let sessionId = null;
  const init = await mcpPost({
    jsonrpc: "2.0", id: 1, method: "initialize",
    params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "vodia-admin-connections", version: "1.0.0" } }
  });
  sessionId = init.sessionId;
  await mcpPost({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }, sessionId);
  const result = await mcpPost({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name, arguments: args } }, sessionId);
  if (result.body?.error) throw new Error(result.body.error.message || "MCP_TOOL_FAILED");
  return result.body?.result || result.body;
}

async function testMicrosoft(cfg) {
  const form = new URLSearchParams({
    client_id: cfg.clientId,
    client_secret: cfg.clientSecret,
    scope: "https://graph.microsoft.com/.default",
    grant_type: "client_credentials"
  });
  const token = await fetch(`https://login.microsoftonline.com/${encodeURIComponent(cfg.tenantId)}/oauth2/v2.0/token`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form
  });
  if (!token.ok) throw new Error(`MICROSOFT_OAUTH_${token.status}`);
  const t = await token.json();
  if (!t.access_token) throw new Error("MICROSOFT_ACCESS_TOKEN_MISSING");
  const org = await fetch("https://graph.microsoft.com/v1.0/organization?$select=id,displayName", {
    headers: { authorization: `Bearer ${t.access_token}` }
  });
  if (!org.ok) throw new Error(`MICROSOFT_GRAPH_${org.status}`);
  const o = await org.json();
  return { ok: true, organization: o.value?.[0]?.displayName || null };
}

async function testCloudflare(cfg) {
  const headers = { authorization: `Bearer ${cfg.apiToken}` };
  if (cfg.zoneId) {
    const r = await fetch(`https://api.cloudflare.com/client/v4/zones/${encodeURIComponent(cfg.zoneId)}`, { headers });
    if (!r.ok) throw new Error(`CLOUDFLARE_ZONE_${r.status}`);
    const j = await r.json();
    if (!j.success) throw new Error("CLOUDFLARE_ZONE_FAILED");
    return { ok: true, domain: j.result?.name || cfg.domain || null, zoneStatus: j.result?.status || null };
  }
  const r = await fetch(`https://api.cloudflare.com/client/v4/zones?name=${encodeURIComponent(cfg.domain)}&per_page=1`, { headers });
  if (!r.ok) throw new Error(`CLOUDFLARE_ZONE_${r.status}`);
  const j = await r.json();
  if (!j.success || !j.result?.length) throw new Error("CLOUDFLARE_ZONE_NOT_FOUND");
  return { ok: true, domain: j.result[0].name, zoneStatus: j.result[0].status || null };
}

async function testProvider(provider) {
  const cfg = loadProviderConnections().providers?.[provider];
  if (!cfg) throw new Error("PROVIDER_NOT_CONFIGURED");
  if (provider === "aws") {
    await callTool("aws_check_customer_connection", { roleArn: cfg.roleArn, externalId: cfg.externalId });
    return { ok: true, message: "STS AssumeRole passed" };
  }
  if (provider === "microsoft") return testMicrosoft(cfg);
  if (provider === "cloudflare") return testCloudflare(cfg);
  if (provider === "pbx") {
    await callTool("get_system_status", {});
    return { ok: true, message: "Active MCP PBX connection responded. Saved PBX profile is stored for the activation adapter." };
  }
  throw new Error("UNKNOWN_PROVIDER");
}

async function route(req, res) {
  const url = new URL(req.url, "http://localhost");

  if (req.method === "GET" && url.pathname === "/admin-connections-api/health") {
    return json(res, 200, { ok: true, service: "vodia-admin-connections", version: "1.0.0" });
  }

  if (req.method === "POST" && url.pathname === "/admin-connections-api/login") {
    const data = await body(req);
    if (!secureEqual(data.key, readAdminKey())) {
      return json(res, 401, { ok: false, error: "INVALID_ADMIN_KEY" });
    }
    const id = randomBytes(32).toString("hex");
    const csrf = randomBytes(24).toString("hex");
    sessions.set(id, { csrf, expiresAt: Date.now() + SESSION_TTL_MS });
    return json(res, 200, { ok: true, csrf }, {
      "set-cookie": `vodia_admin_connections=${id}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=${SESSION_TTL_MS / 1000}`
    });
  }

  if (req.method === "POST" && url.pathname === "/admin-connections-api/logout") {
    const s = getSession(req);
    if (s) sessions.delete(s.id);
    return json(res, 200, { ok: true }, {
      "set-cookie": "vodia_admin_connections=; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=0"
    });
  }

  if (req.method === "GET" && url.pathname === "/admin-connections-api/providers") {
    if (!requireSession(req, res)) return;
    return json(res, 200, { ok: true, providers: sanitizeProviderConnections() });
  }

  const match = url.pathname.match(/^\/admin-connections-api\/providers\/(pbx|aws|microsoft|cloudflare)(?:\/(test))?$/);
  if (match) {
    const provider = match[1], action = match[2] || null;

    if (req.method === "PUT" && !action) {
      if (!requireSession(req, res, true)) return;
      const incoming = validate(provider, await body(req));
      const clean = mergeSecret(provider, incoming);
      const saved = saveProviderConnection(provider, clean);

      if (provider === "aws") {
        try {
          await callTool("aws_save_customer_connection_profile", { roleArn: clean.roleArn, externalId: clean.externalId });
        } catch (e) {
          return json(res, 502, { ok: false, error: "AWS_PROFILE_SAVE_FAILED", detail: String(e.message || e) });
        }
      }

      return json(res, 200, { ok: true, provider, providers: sanitizeProviderConnections(saved) });
    }

    if (req.method === "POST" && action === "test") {
      if (!requireSession(req, res, true)) return;
      try {
        return json(res, 200, { provider, ...(await testProvider(provider)) });
      } catch (e) {
        return json(res, 502, { ok: false, provider, error: String(e.message || e) });
      }
    }

    if (req.method === "DELETE" && !action) {
      if (!requireSession(req, res, true)) return;
      const next = deleteProviderConnection(provider);
      return json(res, 200, { ok: true, provider, providers: sanitizeProviderConnections(next) });
    }
  }

  return json(res, 404, { ok: false, error: "NOT_FOUND" });
}

http.createServer((req, res) => {
  Promise.resolve(route(req, res)).catch((e) => json(res, 500, { ok: false, error: String(e?.message || e) }));
}).listen(PORT, HOST, () => {
  console.log(`[vodia-admin-connections] listening on http://${HOST}:${PORT}`);
});
