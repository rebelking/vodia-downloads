#!/usr/bin/env bash
# Vodia MCP v0.14.9.51 — guarded MSP organization/customer deletion
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
AUTHZ="$APP/msp-authz-v1.js"
CONNECTIONS="$APP/msp-customer-connections-v1.js"
VERSION="$APP/version.js"
FROM_VER="0.14.9.50"
TO_VER="0.14.9.51"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="${VODIA_MCP_BACKUP_ROOT:-/var/backups}/vodia-mcp-v${TO_VER}-org-customer-delete-$STAMP"
TMP_DIR="$(mktemp -d)"
TMP_AUTHZ="$TMP_DIR/msp-authz-v1.js"
TMP_CONNECTIONS="$TMP_DIR/msp-customer-connections-v1.js"
TMP_VERSION="$TMP_DIR/version.js"
HEALTH="$TMP_DIR/health.json"
INSTALLED=0

trap 'rm -rf "$TMP_DIR"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

rollback() {
  local rc="${1:-1}"
  trap - ERR
  echo "Activation failed; restoring backup: $BACKUP_DIR" >&2
  cp -a "$BACKUP_DIR/msp-authz-v1.js" "$AUTHZ" || true
  cp -a "$BACKUP_DIR/msp-customer-connections-v1.js" "$CONNECTIONS" || true
  cp -a "$BACKUP_DIR/version.js" "$VERSION" || true
  systemctl restart "$SERVICE" 2>/dev/null || true
  echo "ROLLED BACK" >&2
  exit "$rc"
}

