const $=(id)=>document.getElementById(id);

function badge(id,text,state="neutral"){
  const el=$(id); if(!el)return;
  el.textContent=text; el.className="badge"+(state==="neutral"?" neutral":state==="bad"?" bad":"");
}

async function loadHealth(){
  try{
    const r=await fetch("/health",{credentials:"same-origin"});
    if(!r.ok) throw new Error("HTTP "+r.status);
    const h=await r.json();
    $("mcpDot").className="dot ok";
    $("mcpStatus").textContent="MCP connected";
    $("serviceState").textContent=h.ok?"Online":"Degraded";
    $("serviceName").textContent=h.service||"Vodia MCP";
    $("versionValue").textContent=h.version||"—";
    $("oauthValue").textContent=h.oauthEnabled?"Enabled":"Disabled";
    $("modeValue").textContent=(h.mode||"—").replaceAll("-"," ");
    badge("pbxBadge","Connected","ok");
    $("pbxDetail").textContent="MCP service reachable";
  }catch(e){
    $("mcpDot").className="dot bad";
    $("mcpStatus").textContent="MCP unavailable";
    $("serviceState").textContent="Offline";
    badge("pbxBadge","Unavailable","bad");
    $("pbxDetail").textContent=e.message;
  }
}

const flows={
  aws:{
    eyebrow:"AWS CONNECTION",
    title:"Connect Amazon Web Services",
    text:"Use the existing secure AWS connection workflow. The main dashboard never asks for raw credentials or displays the External ID.",
    steps:[
      ["Open guided AWS setup","Launch the MCP AWS connection workflow."],
      ["Verify account","MCP performs STS AssumeRole without creating infrastructure."],
      ["Save connection","The connection profile is encrypted and reused by future sessions."]
    ],
    primary:"Start AWS setup"
  },
  cloudflare:{
    eyebrow:"DNS CONNECTION",
    title:"Manage Cloudflare DNS",
    text:"Cloudflare stays a managed integration. Provider secrets remain in protected configuration and never appear on the customer dashboard.",
    steps:[
      ["Check saved integration","Verify the configured Cloudflare connection."],
      ["Verify DNS zone","Confirm the customer-owned zone is available."],
      ["Ready for workflows","Tenant/DNS planning can use the saved provider."]
    ],
    primary:"Check Cloudflare"
  },
  microsoft:{
    eyebrow:"MICROSOFT CONNECTION",
    title:"Connect Microsoft 365",
    text:"Microsoft onboarding should be an OAuth / guided connection flow rather than raw IDs and secrets on the dashboard.",
    steps:[
      ["Sign in to Microsoft","Use the configured Entra application."],
      ["Verify tenant","Load domains, users, licenses, and readiness."],
      ["Enable workflows","Teams and Direct Routing actions become available."]
    ],
    primary:"Start Microsoft setup"
  },
  pbx:{
    eyebrow:"PBX CONNECTION",
    title:"Vodia PBX connection",
    text:"The PBX is managed by the MCP service. Customer-facing screens show status and actions, while raw API credentials remain in protected server configuration.",
    steps:[
      ["Check service","Verify MCP and PBX reachability."],
      ["Load PBX status","Read current system and tenant health."],
      ["Use guarded actions","Changes continue through plan → approve → apply → verify."]
    ],
    primary:"Check PBX"
  }
};

function openFlow(key){
  const f=flows[key]; if(!f)return;
  $("modalEyebrow").textContent=f.eyebrow;
  $("modalTitle").textContent=f.title;
  $("modalText").textContent=f.text;
  $("modalSteps").innerHTML=f.steps.map((s,i)=>`<div class="step"><span class="step-num">${i+1}</span><div><strong>${s[0]}</strong><small>${s[1]}</small></div></div>`).join("");
  $("modalPrimary").textContent=f.primary;
  $("modalPrimary").dataset.flow=key;
  $("modalBackdrop").hidden=false;
}
function closeModal(){$("modalBackdrop").hidden=true}

document.querySelectorAll("[data-provider]").forEach(el=>{
  if(el.tagName!=="BUTTON")return;
  el.addEventListener("click",()=>{
    const p=el.dataset.provider;
    if(el.dataset.action==="test" && p==="pbx"){loadHealth();return}
    openFlow(p);
  });
});
document.querySelectorAll("[data-workflow]").forEach(el=>el.addEventListener("click",()=>{
  const w=el.dataset.workflow;
  if(w==="deploy-aws") return openFlow("aws");
  if(w==="teams") return openFlow("microsoft");
  if(w==="health") return openFlow("pbx");
  $("modalEyebrow").textContent="PBX WORKFLOW";
  $("modalTitle").textContent="Create a Vodia tenant";
  $("modalText").textContent="Tenant creation remains a guarded MCP workflow with planning, DNS validation, explicit approval, apply, and verification.";
  $("modalSteps").innerHTML=["Plan tenant and DNS","Review customer-facing plan","Approve exact change","Apply and verify"].map((x,i)=>`<div class="step"><span class="step-num">${i+1}</span><div><strong>${x}</strong></div></div>`).join("");
  $("modalPrimary").textContent="Start tenant workflow";
  $("modalPrimary").dataset.flow="tenant";
  $("modalBackdrop").hidden=false;
}));

$("modalClose").addEventListener("click",closeModal);
$("modalCancel").addEventListener("click",closeModal);
$("modalBackdrop").addEventListener("click",e=>{if(e.target===$("modalBackdrop"))closeModal()});
$("refreshBtn").addEventListener("click",loadHealth);
$("advancedBtn").addEventListener("click",()=>{location.href="/admin/"});
$("activityBtn").addEventListener("click",()=>{location.href="/admin/"});
$("modalPrimary").addEventListener("click",()=>{
  const flow=$("modalPrimary").dataset.flow;
  // Phase 1 shell: route advanced setup through the existing protected admin surface
  // until each provider's guided HTTP/MCP action endpoint is attached.
  if(flow==="pbx"){closeModal();loadHealth();return}
  location.href="/admin/";
});
loadHealth();
