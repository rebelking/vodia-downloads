import { App } from "@modelcontextprotocol/ext-apps";

const $ = (id) => document.getElementById(id);
const app = new App(
  { name: "Vodia Tenant Approval", version: "1.0.0" },
  {},
  { autoResize: true }
);

function firstDefined(...values) {
  return values.find((v) => v !== undefined && v !== null && String(v) !== "");
}

function unwrapStructured(result) {
  const sc = result?.structuredContent;
  if (!sc || typeof sc !== "object") return {};
  if (sc.data && typeof sc.data === "object") return sc.data;
  if (sc.result && typeof sc.result === "object") return sc.result;
  return sc;
}

function normalizePlan(result) {
  const d = unwrapStructured(result);
  const vodia = d?.vodia && typeof d.vodia === "object" ? d.vodia : {};
  const cloudflare = d?.cloudflare && typeof d.cloudflare === "object" ? d.cloudflare : {};

  const tenant = firstDefined(d.tenant, vodia.tenant, d.fqdn, d.domain, "—");
  const display = firstDefined(
    d.display_name,
    d.displayName,
    vodia.display_name,
    vodia.displayName,
    tenant !== "—" ? String(tenant).split(".")[0] : "—"
  );
  const country = firstDefined(d.country_code, d.countryCode, vodia.country_code, vodia.countryCode, "—");
  const changeId = firstDefined(d.change_id, d.changeId, d.plan_id, d.planId, "—");
  const expires = firstDefined(d.expires_at, d.expiresAt, "—");
  const confirmation = firstDefined(
    d.required_confirmation,
    d.requiredConfirmation,
    d.confirmation_to_copy,
    d.confirmation,
    ""
  );

  let provider = firstDefined(d.dns_provider, d.dnsProvider, vodia.dns_provider);
  let providerDetail = "";
  if (!provider) {
    if (cloudflare && Object.keys(cloudflare).length) {
      provider = "Cloudflare";
      providerDetail = firstDefined(cloudflare.name, cloudflare.zone, cloudflare.record?.name, "") || "";
    } else {
      provider = "Vodia DNS";
      providerDetail = firstDefined(vodia.matchedWildcard, d.matchedWildcard, d.vodiaWildcard, "") || "";
    }
  }

  const currentState = firstDefined(
    d.current_state,
    d.currentState,
    d.preflight?.tenantExists === false ? "Tenant does not exist" : undefined,
    vodia.preflight?.tenantExists === false ? "Tenant does not exist" : undefined,
    "Ready for review"
  );

  return {
    tenant,
    display,
    country,
    changeId,
    expires,
    confirmation,
    provider,
    providerDetail,
    currentState,
    action: provider === "Cloudflare"
      ? "Create new tenant + Cloudflare DNS"
      : "Create new tenant (Vodia-managed DNS)",
  };
}

function setText(id, value) {
  const el = $(id);
  if (el) el.textContent = value == null || value === "" ? "—" : String(value);
}

function render(plan) {
  setText("action", plan.action);
  setText("tenant", plan.tenant);
  setText("provider", plan.providerDetail ? `${plan.provider} — ${plan.providerDetail}` : plan.provider);
  setText("country", plan.country);
  setText("display", plan.display);
  setText("state", plan.currentState);
  setText("plan-id", plan.changeId);
  setText("expires", plan.expires !== "—" ? `Expires ${plan.expires}` : "");
  setText("confirmation", plan.confirmation || "Confirmation phrase was not returned by this planner.");
  $("copy-btn").disabled = !plan.confirmation;
  $("copy-icon").disabled = !plan.confirmation;
}

async function copyApproval() {
  const text = $("confirmation")?.textContent?.trim();
  if (!text || text.startsWith("Confirmation phrase was not returned")) return;

  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.appendChild(ta);
    ta.focus();
    ta.select();
    document.execCommand("copy");
    ta.remove();
  }

  const btn = $("copy-btn");
  const old = btn.textContent;
  btn.textContent = "Copied ✓";
  setTimeout(() => { btn.textContent = old; }, 1600);
}

$("copy-btn").addEventListener("click", copyApproval);
$("copy-icon").addEventListener("click", copyApproval);

app.ontoolresult = (result) => render(normalizePlan(result));
app.connect().catch((error) => {
  console.error("Vodia tenant approval MCP App failed to connect", error);
  setText("state", "UI connection error — use the normal text approval response.");
});
