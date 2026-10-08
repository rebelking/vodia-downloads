import { App } from "@modelcontextprotocol/ext-apps";

const $ = (id) => document.getElementById(id);
const app = new App(
  { name: "Vodia AWS Connection", version: "1.0.0" },
  {},
  { autoResize: true }
);

function unwrap(result) {
  const sc = result?.structuredContent;
  if (!sc || typeof sc !== "object") return {};
  if (sc.data && typeof sc.data === "object") return sc.data;
  if (sc.result && typeof sc.result === "object") return sc.result;
  return sc;
}

function setStatus(kind, title, detail = "") {
  const box = $("status");
  box.className = "status " + kind;
  $("status-title").textContent = title;
  $("status-detail").textContent = detail;
  box.hidden = false;
}

function setBusy(busy) {
  $("save-btn").disabled = busy;
  $("save-btn").textContent = busy ? "Testing connection…" : "Test & Save Connection";
}

function renderInitial(result) {
  const d = unwrap(result);
  const profile = d.profile || d.connectionProfile || null;
  if (profile?.configured) {
    $("roleArn").value = profile.roleArn || "";
    setStatus("ok", "AWS account connected", profile.account ? `Account ${profile.account} · saved ${profile.savedAt || "previously"}` : "Saved connection is ready to use.");
    $("saved-note").textContent = "Future AWS tools can use this saved connection automatically.";
  }
}

$("toggle-external").addEventListener("click", () => {
  const input = $("externalId");
  input.type = input.type === "password" ? "text" : "password";
  $("toggle-external").textContent = input.type === "password" ? "Show" : "Hide";
});

$("save-btn").addEventListener("click", async () => {
  const roleArn = $("roleArn").value.trim();
  const externalId = $("externalId").value.trim();

  if (!roleArn.endsWith("VodiaMCPDeploymentRole")) {
    setStatus("error", "Check the Role ARN", "The role must be named VodiaMCPDeploymentRole.");
    return;
  }
  if (externalId.length < 8) {
    setStatus("error", "Check the External ID", "Use the External ID configured in the role trust policy (minimum 8 characters).");
    return;
  }

  setBusy(true);
  try {
    const result = await app.callServerTool({
      name: "aws_save_customer_connection_profile",
      arguments: { roleArn, externalId }
    });
    const d = unwrap(result);
    if (result?.isError || d?.error) throw new Error(d?.error || "Connection test failed.");
    const identity = d.identity || {};
    $("externalId").value = "";
    setStatus("ok", "AWS account connected", identity.account ? `Account ${identity.account} · STS AssumeRole successful` : "STS AssumeRole successful.");
    $("saved-note").textContent = "Connection saved securely. Future AWS tools will reuse it automatically.";
    try {
      await app.updateModelContext({
        content: [{ type: "text", text: "AWS customer connection was tested successfully and saved. Future AWS deployment tools may use the saved connection profile without asking for the Role ARN or External ID again." }]
      });
    } catch {}
  } catch (error) {
    setStatus("error", "Connection failed", error?.message || String(error));
  } finally {
    setBusy(false);
  }
});

app.ontoolresult = renderInitial;
app.connect().catch((error) => {
  console.error("Vodia AWS Connection MCP App failed to connect", error);
  setStatus("error", "UI connection error", "Use the normal MCP tool flow as a fallback.");
});
