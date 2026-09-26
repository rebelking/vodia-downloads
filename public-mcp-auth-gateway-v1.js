import http from "node:http";

const LISTEN_HOST = process.env.VODIA_PUBLIC_MCP_GATEWAY_HOST || "127.0.0.1";
const LISTEN_PORT = Number(process.env.VODIA_PUBLIC_MCP_GATEWAY_PORT || 3113);
const UPSTREAM_HOST = process.env.VODIA_PUBLIC_MCP_UPSTREAM_HOST || "127.0.0.1";
const UPSTREAM_PORT = Number(process.env.VODIA_PUBLIC_MCP_UPSTREAM_PORT || 3100);
const LEGACY_TOKEN = String(process.env.MCP_BEARER_TOKEN || "").trim();

function bearer(req) {
  const h = String(req.headers.authorization || "");
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1].trim() : null;
}

function sendJson(res, status, body) {
  const payload = Buffer.from(JSON.stringify(body));
  res.writeHead(status, {
    "content-type": "application/json",
    "content-length": String(payload.length),
    "cache-control": "no-store"
  });
  res.end(payload);
}

const server = http.createServer((req, res) => {
  const token = bearer(req);

  if (LEGACY_TOKEN && token && token === LEGACY_TOKEN) {
    return sendJson(res, 401, {
      error: "legacy_static_token_not_allowed",
      error_description: "Public MCP clients must authenticate through OAuth."
    });
  }

  const headers = { ...req.headers, host: `${UPSTREAM_HOST}:${UPSTREAM_PORT}` };
  delete headers["content-length"];

  const upstream = http.request({
    hostname: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    method: req.method,
    path: req.url,
    headers
  }, upstreamRes => {
    res.writeHead(upstreamRes.statusCode || 502, upstreamRes.headers);
    upstreamRes.pipe(res);
  });

  upstream.on("error", err => {
    if (!res.headersSent) {
      sendJson(res, 502, { error: "mcp_upstream_unavailable" });
    } else {
      res.destroy(err);
    }
  });

  req.pipe(upstream);
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  console.log(`[vodia-public-mcp-gateway] listening on http://${LISTEN_HOST}:${LISTEN_PORT}, upstream http://${UPSTREAM_HOST}:${UPSTREAM_PORT}`);
});
