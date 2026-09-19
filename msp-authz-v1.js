import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID, createHash } from "node:crypto";

const DB_PATH = process.env.VODIA_MSP_AUTHZ_DB || "/var/lib/vodia-mcp/msp-authz.db";
const BOOTSTRAP = new Set(
  String(process.env.VODIA_MSP_BOOTSTRAP_SUBJECTS || "")
    .split(",").map(x => x.trim()).filter(Boolean)
);

mkdirSync(dirname(DB_PATH), { recursive: true, mode: 0o700 });
const db = new DatabaseSync(DB_PATH);
db.exec(`
  PRAGMA journal_mode=WAL;
  PRAGMA foreign_keys=ON;
  CREATE TABLE IF NOT EXISTS organizations(
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS customers(
    id TEXT PRIMARY KEY,
    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS memberships(
    subject TEXT NOT NULL,
    organization_id TEXT NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    customer_id TEXT REFERENCES customers(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(subject, organization_id, customer_id)
  );
  CREATE TABLE IF NOT EXISTS commercial_audit(
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL,
    organization_id TEXT,
    customer_id TEXT,
    action TEXT NOT NULL,
    resource TEXT,
    details_json TEXT,
    created_at TEXT NOT NULL
  );
`);

const now = () => new Date().toISOString();

