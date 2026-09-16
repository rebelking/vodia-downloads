#!/usr/bin/env bash
set -Eeuo pipefail

APP=/opt/vodia-mcp
ADMIN="$APP/admin.js"
VERSION="$APP/version.js"
SERVICE=vodia-mcp
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP_DIR="/var/backups/vodia-mcp-v0.14.8-account-batch-$STAMP"
TMP_ADMIN="$(mktemp --suffix=.js)"
TMP_VERSION="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP_ADMIN" "$TMP_VERSION"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || fail "run as root"

echo "=== Vodia MCP v0.14.8 — Generic Account Batch Plan/Apply ==="
echo "[1/8] Preflight"
test -f "$ADMIN" || fail "missing $ADMIN"
test -f "$VERSION" || fail "missing $VERSION"
node --check "$ADMIN" >/dev/null || fail "current admin.js syntax invalid"
grep -q 'server.registerTool("plan_create_account"' "$ADMIN" || fail "plan_create_account missing"
grep -q 'server.registerTool("plan_update_account"' "$ADMIN" || fail "plan_update_account missing"
grep -q 'post_rest_domain_domain_addacc' "$ADMIN" || fail "account-create operation missing"
grep -q 'post_rest_domain_domain_user_settings_ext' "$ADMIN" || fail "account-update operation missing"
if grep -q '"plan_account_batch"' "$ADMIN"; then fail "batch patch already installed"; fi
echo PASS

echo "[2/8] Backup"
mkdir -p "$BACKUP_DIR"
cp -a "$ADMIN" "$BACKUP_DIR/admin.js"
cp -a "$VERSION" "$BACKUP_DIR/version.js"
echo "PASS: $BACKUP_DIR"

cp -a "$ADMIN" "$TMP_ADMIN"
cp -a "$VERSION" "$TMP_VERSION"

echo "[3/8] Patch admin.js"
python3 - "$TMP_ADMIN" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

module_anchor='export function registerAdminTools('
if module_anchor not in s:
    raise SystemExit('PATCH ERROR: registerAdminTools export anchor not found')
module_block=r'''
// v0.14.8 generic account batch framework.
// One MCP apply call may execute many non-destructive account creates/updates.
// DELETE is deliberately excluded and remains under the existing destructive policy.
const ACCOUNT_BATCH_PLAN_TTL_MS = 5 * 60 * 1000;
const accountBatchPlans = new Map();

function normalizeAccountBatchOperations(operations) {
  if (!Array.isArray(operations) || operations.length < 1 || operations.length > 500) {
    throw new Error("operations must contain 1-500 batch items.");
  }
  return operations.map((item, index) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) throw new Error(`operations[${index}] must be an object.`);
    const action = String(item.action || "").trim().toLowerCase();
    if (!['create','update'].includes(action)) throw new Error(`operations[${index}].action must be create or update.`);
    if (action === 'create') {
      const type = String(item.type || "").trim();
      const accounts = String(item.accounts || "").trim();
      if (!type || !/^[A-Za-z0-9_.-]+$/.test(type)) throw new Error(`operations[${index}].type is invalid.`);
      if (!accounts || !/^[A-Za-z0-9*#._/,-]+$/.test(accounts)) throw new Error(`operations[${index}].accounts contains unsupported characters.`);
      return { action, type, accounts };
    }
    const account = String(item.account || "").trim();
    const changes = item.changes;
    if (!account || account.length > 128) throw new Error(`operations[${index}].account is invalid.`);
    if (!changes || typeof changes !== 'object' || Array.isArray(changes) || Object.keys(changes).length < 1) {
      throw new Error(`operations[${index}].changes must be a non-empty object.`);
    }
    return { action, account, changes };
  });
}

function publicAccountBatchPlan(plan, redactSensitive) {
  return {
    changeId: plan.changeId,
    operation: 'AccountBatch',
    domain: plan.domain,
    operationCount: plan.operations.length,
    creates: plan.operations.filter(x => x.action === 'create').length,
    updates: plan.operations.filter(x => x.action === 'update').length,
    operations: redactSensitive ? redactSensitive(plan.operations) : plan.operations,
    reason: plan.reason,
    expiresAt: plan.expiresAt.toISOString(),
    requiredConfirmation: plan.requiredConfirmation,
    changesPbx: false,
    destructive: false,
  };
}

'''
s=s.replace(module_anchor,module_block+module_anchor,1)

