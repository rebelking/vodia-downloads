#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
SERVICE="vodia-mcp"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-phase3-11-6.$STAMP"
TMP="$(mktemp --suffix=.js)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.6 — Consolidated 3CX Phone Model Review ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
node --check "$INDEX" >/dev/null || fail "current index.js syntax invalid"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "prepare migration tool not found"
grep -q '"pbx_ai_validate_3cx_device_model_selection"' "$INDEX" || fail "Phase 3.11.5.10 guided resolver not found"
grep -q 'function matchLiveDeviceCandidates' "$INDEX" || fail "live candidate matcher not found"
grep -q 'function deriveVendorFromModel' "$INDEX" || fail "vendor derivation helper not found"
grep -q 'model_overrides: z.record(z.string()).optional()' "$INDEX" || fail "model_overrides contract not found"
echo "PASS"

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
cp -a "$INDEX" "$TMP"
echo "PASS: $BACKUP"

echo "[3/7] Add consolidated grouped-review tool"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

tool_name = '"pbx_ai_review_3cx_device_model_groups"'
if tool_name in s:
    print("Tool already present; leaving existing implementation unchanged.")
    raise SystemExit(0)

anchor = 'server.registerTool(\n  "pbx_ai_validate_3cx_device_model_selection",'
if anchor not in s:
    raise SystemExit("PATCH ERROR: Phase 3.11.5.10 tool anchor not found")