function safeString(v) {
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

export function oauthIdentity(extra) {
  const a = extra?.authInfo || {};
  const e = a.extra || {};
  const claims = e.claims || {};
  const user = e.user || {};
  const candidates = [
    ["sub", claims.sub],
    ["userId", e.userId],
    ["user_id", e.user_id],
    ["user.id", user.id],
    ["email", claims.email],
    ["user.email", user.email],
    ["email", e.email],
  ].map(([kind, value]) => [kind, safeString(value)]).filter(([,value]) => value);

  const chosen = candidates[0] || null;
  return {
    authenticated: Boolean(a && (a.token || a.clientId || candidates.length)),
    subject: chosen ? `${chosen[0]}:${chosen[1].toLowerCase()}` : null,
    subjectKind: chosen?.[0] || null,
    clientId: safeString(a.clientId),
    scopes: Array.isArray(a.scopes) ? a.scopes : [],
    candidates: candidates.map(([kind, value]) => ({ kind, value: kind.includes("email") ? value.toLowerCase() : value }))
  };
}

function requireOAuthSubject(extra) {
  const identity = oauthIdentity(extra);
  if (!identity.authenticated) throw new Error("OAUTH_REQUIRED: authenticate with the Vodia MCP OAuth flow.");
  if (!identity.subject) {
    throw new Error("OAUTH_USER_IDENTITY_REQUIRED: OAuth succeeded but no stable user subject/email claim was exposed to MCP tools.");
  }
  return identity;
}

function membershipRows(subject) {
  return db.prepare(`
    SELECT m.subject,m.organization_id AS organizationId,m.customer_id AS customerId,
           m.role,o.name AS organizationName,c.name AS customerName,c.status AS customerStatus
      FROM memberships m
      JOIN organizations o ON o.id=m.organization_id
 LEFT JOIN customers c ON c.id=m.customer_id
     WHERE m.subject=?
     ORDER BY o.name,c.name
  `).all(subject);
}

function isBootstrap(subject) {
  return BOOTSTRAP.has(subject);
}

export function requireMspAdmin(extra) {
  const identity = requireOAuthSubject(extra);
  const organizationCount = Number(db.prepare("SELECT COUNT(*) AS n FROM organizations").get()?.n || 0);
  if (organizationCount === 0) return { identity, bootstrap: true, firstOrganizationClaim: true };
  if (isBootstrap(identity.subject)) return { identity, bootstrap: true };
  const row = db.prepare("SELECT 1 FROM memberships WHERE subject=? AND role='MSP_ADMIN' LIMIT 1").get(identity.subject);
  if (!row) throw new Error("MSP_ADMIN_REQUIRED: this OAuth identity is not an MSP administrator.");
  return { identity, bootstrap: false };
}

export function requireCustomerAccess(extra, customerId, allowedRoles = ["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"]) {
  const identity = requireOAuthSubject(extra);
  const customer = db.prepare(`
    SELECT c.id,c.name,c.status,c.organization_id AS organizationId,o.name AS organizationName
      FROM customers c JOIN organizations o ON o.id=c.organization_id
     WHERE c.id=?
  `).get(customerId);
  if (!customer || customer.status !== "active") throw new Error("CUSTOMER_NOT_FOUND_OR_INACTIVE");

  if (isBootstrap(identity.subject)) return { identity, customer, role: "MSP_ADMIN", bootstrap: true };

  const rows = db.prepare(`
    SELECT role,customer_id AS customerId
      FROM memberships
     WHERE subject=? AND organization_id=?
       AND (customer_id IS NULL OR customer_id=?)
  `).all(identity.subject, customer.organizationId, customerId);

  const priority = ["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"];
  const effective = priority.find(role => rows.some(r => r.role === role));
  if (!effective || !allowedRoles.includes(effective)) throw new Error("CUSTOMER_ACCESS_DENIED");
  return { identity, customer, role: effective, bootstrap: false };
}

export function recordCommercialAudit(extra, { customerId, action, resource, details = {} }) {
  const access = requireCustomerAccess(extra, customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
  const id = randomUUID();
  const detailsSafe = { ...details };
  for (const k of Object.keys(detailsSafe)) {
    if (/token|secret|password|externalId/i.test(k)) detailsSafe[k] = "[REDACTED]";
  }
  db.prepare(`
    INSERT INTO commercial_audit(id,subject,organization_id,customer_id,action,resource,details_json,created_at)
    VALUES(?,?,?,?,?,?,?,?)
  `).run(id, access.identity.subject, access.customer.organizationId, customerId, action, resource || null, JSON.stringify(detailsSafe), now());
  return { id, subject: access.identity.subject, organizationId: access.customer.organizationId, customerId };
}

export function registerMspAuthzTools(server, ctx) {
  const { z, toolOutputSchema, scopedAudit, scopedSuccess, failure } = ctx;

  server.registerTool("msp_get_my_identity", {
    title: "Get my Vodia MCP identity",
    description: "Shows the stable OAuth identity claims visible to the MCP and current MSP/customer memberships. Never returns access tokens.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async (_input, extra) => {
    try {
      const identity = oauthIdentity(extra);
      return scopedSuccess({
        identity: { ...identity, token: undefined },
        bootstrapAdmin: Boolean(identity.subject && isBootstrap(identity.subject)),
        memberships: identity.subject ? membershipRows(identity.subject) : [],
        changesMade: false
      }, { operation: "MSP_IDENTITY_GET", readOnly: true }, identity.subject ? "OAuth identity resolved." : "OAuth identity is missing a stable user subject; review OAuth claim mapping.");
    } catch (error) { return failure(error, "MSP identity read"); }
  });

  server.registerTool("msp_create_organization", {
    title: "Create MSP organization",
    description: "Creates an MSP organization. Requires an OAuth-authenticated bootstrap/MSP administrator.",
    inputSchema: { name: z.string().min(2).max(160) },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, async ({ name }, extra) => {
    try {
      const { identity } = requireMspAdmin(extra);
      const id = randomUUID();
      db.prepare("INSERT INTO organizations(id,name,created_at) VALUES(?,?,?)").run(id, name.trim(), now());
      db.prepare("INSERT INTO memberships(subject,organization_id,customer_id,role,created_at) VALUES(?,?,?,?,?)")
        .run(identity.subject, id, null, "MSP_ADMIN", now());
      scopedAudit("msp_create_organization", { organizationId: id, subject: identity.subject });
      return scopedSuccess({ organization: { id, name: name.trim() }, changesMade: true }, { operation: "MSP_ORGANIZATION_CREATE", readOnly: false }, "MSP organization created.");
    } catch (error) { return failure(error, "MSP organization creation"); }
  });

  server.registerTool("msp_create_customer", {
    title: "Create MSP customer",
    description: "Creates a customer under an MSP organization. Requires MSP administrator access.",
    inputSchema: { organizationId: z.string().uuid(), name: z.string().min(2).max(160) },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, async ({ organizationId, name }, extra) => {
    try {
      const { identity } = requireMspAdmin(extra);
      const org = db.prepare("SELECT id,name FROM organizations WHERE id=?").get(organizationId);
      if (!org) throw new Error("ORGANIZATION_NOT_FOUND");
      if (!isBootstrap(identity.subject)) {
        const ok = db.prepare("SELECT 1 FROM memberships WHERE subject=? AND organization_id=? AND role='MSP_ADMIN'").get(identity.subject, organizationId);
        if (!ok) throw new Error("ORGANIZATION_ACCESS_DENIED");
      }
      const id = randomUUID();
      db.prepare("INSERT INTO customers(id,organization_id,name,status,created_at) VALUES(?,?,?,?,?)")
        .run(id, organizationId, name.trim(), "active", now());
      scopedAudit("msp_create_customer", { organizationId, customerId: id, subject: identity.subject });
      return scopedSuccess({ customer: { id, organizationId, name: name.trim(), status: "active" }, changesMade: true }, { operation: "MSP_CUSTOMER_CREATE", readOnly: false }, "MSP customer created.");
    } catch (error) { return failure(error, "MSP customer creation"); }
  });

  server.registerTool("msp_grant_membership", {
    title: "Grant MSP/customer access",
    description: "Grants a stable OAuth subject access to an organization or customer. Requires MSP administrator access.",
    inputSchema: {
      subject: z.string().min(3),
      organizationId: z.string().uuid(),
      customerId: z.string().uuid().optional(),
      role: z.enum(["MSP_ADMIN","CUSTOMER_ADMIN","OPERATOR","READ_ONLY"])
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false }
  }, async ({ subject, organizationId, customerId, role }, extra) => {
    try {
      const admin = requireMspAdmin(extra);
      if (role === "MSP_ADMIN" && customerId) throw new Error("INVALID_MEMBERSHIP: MSP_ADMIN must be organization-wide.");
      if (role !== "MSP_ADMIN" && !customerId) throw new Error("INVALID_MEMBERSHIP: customer-scoped roles require customerId.");
      const org = db.prepare("SELECT id FROM organizations WHERE id=?").get(organizationId);
      if (!org) throw new Error("ORGANIZATION_NOT_FOUND");
      if (customerId) {
        const c = db.prepare("SELECT id FROM customers WHERE id=? AND organization_id=?").get(customerId, organizationId);
        if (!c) throw new Error("CUSTOMER_NOT_FOUND");
      }
      db.prepare(`
        INSERT INTO memberships(subject,organization_id,customer_id,role,created_at)
        VALUES(?,?,?,?,?)
        ON CONFLICT(subject,organization_id,customer_id) DO UPDATE SET role=excluded.role
      `).run(subject.trim(), organizationId, customerId || null, role, now());
      scopedAudit("msp_grant_membership", { organizationId, customerId: customerId || null, role, by: admin.identity.subject });
      return scopedSuccess({ subject: subject.trim(), organizationId, customerId: customerId || null, role, changesMade: true }, { operation: "MSP_MEMBERSHIP_GRANT", readOnly: false }, "MSP/customer access granted.");
    } catch (error) { return failure(error, "MSP membership grant"); }
  });

  server.registerTool("msp_list_customers", {
    title: "List my MSP customers",
    description: "Lists only customers the authenticated OAuth identity may access.",
    inputSchema: {},
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async (_input, extra) => {
    try {
      const identity = requireOAuthSubject(extra);
      let customers;
      if (isBootstrap(identity.subject)) {
        customers = db.prepare(`
          SELECT c.id,c.name,c.status,c.organization_id AS organizationId,o.name AS organizationName
          FROM customers c JOIN organizations o ON o.id=c.organization_id ORDER BY o.name,c.name
        `).all();
      } else {
        customers = db.prepare(`
          SELECT DISTINCT c.id,c.name,c.status,c.organization_id AS organizationId,o.name AS organizationName
          FROM customers c JOIN organizations o ON o.id=c.organization_id
          JOIN memberships m ON m.organization_id=c.organization_id
          WHERE m.subject=? AND (m.customer_id IS NULL OR m.customer_id=c.id)
          ORDER BY o.name,c.name
        `).all(identity.subject);
      }
      return scopedSuccess({ customers, changesMade: false }, { operation: "MSP_CUSTOMERS_LIST", readOnly: true }, `Found ${customers.length} accessible customer(s).`);
    } catch (error) { return failure(error, "MSP customer list"); }
  });

  server.registerTool("msp_get_commercial_audit", {
    title: "Get customer commercial audit",
    description: "Returns Marketplace/commercial approval audit entries for one customer. Requires MSP or customer administrator access.",
    inputSchema: { customerId: z.string().uuid(), limit: z.number().int().min(1).max(200).default(50) },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false }
  }, async ({ customerId, limit }, extra) => {
    try {
      requireCustomerAccess(extra, customerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
      const rows = db.prepare(`
        SELECT id,subject,organization_id AS organizationId,customer_id AS customerId,
               action,resource,details_json AS detailsJson,created_at AS createdAt
        FROM commercial_audit WHERE customer_id=? ORDER BY created_at DESC LIMIT ?
      `).all(customerId, limit).map(r => ({ ...r, details: r.detailsJson ? JSON.parse(r.detailsJson) : {}, detailsJson: undefined }));
      return scopedSuccess({ entries: rows, changesMade: false }, { operation: "MSP_COMMERCIAL_AUDIT_GET", readOnly: true }, `Loaded ${rows.length} audit entrie(s).`);
    } catch (error) { return failure(error, "MSP commercial audit read"); }
  });
}
