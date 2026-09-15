#!/usr/bin/env bash
set -Eeuo pipefail

APP="/opt/vodia-mcp"
INDEX="$APP/index.js"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
BACKUP="$INDEX.pre-phase3-11-5-10.$STAMP"

fail(){ echo "FAIL: $*" >&2; exit 1; }

echo "=== Vodia MCP Phase 3.11.5.10 — Guided Ambiguous Model Selection ==="

echo "[1/7] Preflight"
test -f "$INDEX" || fail "missing $INDEX"
grep -q '"pbx_ai_prepare_3cx_device_migration"' "$INDEX" || fail "prepare migration tool not found"
grep -q 'function classify3cxDeviceForMigration' "$INDEX" || fail "device classifier not found"
grep -q 'function matchLiveDeviceCandidates' "$INDEX" || fail "live candidate matcher not found"
grep -q 'function deriveVendorFromModel' "$INDEX" || fail "vendor derivation helper not found"
echo "PASS"

echo "[2/7] Backup"
cp -a "$INDEX" "$BACKUP"
echo "PASS: $BACKUP"

echo "[3/7] Add guided model-selection tool"
python3 - "$INDEX" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

tool_name = '"pbx_ai_validate_3cx_device_model_selection"'
if tool_name in s:
    print("Tool already present; leaving existing implementation unchanged.")
    raise SystemExit(0)

anchor = 'server.registerTool(\n  "pbx_ai_diagnose_device_catalog",'
if anchor not in s:
    raise SystemExit("PATCH ERROR: diagnostic tool anchor not found")

block = r'''
server.registerTool(
  "pbx_ai_validate_3cx_device_model_selection",
  {
    title: "Validate grouped 3CX phone model selection",
    description: "Read-only guided resolver for ambiguous 3CX phone model groups. Finds all matching source devices, reads the live Vodia tenant model catalog, presents only valid candidates, and validates an administrator-selected model. Never guesses and never writes to the PBX.",
    inputSchema: {
      filename: z.string().min(1),
      target_tenant: z.string().min(1),
      vendor: z.string().min(1),
      source_model: z.string().min(1),
      selected_model: z.string().min(1).optional(),
    },
    outputSchema: toolOutputSchema,
    annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: false },
  },
  async ({ filename, target_tenant, vendor, source_model, selected_model }) => {
    scopedAudit("pbx_ai_validate_3cx_device_model_selection", {
      filename, target_tenant, vendor, source_model, selected_model
    });

    try {
      const loaded = load3cxNormalizedImport(filename);
      const phones = get3cxInventoryCategory(loaded.data, "phones").items;

      const wantedVendor = normalizeDeviceToken(vendor);
      const wantedModel = normalizeDeviceToken(source_model);

      const matchingPhones = phones.filter((phone) => {
        const actualVendor = normalizeDeviceToken(deriveVendorFromModel(phone)?.vendor || "");
        const actualModel = normalizeDeviceToken(
          String(phone?.model ?? phone?.device_model ?? phone?.phone_model ?? "").trim()
        );
        return actualVendor === wantedVendor && actualModel === wantedModel;
      });

      if (!matchingPhones.length) {
        return scopedSuccess(
          {
            targetTenant: target_tenant,
            filename,
            changesMade: false,
            status: "SOURCE_GROUP_NOT_FOUND",
            vendor,
            sourceModel: source_model,
            sourceDeviceCount: 0,
            candidates: [],
            selectedModel: null,
            modelOverride: null,
          },
          { operation: "AI_VALIDATE_3CX_DEVICE_MODEL_SELECTION", readOnly: true, changesMade: false },
          `No matching source device group found for ${vendor} ${source_model}.`
        );
      }

      const liveCatalog = await fetchLiveVodiaDeviceCatalog(target_tenant);
      const candidates = matchLiveDeviceCandidates(
        vendor,
        source_model,
        liveCatalog
      ).map((c) => ({
        vendor: c.vendor ?? null,
        model: c.model ?? null,
      }));

      const uniqueModels = [...new Map(
        candidates
          .filter((c) => c.model)
          .map((c) => [normalizeDeviceToken(c.model), c])
      ).values()];

      if (!selected_model) {
        return scopedSuccess(
          {
            targetTenant: target_tenant,
            filename,
            changesMade: false,
            status: uniqueModels.length > 1
              ? "AWAITING_ADMIN_SELECTION"
              : (uniqueModels.length === 1 ? "SINGLE_VALID_CANDIDATE" : "NO_VALID_CANDIDATE"),
            vendor,
            sourceModel: source_model,
            sourceDeviceCount: matchingPhones.length,
            sampleExtensions: matchingPhones
              .map((p) => String(p?.extension ?? p?.ext ?? p?.user ?? "").trim())
              .filter(Boolean)
              .slice(0, 10),
            candidates: uniqueModels,
            selectedModel: null,
            modelOverride: null,
            adminInstruction: uniqueModels.length > 1
              ? `Choose exactly one live Vodia model for all ${matchingPhones.length} matching source devices.`
              : (uniqueModels.length === 1
                  ? "One live Vodia candidate exists; confirm it before applying a grouped override."
                  : "No compatible live Vodia model exists for this source group."),
          },
          { operation: "AI_VALIDATE_3CX_DEVICE_MODEL_SELECTION", readOnly: true, changesMade: false },
          uniqueModels.length > 1
            ? `Administrator selection required for ${vendor} ${source_model}.`
            : "Grouped device model validation completed."
        );
      }

      const chosen = uniqueModels.find(
        (c) => normalizeDeviceToken(c.model) === normalizeDeviceToken(selected_model)
      );

      if (!chosen) {
        return scopedSuccess(
          {
            targetTenant: target_tenant,
            filename,
            changesMade: false,
            status: "INVALID_ADMIN_SELECTION",
            vendor,
            sourceModel: source_model,
            sourceDeviceCount: matchingPhones.length,
            candidates: uniqueModels,
            selectedModel: selected_model,
            modelOverride: null,
            adminInstruction: "Choose one of the models returned in candidates. The MCP will not guess or accept an out-of-catalog model.",
          },
          { operation: "AI_VALIDATE_3CX_DEVICE_MODEL_SELECTION", readOnly: true, changesMade: false },
          `Selection '${selected_model}' is not a valid live Vodia candidate for ${vendor} ${source_model}.`
        );
      }

      const overrideKey = `${String(vendor).trim()} ${String(source_model).trim()}`.toLowerCase();

      return scopedSuccess(
        {
          targetTenant: target_tenant,
          filename,
          changesMade: false,
          status: "ADMIN_SELECTION_VALIDATED",
          vendor,
          sourceModel: source_model,
          sourceDeviceCount: matchingPhones.length,
          candidates: uniqueModels,
          selectedModel: chosen.model,
          modelOverride: { [overrideKey]: chosen.model },
          nextStep: {
            tool: "pbx_ai_prepare_3cx_device_migration",
            modelOverrideToMerge: { [overrideKey]: chosen.model },
          },
        },
        { operation: "AI_VALIDATE_3CX_DEVICE_MODEL_SELECTION", readOnly: true, changesMade: false },
        `Validated ${chosen.model} for all ${matchingPhones.length} matching ${vendor} ${source_model} devices. No PBX changes were made.`
      );
    } catch (error) {
      return failure(error, "3CX grouped device model selection validation");
    }
  }
);

'''