[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in python3 node grep install systemctl curl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required"
done
for f in "$AUTHZ" "$CONNECTIONS" "$VERSION"; do
  [[ -f "$f" ]] || fail "missing $f"
done

grep -Eq "CONNECTOR_VERSION[[:space:]]*=[[:space:]]*[\"']${FROM_VER//./\\.}[\"']" "$VERSION" \
  || fail "expected installed base v${FROM_VER}"

echo "=== Vodia MCP v${TO_VER} — guarded organization/customer deletion ==="

echo "[1/8] Stage current files — NO LIVE CHANGES"
cp -a "$AUTHZ" "$TMP_AUTHZ"
cp -a "$CONNECTIONS" "$TMP_CONNECTIONS"
cp -a "$VERSION" "$TMP_VERSION"

echo "[2/8] Patch MSP authorization/database helpers — NO LIVE CHANGES"
python3 - "$TMP_AUTHZ" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

marker = "v0.14.9.51 guarded organization/customer deletion"
if marker in s:
    raise SystemExit("authz file already contains v0.14.9.51 patch marker")

anchor = "export function requireCustomerAccess(extra, customerId, allowedRoles = ["
pos = s.find(anchor)
if pos < 0:
    raise SystemExit("requireCustomerAccess anchor not found")

block = r'''
// v0.14.9.51 guarded organization/customer deletion
export function requireOrganizationAdmin(extra, organizationId) {
  const admin = requireMspAdmin(extra);
  const org = db.prepare("SELECT id,name,created_at AS createdAt FROM organizations WHERE id=?").get(organizationId);
  if (!org) throw new Error("ORGANIZATION_NOT_FOUND");

  if (!isBootstrap(admin.identity.subject)) {
    const ok = db.prepare(`
      SELECT 1 FROM memberships
       WHERE subject=? AND organization_id=? AND customer_id IS NULL AND role='MSP_ADMIN'
       LIMIT 1
    `).get(admin.identity.subject, organizationId);
    if (!ok) throw new Error("ORGANIZATION_ACCESS_DENIED");
  }
  return { ...admin, organization: org };
}

export function getCustomerDeletePreview(extra, customerId) {
  const access = requireCustomerAccess(extra, customerId, ["MSP_ADMIN"]);
  const customer = db.prepare(`
    SELECT c.id,c.name,c.status,c.organization_id AS organizationId,o.name AS organizationName,
           c.created_at AS createdAt
      FROM customers c JOIN organizations o ON o.id=c.organization_id
     WHERE c.id=?
  `).get(customerId);
  if (!customer) throw new Error("CUSTOMER_NOT_FOUND");

  const membershipCount = Number(db.prepare(
    "SELECT COUNT(*) AS n FROM memberships WHERE customer_id=?"
  ).get(customerId)?.n || 0);

  const auditCount = Number(db.prepare(
    "SELECT COUNT(*) AS n FROM commercial_audit WHERE customer_id=?"
  ).get(customerId)?.n || 0);

  return {
    customer,
    membershipCount,
    commercialAuditCount: auditCount,
    auditRetention: "Commercial audit rows are retained after deletion.",
    confirmation: `DELETE CUSTOMER ${customer.id}`,
    requestedBy: access.identity.subject
  };
}

export function getOrganizationDeletePreview(extra, organizationId) {
  const access = requireOrganizationAdmin(extra, organizationId);
  const organizationCount = Number(db.prepare("SELECT COUNT(*) AS n FROM organizations").get()?.n || 0);
  const customers = db.prepare(`
    SELECT id,name,status,created_at AS createdAt
      FROM customers
     WHERE organization_id=?
     ORDER BY name
  `).all(organizationId);

  const membershipCount = Number(db.prepare(
    "SELECT COUNT(*) AS n FROM memberships WHERE organization_id=?"
  ).get(organizationId)?.n || 0);

  const auditCount = Number(db.prepare(
    "SELECT COUNT(*) AS n FROM commercial_audit WHERE organization_id=?"
  ).get(organizationId)?.n || 0);

  return {
    organization: access.organization,
    organizationCount,
    customers,
    customerCount: customers.length,
    membershipCount,
    commercialAuditCount: auditCount,
    auditRetention: "Commercial audit rows are retained after deletion.",
    confirmation: `DELETE ORGANIZATION ${access.organization.id}`,
    requestedBy: access.identity.subject
  };
}

export function deleteCustomerRecord(extra, customerId) {
  const preview = getCustomerDeletePreview(extra, customerId);
  const out = db.prepare("DELETE FROM customers WHERE id=?").run(customerId);
  if (Number(out.changes || 0) !== 1) throw new Error("CUSTOMER_DELETE_FAILED");
  return preview;
}

export function deleteOrganizationRecord(extra, organizationId) {
  const preview = getOrganizationDeletePreview(extra, organizationId);
  if (preview.organizationCount <= 1) {
    throw new Error("LAST_ORGANIZATION_DELETE_BLOCKED: create another organization before deleting the final MSP organization.");
  }
  const out = db.prepare("DELETE FROM organizations WHERE id=?").run(organizationId);
  if (Number(out.changes || 0) !== 1) throw new Error("ORGANIZATION_DELETE_FAILED");
  return preview;
}

'''
s = s[:pos] + block + s[pos:]
p.write_text(s)
PY

echo "[3/8] Patch guarded MCP tools + encrypted AWS connection cleanup — NO LIVE CHANGES"
python3 - "$TMP_CONNECTIONS" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

marker = "v0.14.9.51 guarded deletion tools"
if marker in s:
    raise SystemExit("connection file already contains v0.14.9.51 patch marker")

old_import = 'import { requireCustomerAccess } from "./msp-authz-v1.js";'
new_import = '''import {
  requireCustomerAccess,
  getCustomerDeletePreview,
  getOrganizationDeletePreview,
  deleteCustomerRecord,
  deleteOrganizationRecord
} from "./msp-authz-v1.js";'''
if old_import not in s:
    raise SystemExit("msp-authz import anchor not found")
s = s.replace(old_import, new_import, 1)

func_anchor = "export function registerMspCustomerConnectionTools(server, ctx) {"
pos = s.find(func_anchor)
if pos < 0:
    raise SystemExit("registerMspCustomerConnectionTools anchor not found")

helpers = r'''
// v0.14.9.51 guarded deletion tools
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

'''
s = s[:pos] + helpers + s[pos:]

reg_anchor = '  server.registerTool("msp_get_customer_aws_connection", {'
reg_pos = s.find(reg_anchor, s.find(func_anchor))
if reg_pos < 0:
    raise SystemExit("tool registration anchor not found")

tools = r'''  server.registerTool("msp_plan_delete_customer", {
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
      if (confirmation !== preview.confirmation) {
        throw new Error(`CONFIRMATION_REQUIRED: exact phrase is ${preview.confirmation}`);
      }

      const awsConnection = scopedAwsDependency(customerId);
      if (awsConnection && !detachAwsConnection) {
        throw new Error("CUSTOMER_AWS_CONNECTION_DEPENDENCY: rerun with detachAwsConnection=true after reviewing the deletion plan.");
      }

      if (awsConnection) removed = removeScopedAwsConnections([customerId]);
      try {
        deleteCustomerRecord(extra, customerId);
      } catch (error) {
        restoreScopedAwsConnections(removed.backup);
        throw error;
      }

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
      if (confirmation !== preview.confirmation) {
        throw new Error(`CONFIRMATION_REQUIRED: exact phrase is ${preview.confirmation}`);
      }

      const customerIds = preview.customers.map(c => c.id);
      const awsDependencies = customerIds
        .map(id => ({ customerId: id, connection: scopedAwsDependency(id) }))
        .filter(x => x.connection);

      if (awsDependencies.length && !detachAwsConnections) {
        throw new Error(`ORGANIZATION_AWS_CONNECTION_DEPENDENCY: ${awsDependencies.length} saved AWS connection(s) exist; rerun with detachAwsConnections=true after reviewing the deletion plan.`);
      }

      if (awsDependencies.length) removed = removeScopedAwsConnections(customerIds);
      try {
        deleteOrganizationRecord(extra, organizationId);
      } catch (error) {
        restoreScopedAwsConnections(removed.backup);
        throw error;
      }

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

'''
s = s[:reg_pos] + tools + s[reg_pos:]
p.write_text(s)
PY

echo "[4/8] Patch version + validate staged JavaScript — NO LIVE CHANGES"
python3 - "$TMP_VERSION" "$TO_VER" <<'PY'
from pathlib import Path
import re, sys
p, to = Path(sys.argv[1]), sys.argv[2]
s = p.read_text()
n = re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])', r'\g<1>'+to+r'\2', s, count=1)
if n == s:
    raise SystemExit("CONNECTOR_VERSION missing")
