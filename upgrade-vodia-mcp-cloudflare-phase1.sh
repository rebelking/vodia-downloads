#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="/opt/vodia-mcp"
SERVICE="vodia-mcp"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/opt/vodia-mcp.before-cloudflare-phase1-${STAMP}"

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

for required in "$APP_DIR/package.json" "$APP_DIR/http.js" "$APP_DIR/public/index.html" "$APP_DIR/public/app.js"; do
  [[ -f "$required" ]] || { echo "Missing required file: $required"; exit 1; }
done

VERSION="$(node -p "require('$APP_DIR/package.json').version")"
[[ "$VERSION" == "0.14.7" || "$VERSION" == "0.14.8" ]] || {
  echo "Cloudflare Phase 1 expects Vodia MCP 0.14.7 or 0.14.8; found ${VERSION:-unknown}."
  exit 1
}

grep -q 'app.get("/api/status", requireAdmin' "$APP_DIR/http.js" || {
  echo "Expected Control Center route anchor was not found in http.js. No changes made."
  exit 1
}
grep -q 'OAuth users' "$APP_DIR/public/index.html" || {
  echo "Expected OAuth users UI anchor was not found. No changes made."
  exit 1
}
grep -q '\$("#dashboard").classList.remove("hidden")' "$APP_DIR/public/app.js" || {
  echo "Expected dashboard JavaScript anchor was not found. No changes made."
  exit 1
}

if grep -q 'cloudflare-integration.js' "$APP_DIR/http.js"; then
  echo "Cloudflare Phase 1 already appears installed. Exiting without changes."
  exit 0
fi

echo "[1/7] Backing up current application to $BACKUP_DIR"
cp -a "$APP_DIR" "$BACKUP_DIR"

rollback() {
  local rc=$?
  echo "Cloudflare Phase 1 failed; restoring $BACKUP_DIR"
  systemctl stop "$SERVICE" 2>/dev/null || true
  rm -rf "$APP_DIR"
  cp -a "$BACKUP_DIR" "$APP_DIR"
  systemctl restart "$SERVICE" 2>/dev/null || true
  exit "$rc"
}
trap rollback ERR

cat > "$APP_DIR/cloudflare-integration.js" <<'EOF'
import { createCipheriv, createDecipheriv, createHash, randomBytes } from "node:crypto";
import { DatabaseSync } from "node:sqlite";

const API_BASE = "https://api.cloudflare.com/client/v4";

function cleanDomain(value) {
  const domain = String(value || "").trim().toLowerCase().replace(/\.$/, "");
  if (!domain || domain.length > 253 || !/^[a-z0-9.-]+$/.test(domain) || !domain.includes(".")) {
    throw new Error("Enter a valid DNS zone such as example.com.");
  }
  return domain;
}

function requireSecret() {
  const secret = String(process.env.SESSION_SECRET || "");
  if (secret.length < 24) throw new Error("SESSION_SECRET is required for encrypted integration credentials.");
  return createHash("sha256").update(`vodia-mcp:integrations:${secret}`).digest();
}

function seal(value) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", requireSecret(), iv);
  const encrypted = Buffer.concat([cipher.update(String(value), "utf8"), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, encrypted].map((part) => part.toString("base64url")).join(".");
}

function open(value) {
  const [ivText, tagText, cipherText] = String(value || "").split(".");
  if (!ivText || !tagText || !cipherText) throw new Error("Stored Cloudflare credential is invalid.");
  const decipher = createDecipheriv("aes-256-gcm", requireSecret(), Buffer.from(ivText, "base64url"));
  decipher.setAuthTag(Buffer.from(tagText, "base64url"));
  return Buffer.concat([
    decipher.update(Buffer.from(cipherText, "base64url")),
    decipher.final(),
  ]).toString("utf8");
}