s = s.replace(anchor, block + anchor, 1)
p.write_text(s)
print("PASS: tool inserted")
PY

echo "[4/7] Validate JavaScript"
node --check "$INDEX"
echo "PASS"

echo "[5/7] Safety contract checks"
grep -q '"pbx_ai_validate_3cx_device_model_selection"' "$INDEX" \
  || fail "new tool not found"
grep -q '"AWAITING_ADMIN_SELECTION"' "$INDEX" \
  || fail "guided selection state missing"
grep -q '"INVALID_ADMIN_SELECTION"' "$INDEX" \
  || fail "invalid selection guard missing"
grep -q '"ADMIN_SELECTION_VALIDATED"' "$INDEX" \
  || fail "validated selection state missing"
echo "PASS"

echo "[6/7] Restart service"
systemctl restart vodia-mcp
systemctl is-active --quiet vodia-mcp || fail "vodia-mcp did not restart"
echo "PASS: vodia-mcp active"

echo "[7/7] Verify"
grep -n -A18 -B3 '"pbx_ai_validate_3cx_device_model_selection"' "$INDEX" | head -80

echo
echo "=== PHASE 3.11.5.10 INSTALL PASS ==="
echo "New tool: pbx_ai_validate_3cx_device_model_selection"
echo "Purpose: guided grouped model choice using live Vodia candidates"
echo "PBX writes: 0"
echo "Backup: $BACKUP"
echo
echo "NEXT:"
echo "1) Call without selected_model for Yealink T46."
echo "2) Admin chooses T46G, T46S, or T46U."
echo "3) Call again with selected_model to validate."
echo "4) Merge returned override into pbx_ai_prepare_3cx_device_migration."
