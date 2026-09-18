import http from "node:http";
import { readFile } from "node:fs/promises";

const HOST = process.env.VODIA_CONTROL_API_HOST || "127.0.0.1";
const PORT = Number(process.env.VODIA_CONTROL_API_PORT || 3110);
const MCP_URL = process.env.VODIA_CONTROL_MCP_URL || "http://127.0.0.1:3100/mcp";
const HEALTH_URL = process.env.VODIA_CONTROL_HEALTH_URL || "http://127.0.0.1:3100/health";
const AUDIT_LOG = process.env.VODIA_AUDIT_LOG || "/var/log/vodia-mcp/audit.jsonl";
const TOKEN = process.env.MCP_BEARER_TOKEN || "";

function json(res, status, body) {
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    "x-content-type-options": "nosniff"
  });
  res.end(JSON.stringify(body));
}

function parseMcpBody(text, contentType) {
  if ((contentType || "").includes("text/event-stream")) {
    const payloads = text
      .split(/\r?\n/)
      .filter((line) => line.startsWith("data:"))
      .map((line) => line.slice(5).trim())
      .filter(Boolean);
    for (let i = payloads.length - 1; i >= 0; i--) {
      try { return JSON.parse(payloads[i]); } catch {}
    }
    throw new Error("MCP_SSE_PARSE_FAILED");
  }
  return JSON.parse(text);
}

async function mcpPost(message, sessionId) {
  if (!TOKEN) throw new Error("MCP_BEARER_TOKEN_MISSING");
  const headers = {
    authorization: `Bearer ${TOKEN}`,
    "content-type": "application/json",
    accept: "application/json, text/event-stream"
  };
  if (sessionId) headers["mcp-session-id"] = sessionId;
  const response = await fetch(MCP_URL, {
    method: "POST",
    headers,
    body: JSON.stringify(message)
  });
  const text = await response.text();
  if (!response.ok) throw new Error(`MCP_HTTP_${response.status}: ${text.slice(0, 300)}`);
  return {
    body: text ? parseMcpBody(text, response.headers.get("content-type")) : null,
    sessionId: response.headers.get("mcp-session-id") || sessionId || null
  };
}

async function callTool(name, args = {}) {
  let sessionId = null;
  try {
    const init = await mcpPost({
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2025-06-18",
        capabilities: {},
        clientInfo: { name: "vodia-control-center", version: "2.1.0" }
      }
    });
    sessionId = init.sessionId;
    await mcpPost({
      jsonrpc: "2.0",
      method: "notifications/initialized",
      params: {}
    }, sessionId);
    const result = await mcpPost({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name, arguments: args }
    }, sessionId);
    if (result.body?.error) throw new Error(result.body.error.message || "MCP tool call failed");
    return result.body?.result || result.body;
  } catch (error) {
    error.toolName = name;
    throw error;
  }
}

function unwrapToolResult(result) {
  const sc = result?.structuredContent;
  if (sc && typeof sc === "object") {
    if (sc.data && typeof sc.data === "object") return sc.data;
    if (sc.result && typeof sc.result === "object") return sc.result;
    return sc;
  }
  const textPart = Array.isArray(result?.content)
    ? result.content.find((x) => x?.type === "text" && typeof x.text === "string")
    : null;
  if (textPart) {
    try { return JSON.parse(textPart.text); } catch { return { message: textPart.text }; }
  }
  return result || {};
}

async function health() {
  const r = await fetch(HEALTH_URL);
  if (!r.ok) throw new Error(`HEALTH_HTTP_${r.status}`);
  return r.json();
}

async function safeTool(name, args = {}) {
  try {
    const raw = await callTool(name, args);
    return { ok: true, data: unwrapToolResult(raw) };
  } catch (error) {
    return { ok: false, error: String(error?.message || error), tool: name };
  }
}

async function connectionSummary() {
  const [aws, cloudflare, microsoft, pbx] = await Promise.all([
    safeTool("aws_get_customer_connection_profile"),
    safeTool("cloudflare_check_connection"),
    safeTool("microsoft_check_graph_readiness"),
    safeTool("get_system_status")
  ]);
  return { aws, cloudflare, microsoft, pbx };
}

async function tailAudit(limit = 20) {
  let text = "";
  try { text = await readFile(AUDIT_LOG, "utf8"); } catch { return []; }
  const lines = text.split(/\r?\n/).filter(Boolean).slice(-Math.max(1, Math.min(limit, 100))).reverse();
  return lines.map((line) => {
    try {
      const row = JSON.parse(line);
      const safe = {
        at: row.at || row.timestamp || row.time || null,
        tool: row.tool || row.action || row.operation || row.event || "MCP activity",
        actor: row.actor || row.user || row.subject || null,
        result: row.result || row.status || row.outcome || null
      };
      return safe;
    } catch {
      return { at: null, tool: "MCP activity", actor: null, result: "recorded" };
    }
  });
}

async function route(req, res) {
  if (req.method === "GET" && req.url === "/control-api/health") {
    try { return json(res, 200, { ok: true, health: await health() }); }
    catch (e) { return json(res, 503, { ok: false, error: String(e.message || e) }); }
  }

  if (req.method === "GET" && req.url === "/control-api/connections") {
    const summary = await connectionSummary();
    return json(res, 200, { ok: true, connections: summary });
  }

  if (req.method === "GET" && req.url.startsWith("/control-api/activity")) {
    const u = new URL(req.url, "http://localhost");
    const limit = Number(u.searchParams.get("limit") || 20);
    return json(res, 200, { ok: true, activity: await tailAudit(limit) });
  }

  if (req.method === "POST" && req.url.startsWith("/control-api/test/")) {
    const provider = req.url.slice("/control-api/test/".length);
    const map = {
      aws: ["aws_check_customer_connection", {}],
      cloudflare: ["cloudflare_check_connection", {}],
      microsoft: ["microsoft_check_graph_readiness", {}],
      pbx: ["get_system_status", {}]
    };
    if (!map[provider]) return json(res, 404, { ok: false, error: "UNKNOWN_PROVIDER" });
    const [tool, args] = map[provider];
    const result = await safeTool(tool, args);
    return json(res, result.ok ? 200 : 502, { provider, ...result });
  }

  if (req.method === "GET" && req.url === "/control-api/pbx") {
    const result = await safeTool("get_system_status");
    return json(res, result.ok ? 200 : 502, result);
  }

  return json(res, 404, { ok: false, error: "NOT_FOUND" });
}

http.createServer((req, res) => {
  Promise.resolve(route(req, res)).catch((error) => {
    json(res, 500, { ok: false, error: String(error?.message || error) });
  });
}).listen(PORT, HOST, () => {
  console.log(`[vodia-control-api] listening on http://${HOST}:${PORT}`);
});