function db() {
  const database = new DatabaseSync(String(process.env.DB_PATH || "/var/lib/vodia-mcp/auth.db"));
  database.exec(`
    CREATE TABLE IF NOT EXISTS integrations (
      provider TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      config_json TEXT NOT NULL,
      secret_blob TEXT NOT NULL,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )
  `);
  return database;
}

async function cf(path, token) {
  const response = await fetch(`${API_BASE}${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/json" },
    signal: AbortSignal.timeout(12000),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body.success === false) {
    const message = body?.errors?.map((item) => item.message).filter(Boolean).join("; ") || `Cloudflare returned HTTP ${response.status}`;
    const error = new Error(message);
    error.status = response.status;
    throw error;
  }
  return body;
}

export async function testCloudflareConnection({ domain, apiToken }) {
  const zoneName = cleanDomain(domain);
  const token = String(apiToken || "").trim();
  if (!token) throw new Error("Cloudflare API token is required.");

  const verification = await cf("/user/tokens/verify", token);
  const zoneQuery = new URLSearchParams({ name: zoneName, status: "active", per_page: "20" });
  const zones = await cf(`/zones?${zoneQuery}`, token);
  const zone = (zones.result || []).find((item) => String(item.name || "").toLowerCase() === zoneName);
  if (!zone) throw new Error(`Cloudflare token is valid, but zone ${zoneName} was not found or is outside the token scope.`);

  const records = await cf(`/zones/${encodeURIComponent(zone.id)}/dns_records?per_page=5`, token);
  return {
    provider: "cloudflare",
    connected: true,
    tokenStatus: verification?.result?.status || "active",
    domain: zone.name,
    zoneId: zone.id,
    zoneStatus: zone.status,
    accountName: zone?.account?.name || null,
    permissions: {
      zoneRead: true,
      dnsRead: true,
      dnsWrite: "not_tested",
    },
    sampleRecordCount: Array.isArray(records.result) ? records.result.length : 0,
    note: "DNS Write is intentionally not probed because Phase 1 performs no Cloudflare writes.",
  };
}

export async function saveCloudflareIntegration({ domain, apiToken }) {
  const readiness = await testCloudflareConnection({ domain, apiToken });
  const database = db();
  const now = Math.floor(Date.now() / 1000);
  const config = JSON.stringify({ domain: readiness.domain, zoneId: readiness.zoneId, accountName: readiness.accountName });
  const secretBlob = seal(String(apiToken).trim());
  database.prepare(`
    INSERT INTO integrations(provider, display_name, config_json, secret_blob, created_at, updated_at)
    VALUES('cloudflare', 'Cloudflare', ?, ?, ?, ?)
    ON CONFLICT(provider) DO UPDATE SET
      display_name=excluded.display_name,
      config_json=excluded.config_json,
      secret_blob=excluded.secret_blob,
      updated_at=excluded.updated_at
  `).run(config, secretBlob, now, now);
  database.close();
  return readiness;
}

export function getCloudflareIntegrationStatus() {
  const database = db();
  const row = database.prepare("SELECT config_json, updated_at FROM integrations WHERE provider='cloudflare'").get();
  database.close();
  if (!row) return { provider: "cloudflare", configured: false, connected: false };
  const config = JSON.parse(row.config_json || "{}");
  return {
    provider: "cloudflare",
    configured: true,
    connected: null,
    domain: config.domain || null,
    zoneId: config.zoneId || null,
    accountName: config.accountName || null,
    updatedAt: row.updated_at,
    credentialStored: true,
  };
}

export async function checkSavedCloudflareConnection() {
  const database = db();
  const row = database.prepare("SELECT config_json, secret_blob, updated_at FROM integrations WHERE provider='cloudflare'").get();
  database.close();
  if (!row) return { provider: "cloudflare", configured: false, connected: false };
  const config = JSON.parse(row.config_json || "{}");
  const readiness = await testCloudflareConnection({ domain: config.domain, apiToken: open(row.secret_blob) });
  return { ...readiness, configured: true, updatedAt: row.updated_at };
}

export async function listSavedCloudflareDnsRecords({ name = "", type = "" } = {}) {
  const database = db();
  const row = database.prepare("SELECT config_json, secret_blob FROM integrations WHERE provider='cloudflare'").get();
  database.close();
  if (!row) throw new Error("Cloudflare is not configured.");
  const config = JSON.parse(row.config_json || "{}");
  const token = open(row.secret_blob);
  const query = new URLSearchParams({ per_page: "100" });
  if (name) query.set("name", String(name).trim().toLowerCase());
  if (type) query.set("type", String(type).trim().toUpperCase());
  const result = await cf(`/zones/${encodeURIComponent(config.zoneId)}/dns_records?${query}`, token);
  return {
    provider: "cloudflare",
    domain: config.domain,
    records: (result.result || []).map((record) => ({
      id: record.id,
      type: record.type,
      name: record.name,
      content: record.content,
      ttl: record.ttl,
      proxied: record.proxied ?? null,
      comment: record.comment || null,
    })),
  };
}

export function disconnectCloudflareIntegration() {
  const database = db();
  const result = database.prepare("DELETE FROM integrations WHERE provider='cloudflare'").run();
  database.close();
  return { provider: "cloudflare", configured: false, disconnected: Number(result.changes || 0) > 0 };
}
EOF

echo "[2/7] Patching authenticated Control Center API routes"
python3 - "$APP_DIR/http.js" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
imp = '''import {\n  checkSavedCloudflareConnection,\n  disconnectCloudflareIntegration,\n  getCloudflareIntegrationStatus,\n  listSavedCloudflareDnsRecords,\n  saveCloudflareIntegration,\n  testCloudflareConnection,\n} from "./cloudflare-integration.js";\n'''
if 'from "./cloudflare-integration.js"' not in s:
    s = imp + s
anchor = 'app.get("/api/status", requireAdmin, async (_req, res) => {'
routes = r'''app.get("/api/integrations/cloudflare", requireAdmin, (_req, res) => {
  try { res.json(getCloudflareIntegrationStatus()); }
  catch (error) { res.status(500).json({ error: error.message }); }
});

app.post("/api/integrations/cloudflare/test", requireAdmin, async (req, res) => {
  try {
    const result = await testCloudflareConnection({ domain: req.body?.domain, apiToken: req.body?.apiToken });
    audit("cloudflare_integration_tested", { actor: adminActor, domain: result.domain, connected: true });
    res.json(result);
  } catch (error) {
    audit("cloudflare_integration_test_failed", { actor: adminActor, domain: String(req.body?.domain || ""), error: error.message });
    res.status(400).json({ error: error.message });
  }
});

app.post("/api/integrations/cloudflare", requireAdmin, async (req, res) => {
  try {
    const result = await saveCloudflareIntegration({ domain: req.body?.domain, apiToken: req.body?.apiToken });
    audit("cloudflare_integration_saved", { actor: adminActor, domain: result.domain, zone_id: result.zoneId });
    res.json({ ...result, credentialStored: true });
  } catch (error) {
    res.status(400).json({ error: error.message });
  }
});

app.post("/api/integrations/cloudflare/check", requireAdmin, async (_req, res) => {
  try { res.json(await checkSavedCloudflareConnection()); }
  catch (error) { res.status(400).json({ error: error.message }); }
});

app.get("/api/integrations/cloudflare/dns", requireAdmin, async (req, res) => {
  try { res.json(await listSavedCloudflareDnsRecords({ name: req.query.name, type: req.query.type })); }
  catch (error) { res.status(400).json({ error: error.message }); }
});

app.delete("/api/integrations/cloudflare", requireAdmin, (_req, res) => {
  try {
    const result = disconnectCloudflareIntegration();
    audit("cloudflare_integration_disconnected", { actor: adminActor });
    res.json(result);
  } catch (error) { res.status(500).json({ error: error.message }); }
});

'''
if '/api/integrations/cloudflare' not in s:
    if anchor not in s:
        raise SystemExit('http.js API route anchor missing')
    s = s.replace(anchor, routes + anchor, 1)
p.write_text(s)
PY

echo "[3/7] Adding Integrations card to Control Center"
python3 - "$APP_DIR/public/index.html" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
if 'id="cloudflareForm"' in s:
    raise SystemExit(0)
needle='<p class="eyebrow">IDENTITY</p><h2>OAuth users</h2>'
pos=s.find(needle)
if pos < 0: raise SystemExit('OAuth users UI anchor missing')
start=s.rfind('<section', 0, pos)
if start < 0: raise SystemExit('OAuth users section start missing')
card='''        <section class="card" id="integrationsCard">\n          <div class="card-head"><div><p class="eyebrow">INTEGRATIONS</p><h2>Cloudflare DNS</h2></div><span id="cloudflareBadge" class="badge blocked">Not configured</span></div>\n          <p class="muted">Connect a customer-owned Cloudflare zone without exposing the API token to MCP clients. Phase 1 is read-only after setup.</p>\n          <form id="cloudflareForm" class="form-grid">\n            <input id="cloudflareDomain" placeholder="example.com" autocomplete="off" required>\n            <input id="cloudflareToken" type="password" placeholder="Cloudflare API token" autocomplete="new-password" required>\n            <button id="cloudflareTest" type="button" class="secondary">Test connection</button>\n            <button id="cloudflareSave" type="submit">Save integration</button>\n            <button id="cloudflareCheck" type="button" class="secondary">Check saved connection</button>\n            <button id="cloudflareDisconnect" type="button" class="secondary">Disconnect</button>\n          </form>\n          <p id="cloudflareError" class="error"></p>\n          <dl id="cloudflareDetails" class="kv"></dl>\n        </section>\n\n'''
s=s[:start]+card+s[start:]
p.write_text(s)
PY

echo "[4/7] Wiring Cloudflare UI behavior"
cat >> "$APP_DIR/public/app.js" <<'EOF'

// Cloudflare integration — Phase 1
async function refreshCloudflare() {
  const status = await api("/api/integrations/cloudflare").catch((error) => ({ configured: false, error: error.message }));
  const badge = $("#cloudflareBadge");
  const details = $("#cloudflareDetails");
  if (!badge || !details) return;
  badge.textContent = status.configured ? "Configured" : "Not configured";
  badge.classList.toggle("blocked", !status.configured);
  $("#cloudflareDomain").value = status.domain || $("#cloudflareDomain").value || "";
  $("#cloudflareToken").value = "";
  $("#cloudflareToken").required = !status.configured;
  details.innerHTML = status.configured ? `
    <dt>Zone</dt><dd>${escapeHtml(status.domain || "Unknown")}</dd>
    <dt>Zone ID</dt><dd>${escapeHtml(status.zoneId || "Discovered automatically")}</dd>
    <dt>Credential</dt><dd>Stored encrypted server-side</dd>
    <dt>Last updated</dt><dd>${status.updatedAt ? escapeHtml(new Date(status.updatedAt * 1000).toLocaleString()) : "Unknown"}</dd>` : "";
}

async function cloudflarePayload() {
  return { domain: $("#cloudflareDomain").value.trim(), apiToken: $("#cloudflareToken").value.trim() };
}

$("#cloudflareTest")?.addEventListener("click", async () => {
  $("#cloudflareError").textContent = "";
  try {
    const payload = await cloudflarePayload();
    if (!payload.apiToken) throw new Error("Enter the Cloudflare API token to test a new credential.");
    const result = await api("/api/integrations/cloudflare/test", { method: "POST", body: payload });
    $("#cloudflareBadge").textContent = "Connection passed";
    $("#cloudflareBadge").classList.remove("blocked");
    $("#cloudflareDetails").innerHTML = `
      <dt>Zone</dt><dd>${escapeHtml(result.domain)}</dd>
      <dt>Zone status</dt><dd>${escapeHtml(result.zoneStatus || "Unknown")}</dd>
      <dt>Zone read</dt><dd>Pass</dd>
      <dt>DNS read</dt><dd>Pass</dd>
      <dt>DNS write</dt><dd>Not tested — Phase 1 performs no writes</dd>`;
  } catch (error) { $("#cloudflareError").textContent = error.message; }
});

$("#cloudflareForm")?.addEventListener("submit", async (event) => {
  event.preventDefault();
  $("#cloudflareError").textContent = "";
  try {
    const payload = await cloudflarePayload();
    if (!payload.apiToken) throw new Error("Enter the Cloudflare API token before saving or replacing the credential.");
    await api("/api/integrations/cloudflare", { method: "POST", body: payload });
    await refreshCloudflare();
  } catch (error) { $("#cloudflareError").textContent = error.message; }
});

$("#cloudflareCheck")?.addEventListener("click", async () => {
  $("#cloudflareError").textContent = "";
  try {
    const result = await api("/api/integrations/cloudflare/check", { method: "POST", body: {} });
    $("#cloudflareBadge").textContent = result.connected ? "Connected" : "Unavailable";
    $("#cloudflareBadge").classList.toggle("blocked", !result.connected);
    $("#cloudflareDetails").innerHTML = `
      <dt>Zone</dt><dd>${escapeHtml(result.domain || "Unknown")}</dd>
      <dt>Token</dt><dd>${escapeHtml(result.tokenStatus || "Unknown")}</dd>
      <dt>Zone read</dt><dd>Pass</dd>
      <dt>DNS read</dt><dd>Pass</dd>
      <dt>DNS write</dt><dd>Not tested</dd>`;
  } catch (error) { $("#cloudflareError").textContent = error.message; }
});

$("#cloudflareDisconnect")?.addEventListener("click", async () => {
  $("#cloudflareError").textContent = "";
  try {
    await api("/api/integrations/cloudflare", { method: "DELETE" });
    $("#cloudflareDomain").value = "";
    await refreshCloudflare();
  } catch (error) { $("#cloudflareError").textContent = error.message; }
});
EOF

python3 - "$APP_DIR/public/app.js" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
needle='$("#dashboard").classList.remove("hidden");'
replacement='await refreshCloudflare();\n    ' + needle
# Only patch the original dashboard path, not any newly appended occurrence.
if 'await refreshCloudflare();\n    ' + needle not in s:
    if needle not in s: raise SystemExit('dashboard anchor missing')
    s=s.replace(needle, replacement, 1)
p.write_text(s)
PY

echo "[5/7] Validating JavaScript and integration boundaries"
node --check "$APP_DIR/cloudflare-integration.js"
node --check "$APP_DIR/http.js"
node --check "$APP_DIR/public/app.js"
grep -q '/api/integrations/cloudflare' "$APP_DIR/http.js"
grep -q 'cloudflareForm' "$APP_DIR/public/index.html"
if grep -R --line-number -E 'apiToken[^\n]*(console\.log|audit\()|CLOUDFLARE_API_TOKEN=' "$APP_DIR/cloudflare-integration.js" "$APP_DIR/http.js" "$APP_DIR/public/app.js"; then
  echo "Potential Cloudflare secret logging/persistence pattern detected."
  exit 1
fi

echo "[6/7] Restarting Vodia MCP"
systemctl restart "$SERVICE"
HEALTH=""
for _ in {1..25}; do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ -n "$HEALTH" ]] || { journalctl -u "$SERVICE" -n 60 --no-pager || true; exit 1; }
echo "$HEALTH"

echo "[7/7] Cloudflare Phase 1 installed"
echo "Control Center: open your existing /admin/ URL and look for Integrations → Cloudflare DNS."
echo "Backup retained at: $BACKUP_DIR"
echo "Phase 1 supports connection testing, encrypted credential storage, zone discovery, DNS reads, connection re-check, and disconnect."
echo "No Cloudflare DNS writes are implemented in Phase 1."
trap - ERR