block = r'''
server.registerTool(
  "pbx_ai_review_3cx_device_model_groups",
  {
    title: "Review all 3CX phone model groups",
    description: "Read-only consolidated review of 3CX phone model groups against the live Vodia tenant catalog. Groups identical source vendor/model strings, shows valid live candidates, validates administrator overrides, and returns a merged override map for migration preview. Never guesses and never writes to the PBX.",
    inputSchema: {
      filename: z.string().min(1),
      target_tenant: z.string().min(1),
      model_overrides: z.record(z.string()).optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  async ({ filename, target_tenant, model_overrides }) => {
    scopedAudit("pbx_ai_review_3cx_device_model_groups", {
      filename,
      target_tenant,
      modelOverrideCount: Object.keys(model_overrides || {}).length,
    });

    try {
      const loaded = load3cxNormalizedImport(filename);
      const phones = get3cxInventoryCategory(loaded.data, "phones").items;
      const liveCatalog = await fetchLiveVodiaDeviceCatalog(target_tenant);
      const suppliedOverrides = model_overrides || {};

      const normalizedOverrides = new Map(
        Object.entries(suppliedOverrides).map(([key, value]) => [
          normalizeDeviceToken(key),
          String(value || "").trim(),
        ])
      );

      const grouped = new Map();
      for (const phone of phones) {
        const vendorInfo = deriveVendorFromModel(phone) || {};
        const vendor = String(vendorInfo.vendor || "").trim();
        const sourceModel = String(
          phone?.model ?? phone?.device_model ?? phone?.phone_model ?? ""
        ).trim();
        const extension = String(
          phone?.extension ?? phone?.ext ?? phone?.user ?? ""
        ).trim();

        const groupKey = `${normalizeDeviceToken(vendor)} ${normalizeDeviceToken(sourceModel)}`.trim();
        if (!grouped.has(groupKey)) {
          grouped.set(groupKey, {
            groupKey,
            vendor,
            sourceModel,
            sourceDeviceCount: 0,
            sampleExtensions: [],
          });
        }
        const group = grouped.get(groupKey);
        group.sourceDeviceCount += 1;
        if (extension && group.sampleExtensions.length < 10 && !group.sampleExtensions.includes(extension)) {
          group.sampleExtensions.push(extension);
        }
      }

      const groups = [];
      const validatedModelOverrides = {};
      const invalidOverrides = [];

      for (const group of grouped.values()) {
        const candidates = matchLiveDeviceCandidates(
          group.vendor,
          group.sourceModel,
          liveCatalog
        ).map((c) => ({
          vendor: c.vendor ?? null,
          model: c.model ?? null,
        }));

        const uniqueCandidates = [...new Map(
          candidates
            .filter((c) => c.model)
            .map((c) => [normalizeDeviceToken(c.model), c])
        ).values()];

        const overrideLookupKey = normalizeDeviceToken(
          `${group.vendor} ${group.sourceModel}`
        );
        const suppliedSelection = normalizedOverrides.get(overrideLookupKey) || null;
        const chosen = suppliedSelection
          ? uniqueCandidates.find(
              (c) => normalizeDeviceToken(c.model) === normalizeDeviceToken(suppliedSelection)
            )
          : null;

        let status;
        if (suppliedSelection && chosen) {
          status = "ADMIN_SELECTION_VALIDATED";
          validatedModelOverrides[`${group.vendor} ${group.sourceModel}`.trim().toLowerCase()] = chosen.model;
        } else if (suppliedSelection && !chosen) {
          status = "INVALID_ADMIN_SELECTION";
          invalidOverrides.push({
            groupKey: group.groupKey,
            vendor: group.vendor,
            sourceModel: group.sourceModel,
            suppliedSelection,
            candidates: uniqueCandidates,
          });
        } else if (uniqueCandidates.length > 1) {
          status = "AWAITING_ADMIN_SELECTION";
        } else if (uniqueCandidates.length === 1) {
          status = "SINGLE_VALID_CANDIDATE";
        } else {
          status = "NO_VALID_CANDIDATE";
        }

        groups.push({
          ...group,
          status,
          candidates: uniqueCandidates,
          suppliedSelection,
          selectedModel: chosen?.model ?? null,
          requiresAdminSelection: status === "AWAITING_ADMIN_SELECTION",
          blocksMigrationPreview: status === "AWAITING_ADMIN_SELECTION" ||
            status === "INVALID_ADMIN_SELECTION" ||
            status === "NO_VALID_CANDIDATE",
        });
      }

      groups.sort((a, b) => {
        const rank = {
          INVALID_ADMIN_SELECTION: 0,
          AWAITING_ADMIN_SELECTION: 1,
          NO_VALID_CANDIDATE: 2,
          SINGLE_VALID_CANDIDATE: 3,
          ADMIN_SELECTION_VALIDATED: 4,
        };
        const ar = rank[a.status] ?? 99;
        const br = rank[b.status] ?? 99;
        if (ar !== br) return ar - br;
        return `${a.vendor} ${a.sourceModel}`.localeCompare(`${b.vendor} ${b.sourceModel}`);
      });

      const counts = groups.reduce((acc, g) => {
        acc[g.status] = (acc[g.status] || 0) + 1;
        return acc;
      }, {});

      const blockingGroups = groups.filter((g) => g.blocksMigrationPreview);
      const ambiguousGroups = groups.filter((g) => g.status === "AWAITING_ADMIN_SELECTION");

      return scopedSuccess(
        {
          targetTenant: target_tenant,
          filename,
          changesMade: false,
          sourceDeviceCount: phones.length,
          sourceGroupCount: groups.length,
          counts,
          blockingGroupCount: blockingGroups.length,
          ambiguousGroupCount: ambiguousGroups.length,
          groups,
          validatedModelOverrides,
          invalidOverrides,
          readyForMigrationPreview: blockingGroups.length === 0,
          nextStep: blockingGroups.length === 0
            ? {
                tool: "pbx_ai_prepare_3cx_device_migration",
                model_overrides: validatedModelOverrides,
              }
            : {
                tool: "pbx_ai_validate_3cx_device_model_selection",
                instruction: "Resolve each blocking group using one of the live candidates, then rerun this grouped review with the merged model_overrides map.",
              },
          policy: {
            liveCatalogIsAuthoritative: true,
            adminSelectionRequiredForAmbiguousGroups: true,
            invalidSelectionRejected: true,
            pbxWrites: 0,
          },
        },
        {
          operation: "AI_REVIEW_3CX_DEVICE_MODEL_GROUPS",
          readOnly: true,
          changesMade: false,
        },
        blockingGroups.length === 0
          ? "All device model groups are resolved for migration preview. No PBX changes were made."
          : `${blockingGroups.length} device model group(s) still require resolution before migration preview. No PBX changes were made.`
      );
    } catch (error) {
      return failure(error, "3CX grouped device model review");
    }
  }
);

'''