anchor='  server.registerTool("plan_provision_mac", {'
if anchor not in s:
    raise SystemExit('PATCH ERROR: plan_provision_mac insertion anchor not found')
block=r'''
  server.registerTool("plan_account_batch", {
    title: "Plan Vodia account batch",
    description: "Plan one non-destructive batch containing account creates and/or account configuration updates for a single tenant. Supports any account type accepted by the Vodia add-account API. Planning makes no PBX changes. Delete is intentionally excluded.",
    inputSchema: {
      domain: z.string().min(1),
      operations: z.array(z.object({
        action: z.enum(["create", "update"]),
        type: z.string().optional(),
        accounts: z.string().optional(),
        account: z.string().optional(),
        changes: z.record(z.string(), z.any()).optional(),
      })).min(1).max(500),
      reason: z.string().min(3).max(500),
    },
    outputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  }, async ({ domain, operations, reason }) => {
    audit("plan_account_batch", { actor, domain, operationCount: Array.isArray(operations) ? operations.length : 0, reason });
    try {
      const normalized = normalizeAccountBatchOperations(operations);
      const changeId = `account-batch-${globalThis.crypto?.randomUUID?.() || Date.now()}`;
      const expiresAt = new Date(Date.now() + ACCOUNT_BATCH_PLAN_TTL_MS);
      const requiredConfirmation = `APPLY ACCOUNT BATCH ${changeId} ON ${domain}`;
      const plan = {
        changeId,
        actor: String(actor || "unknown"),
        domain: String(domain || "").trim(),
        operations: normalized,
        reason: String(reason || "").trim(),
        expiresAt,
        requiredConfirmation,
        used: false,
      };
      accountBatchPlans.set(changeId, plan);
      return success(publicAccountBatchPlan(plan, redactSensitive), { expiresAt: expiresAt.toISOString(), approvalRequired: true, changesMade: false }, "Account batch planned. Review the full batch, then apply it once with the exact confirmation.");
    } catch (error) { return failure(error, "plan account batch"); }
  });

  server.registerTool("apply_account_batch", {
    title: "Apply Vodia account batch",
    description: "Apply one unchanged, unexpired, non-destructive account batch plan. Executes all creates and updates inside one MCP write-tool invocation so the client can present one Allow once / Always allow decision. Delete is not supported.",
    inputSchema: { change_id: z.string().min(1), confirmation: z.string().min(1) },
    outputSchema,
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
  }, async ({ change_id, confirmation }) => {
    audit("apply_account_batch", { actor, change_id, confirmation: "[REDACTED_CONFIRMATION]" });
    try {
      const plan = accountBatchPlans.get(String(change_id || "").trim());
      if (!plan || plan.used) throw new Error("Account batch plan was not found, expired, or was already used.");
      if (Date.now() > plan.expiresAt.getTime()) { accountBatchPlans.delete(plan.changeId); throw new Error("Account batch plan expired. Plan it again."); }
      if (String(actor || "unknown") !== plan.actor) throw new Error("Account batch plan belongs to a different administrator identity.");
      if (String(confirmation || "") !== plan.requiredConfirmation) throw new Error("Confirmation does not exactly match requiredConfirmation.");

      // Mark used before the first PBX write to prevent replay even if a later item fails.
      plan.used = true;
      const results = [];
      let succeeded = 0;
      for (let i = 0; i < plan.operations.length; i += 1) {
        const item = plan.operations[i];
        try {
          let result;
          if (item.action === 'create') {
            const body = item.type === 'extensions' ? { type: item.type, account_ext: item.accounts } : { type: item.type, account: item.accounts };
            result = await callOperation('post_rest_domain_domain_addacc', { pathParams: { domain: plan.domain }, body });
          } else {
            result = await callOperation('post_rest_domain_domain_user_settings_ext', { pathParams: { domain: plan.domain, ext: item.account }, body: item.changes });
          }
          succeeded += 1;
          results.push({ index: i, action: item.action, target: item.action === 'create' ? item.accounts : item.account, success: true, status: result?.meta?.status ?? result?.status ?? null });
        } catch (error) {
          results.push({ index: i, action: item.action, target: item.action === 'create' ? item.accounts : item.account, success: false, error: String(error?.message || error).slice(0, 500) });
          break;
        }
      }
      accountBatchPlans.delete(plan.changeId);
      const failed = results.filter(x => !x.success).length;
      const notAttempted = plan.operations.length - results.length;
      audit("account_batch_applied", { actor, change_id: plan.changeId, domain: plan.domain, total: plan.operations.length, succeeded, failed, notAttempted });
      return success({ changeId: plan.changeId, domain: plan.domain, total: plan.operations.length, succeeded, failed, notAttempted, complete: failed === 0 && notAttempted === 0, results }, { changesMade: succeeded > 0, partial: failed > 0 || notAttempted > 0 }, failed ? "Account batch stopped at the first failed operation. Earlier successful operations were not rolled back automatically." : "Account batch applied successfully.");
    } catch (error) { return failure(error, "apply account batch"); }
  });

'''
s=s.replace(anchor,block+anchor,1)
p.write_text(s)
PY