p.write_text(n)
PY

node --check "$TMP_AUTHZ" >/dev/null
node --check "$TMP_CONNECTIONS" >/dev/null
node --check "$TMP_VERSION" >/dev/null

grep -q 'msp_plan_delete_customer' "$TMP_CONNECTIONS" || fail "customer plan tool missing"
grep -q 'msp_apply_delete_customer' "$TMP_CONNECTIONS" || fail "customer apply tool missing"
grep -q 'msp_plan_delete_organization' "$TMP_CONNECTIONS" || fail "organization plan tool missing"
grep -q 'msp_apply_delete_organization' "$TMP_CONNECTIONS" || fail "organization apply tool missing"
grep -q 'LAST_ORGANIZATION_DELETE_BLOCKED' "$TMP_AUTHZ" || fail "last-organization guard missing"
grep -q 'externalCloudResourcesDeleted: false' "$TMP_CONNECTIONS" || fail "external-resource safety indicator missing"
echo "PASS: staged syntax + deletion safety checks"

echo "[5/8] Backup live files"
mkdir -p "$BACKUP_DIR"
cp -a "$AUTHZ" "$BACKUP_DIR/msp-authz-v1.js"
cp -a "$CONNECTIONS" "$BACKUP_DIR/msp-customer-connections-v1.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
if [[ -f /var/lib/vodia-mcp/msp-authz.db ]]; then
  cp -a /var/lib/vodia-mcp/msp-authz.db "$BACKUP_DIR/msp-authz.db"
fi
if [[ -f /var/lib/vodia-mcp/msp-customer-connections.enc ]]; then
  cp -a /var/lib/vodia-mcp/msp-customer-connections.enc "$BACKUP_DIR/msp-customer-connections.enc"
fi
echo "PASS: $BACKUP_DIR"

echo "[6/8] Install staged files"
INSTALLED=1
trap 'rollback $?' ERR
install -o root -g root -m 0644 "$TMP_AUTHZ" "$AUTHZ"
install -o root -g root -m 0644 "$TMP_CONNECTIONS" "$CONNECTIONS"
install -o root -g root -m 0644 "$TMP_VERSION" "$VERSION"
echo "PASS"

echo "[7/8] Restart + health verification"
systemctl restart "$SERVICE"
for _ in {1..30}; do
  if curl -fsS -o "$HEALTH" http://127.0.0.1:3100/health 2>/dev/null && [[ -s "$HEALTH" ]]; then
    break
  fi
  sleep 1
done
[[ -s "$HEALTH" ]] || fail "MCP health endpoint did not recover"
grep -Eq "(^|[^0-9.])${TO_VER//./\\.}([^0-9.]|$)" "$HEALTH" \
  || fail "health endpoint did not report v${TO_VER}"
systemctl is-active --quiet "$SERVICE" || fail "$SERVICE is not active"
echo "PASS"
cat "$HEALTH"; echo

echo "[8/8] Complete"
trap - ERR
INSTALLED=0
echo "PASS: Vodia MCP v${TO_VER} installed"
echo
echo "New MCP tools:"
echo "  msp_plan_delete_customer"
echo "  msp_apply_delete_customer"
echo "  msp_plan_delete_organization"
echo "  msp_apply_delete_organization"
echo
echo "Safety behavior:"
echo "  - exact confirmation phrase required"
echo "  - MSP_ADMIN required"
echo "  - final organization cannot be deleted"
echo "  - saved AWS connections block deletion unless explicitly detached"
echo "  - detaching removes only Vodia's saved AWS connection metadata"
echo "  - AWS IAM roles, EC2 instances, DNS, PBXs, and other external resources are NOT deleted"
echo "  - commercial audit rows are retained"
echo
echo "Backup: $BACKUP_DIR"