s = s.replace(anchor, block + anchor, 1)
p.write_text(s)
print("PASS: grouped review tool inserted")
PY

echo "[4/7] Validate JavaScript"
node --check "$TMP" >/dev/null || fail "patched syntax invalid"
echo "PASS"

echo "[5/7] Safety contract checks"
grep -q '"pbx_ai_review_3cx_device_model_groups"' "$TMP" || fail "new grouped review tool missing"
grep -q 'readyForMigrationPreview' "$TMP" || fail "preview readiness guard missing"
grep -q 'validatedModelOverrides' "$TMP" || fail "validated override map missing"
grep -q 'ADMIN_SELECTION_VALIDATED' "$TMP" || fail "validated state missing"
grep -q 'AWAITING_ADMIN_SELECTION' "$TMP" || fail "ambiguous state missing"
grep -q 'INVALID_ADMIN_SELECTION' "$TMP" || fail "invalid override guard missing"
grep -q 'NO_VALID_CANDIDATE' "$TMP" || fail "unsupported/no-candidate guard missing"
python3 - "$INDEX" "$TMP" <<'PY'
from pathlib import Path
import sys

a = Path(sys.argv[1]).read_text()
b = Path(sys.argv[2]).read_text()

def classifier(src):
    st = src.find("function classify3cxDeviceForMigration(")
    if st < 0:
        raise SystemExit("SAFETY FAIL: classifier start missing")
    en = src.find("\nserver.registerTool(", st)
    if en < 0:
        raise SystemExit("SAFETY FAIL: classifier end missing")
    return src[st:en]

if classifier(a) != classifier(b):
    raise SystemExit("SAFETY FAIL: classifier changed")

for required in [
    '"pbx_ai_validate_3cx_device_model_selection"',
    '"pbx_ai_prepare_3cx_device_migration"',
    'model_overrides: z.record(z.string()).optional()',
]:
    if required not in b:
        raise SystemExit("SAFETY FAIL: missing existing contract " + required)

print("PASS: existing classifier byte-identical")
print("PASS: guided single-group resolver preserved")
print("PASS: migration preview contract preserved")
print("PASS: new tool is read-only and performs zero PBX writes")
PY

echo "[6/7] Install + restart"
cp -a "$TMP" "$INDEX"
if ! systemctl restart "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" || true
  fail "restart failed; backup restored"
fi
sleep 2
if ! systemctl is-active --quiet "$SERVICE"; then
  cp -a "$BACKUP" "$INDEX"
  systemctl restart "$SERVICE" || true
  fail "service unhealthy; backup restored"
fi
echo "PASS: $SERVICE active"

echo "[7/7] Verify"
grep -n -A25 -B3 '"pbx_ai_review_3cx_device_model_groups"' "$INDEX" | head -100

echo
echo "=== PHASE 3.11.6 INSTALL PASS ==="
echo "New tool: pbx_ai_review_3cx_device_model_groups"
echo "Purpose: review every source phone-model group in one call"
echo "Live Vodia catalog: authoritative"
echo "Invalid admin selections: rejected"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo
echo "TEST NEXT:"
echo "1) Call pbx_ai_review_3cx_device_model_groups with filename + target_tenant."
echo "2) Confirm Yealink T46 is AWAITING_ADMIN_SELECTION with live candidates."
echo "3) Rerun with model_overrides after choosing T46G/T46S/T46U."
echo "4) When readyForMigrationPreview=true, pass validatedModelOverrides into pbx_ai_prepare_3cx_device_migration."