echo PASS

echo "[4/8] Patch version"
python3 - "$TMP_VERSION" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text()
# Preserve formatting; replace only the exported connector version value.
n=re.sub(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])', r'\g<1>0.14.8\2', s, count=1)
if n==s: raise SystemExit('PATCH ERROR: CONNECTOR_VERSION assignment not found')
p.write_text(n)
PY
echo PASS

echo "[5/8] Static validation"
node --check "$TMP_ADMIN" >/dev/null || fail "patched admin.js syntax invalid"
node --check "$TMP_VERSION" >/dev/null || fail "patched version.js syntax invalid"
grep -q '"plan_account_batch"' "$TMP_ADMIN" || fail "plan_account_batch missing"
grep -q '"apply_account_batch"' "$TMP_ADMIN" || fail "apply_account_batch missing"
grep -q 'Delete is not supported' "$TMP_ADMIN" || fail "delete exclusion marker missing"
grep -q '0.14.8' "$TMP_VERSION" || fail "version marker missing"
echo PASS

echo "[6/8] Install"
cp -a "$TMP_ADMIN" "$ADMIN"
cp -a "$TMP_VERSION" "$VERSION"
if ! node --check "$ADMIN" >/dev/null || ! node --check "$VERSION" >/dev/null; then
  cp -a "$BACKUP_DIR/admin.js" "$ADMIN"; cp -a "$BACKUP_DIR/version.js" "$VERSION"
  fail "live syntax failed; backup restored"
fi
echo PASS

echo "[7/8] Restart + health"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP_DIR/admin.js" "$ADMIN"; cp -a "$BACKUP_DIR/version.js" "$VERSION"
  systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP_DIR/admin.js" "$ADMIN"; cp -a "$BACKUP_DIR/version.js" "$VERSION"
  systemctl restart "$SERVICE" || true
  fail "service unhealthy; backup restored"
fi
curl -fsS http://127.0.0.1:3100/health >/dev/null || echo "WARN: local /health check unavailable; service itself is active"
echo PASS

echo "[8/8] Verify markers"
grep -n -E 'plan_account_batch|apply_account_batch|ACCOUNT_BATCH_PLAN_TTL_MS' "$ADMIN" | head -20
grep -n '0.14.8' "$VERSION" || true

echo
echo "=== v0.14.8 INSTALL PASS ==="
echo "Backup: $BACKUP_DIR"
echo "PBX writes performed by installer: 0"
echo "New admin tools: plan_account_batch, apply_account_batch"
echo "Delete support in generic batch: disabled"
echo
echo "Rollback:"
echo "  cp -a '$BACKUP_DIR/admin.js' '$ADMIN'"
echo "  cp -a '$BACKUP_DIR/version.js' '$VERSION'"
echo "  systemctl restart '$SERVICE'"
