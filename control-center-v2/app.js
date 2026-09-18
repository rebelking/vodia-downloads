const $=(id)=>document.getElementById(id);

function badge(id,text,state="neutral"){
  const el=$(id); if(!el)return;
  el.textContent=text; el.className="badge"+(state==="neutral"?" neutral":state==="bad"?" bad":"");
}
function summarize(obj){
  if(obj==null)return "—";
  if(typeof obj==="string")return obj;
  if(typeof obj==="number"||typeof obj==="boolean")return String(obj);
  for(const key of ["message","summary","status","state","account","tenant","organization","name"]){
    if(obj[key]!=null && typeof obj[key]!=="object") return String(obj[key]);
  }
  return "Available";
}
function connectionState(provider,result){
  if(!result?.ok) return {label:"Needs setup",state:"neutral",detail:"Connection not verified"};
  const d=result.data||{};
  if(provider==="aws"){
    const p=d.profile||d.connectionProfile||d;
    if(p?.configured) return {label:"Connected",state:"ok",detail:p.account?`AWS account ${p.account}`:"Saved AWS connection"};
    return {label:"Needs setup",state:"neutral",detail:"No saved AWS connection"};
  }
  if(provider==="cloudflare"){
    const ready=d.ready ?? d.connected ?? d.ok ?? d.configured;
    return ready===false
      ? {label:"Needs setup",state:"neutral",detail:summarize(d)}
      : {label:"Connected",state:"ok",detail:summarize(d)};
  }
  if(provider==="microsoft"){
    const ready=d.ready ?? d.connected ?? d.ok;
    return ready===false
      ? {label:"Needs setup",state:"neutral",detail:summarize(d)}
      : {label:"Connected",state:"ok",detail:summarize(d)};
  }
  return {label:"Connected",state:"ok",detail:summarize(d)};
}
async function loadHealth(){
  try{
    const r=await fetch("/control-api/health",{credentials:"same-origin"});
    if(!r.ok) throw new Error("HTTP "+r.status);
    const payload=await r.json(),h=payload.health||{};
    $("mcpDot").className="dot ok";
    $("mcpStatus").textContent="MCP connected";
    $("serviceState").textContent=h.ok?"Online":"Degraded";
    $("serviceName").textContent=h.service||"Vodia MCP";
    $("versionValue").textContent=h.version||"—";
    $("oauthValue").textContent=h.oauthEnabled?"Enabled":"Disabled";
    $("modeValue").textContent=h.mode?.includes("policy-controlled")?"Policy-controlled admin":(h.mode||"—");
    $("modeValue").title=h.mode||"";
  }catch(e){
    $("mcpDot").className="dot bad"; $("mcpStatus").textContent="MCP unavailable"; $("serviceState").textContent="Offline";
  }
}
async function loadConnections(){
  try{
    const r=await fetch("/control-api/connections",{credentials:"same-origin"});
    const p=await r.json();
    for(const provider of ["aws","cloudflare","microsoft","pbx"]){
      const s=connectionState(provider,p.connections?.[provider]);
      badge(provider==="microsoft"?"microsoftBadge":provider+"Badge",s.label,s.state);
      const detail=$(provider==="microsoft"?"microsoftDetail":provider+"Detail");
      if(detail)detail.textContent=s.detail;
    }
    renderPbx(p.connections?.pbx);
  }catch(e){
    for(const id of ["awsBadge","cloudflareBadge","microsoftBadge","pbxBadge"])badge(id,"Unavailable","bad");
  }
}
function renderPbx(result){
  const box=$("pbxPanel");
  if(!box)return;
  if(!result?.ok){box.innerHTML="<strong>PBX status unavailable</strong><span>Use Test to retry the live MCP status read.</span>";return}
  const d=result.data||{};
  const rows=[];
  const candidates=[
    ["Version",d.version||d.pbxVersion||d.system?.version],
    ["Platform",d.platform||d.os||d.system?.platform],
    ["Status",d.status||d.state||"Online"]
  ].filter(x=>x[1]);
  if(!candidates.length){box.innerHTML="<strong>PBX connected</strong><span>Live get_system_status completed successfully.</span>";return}
  box.innerHTML=candidates.map(([k,v])=>`<div class="pbx-row"><span>${k}</span><strong>${String(v)}</strong></div>`).join("");
}
async function testProvider(provider,button){
  const old=button.textContent; button.disabled=true; button.textContent="Testing…";
  try{
    const r=await fetch("/control-api/test/"+provider,{method:"POST",credentials:"same-origin"});
    const p=await r.json();
    const s=connectionState(provider,p);
    badge(provider==="microsoft"?"microsoftBadge":provider+"Badge",s.label,s.state);
    const detail=$(provider==="microsoft"?"microsoftDetail":provider+"Detail"); if(detail)detail.textContent=s.detail;
    if(provider==="pbx"&&p.ok) renderPbx(p);
  }finally{button.disabled=false;button.textContent=old}
}
async function loadActivity(){
  try{
    const r=await fetch("/control-api/activity?limit=8",{credentials:"same-origin"});
    const p=await r.json(),rows=p.activity||[];
    $("activityList").innerHTML=rows.length?rows.map(x=>`<div class="activity-row"><span class="activity-dot"></span><div><strong>${escapeHtml(x.tool||"MCP activity")}</strong><small>${escapeHtml([x.result,x.at].filter(Boolean).join(" · ")||"Recorded")}</small></div></div>`).join(""):'<div class="activity-row"><span class="activity-dot"></span><div><strong>No recent activity</strong><small>Audit log is quiet.</small></div></div>';
  }catch{}
}
function escapeHtml(v){return String(v).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#039;"}[c]))}

const flows={
 aws:{eyebrow:"AWS CONNECTION",title:"Amazon Web Services",text:"AWS connection state is read live from the saved MCP connection profile. Test uses the existing aws_check_customer_connection tool.",steps:[["Connection profile","Saved server-side; External ID is never displayed."],["Test","STS AssumeRole is verified without creating infrastructure."],["Deployment","Marketplace and EC2 remain approval-gated."]],primary:"Test AWS now"},
 cloudflare:{eyebrow:"DNS CONNECTION",title:"Cloudflare DNS",text:"Cloudflare status is checked through the existing cloudflare_check_connection MCP tool. Provider tokens remain outside the customer dashboard.",steps:[["Saved integration","Use the existing encrypted Cloudflare integration."],["Test","Verify the saved zone and API permissions."],["DNS changes","Continue to use guarded plan → approve → apply → verify."]],primary:"Test Cloudflare now"},
 microsoft:{eyebrow:"MICROSOFT CONNECTION",title:"Microsoft 365",text:"Microsoft readiness is checked through microsoft_check_graph_readiness using the configured Entra integration.",steps:[["OAuth","Uses the server-side Entra application configuration."],["Readiness","Checks organization, domains, users, and license reads."],["Teams","Direct Routing workflows remain separately controlled."]],primary:"Test Microsoft now"},
 pbx:{eyebrow:"PBX CONNECTION",title:"Vodia PBX",text:"PBX status is read through the existing get_system_status MCP tool.",steps:[["Service","Verify MCP/PBX connectivity."],["Read status","Load current PBX status."],["Changes","Writes remain approval-gated."]],primary:"Test PBX now"}
};
function openFlow(key){
  const f=flows[key]; if(!f)return;
  $("modalEyebrow").textContent=f.eyebrow;$("modalTitle").textContent=f.title;$("modalText").textContent=f.text;
  $("modalSteps").innerHTML=f.steps.map((s,i)=>`<div class="step"><span class="step-num">${i+1}</span><div><strong>${s[0]}</strong><small>${s[1]}</small></div></div>`).join("");
  $("modalPrimary").textContent=f.primary;$("modalPrimary").dataset.flow=key;$("modalBackdrop").hidden=false;
}
function closeModal(){$("modalBackdrop").hidden=true}
document.querySelectorAll("button[data-provider]").forEach(el=>el.addEventListener("click",()=>{
  const p=el.dataset.provider;
  if(el.dataset.action==="test")return testProvider(p,el);
  openFlow(p);
}));
document.querySelectorAll("[data-workflow]").forEach(el=>el.addEventListener("click",()=>{
  const w=el.dataset.workflow;
  if(w==="deploy-aws")return openFlow("aws");
  if(w==="teams")return openFlow("microsoft");
  if(w==="health")return openFlow("pbx");
  $("modalEyebrow").textContent="PBX WORKFLOW";$("modalTitle").textContent="Create a Vodia tenant";
  $("modalText").textContent="Tenant creation continues through the existing guarded MCP plan and approval workflow.";
  $("modalSteps").innerHTML=["Plan tenant and DNS","Review customer-facing plan","Approve exact change","Apply and verify"].map((x,i)=>`<div class="step"><span class="step-num">${i+1}</span><div><strong>${x}</strong></div></div>`).join("");
  $("modalPrimary").textContent="Open advanced workflow";$("modalPrimary").dataset.flow="tenant";$("modalBackdrop").hidden=false;
}));
$("modalClose").addEventListener("click",closeModal);$("modalCancel").addEventListener("click",closeModal);
$("modalBackdrop").addEventListener("click",e=>{if(e.target===$("modalBackdrop"))closeModal()});
$("refreshBtn").addEventListener("click",()=>Promise.all([loadHealth(),loadConnections(),loadActivity()]));
$("advancedBtn").addEventListener("click",()=>location.href="/admin/");
$("activityBtn").addEventListener("click",()=>location.href="/admin/");
$("modalPrimary").addEventListener("click",async()=>{
  const flow=$("modalPrimary").dataset.flow;
  if(["aws","cloudflare","microsoft","pbx"].includes(flow)){
    const fake={textContent:$("modalPrimary").textContent,disabled:false};
    $("modalPrimary").disabled=true;$("modalPrimary").textContent="Testing…";
    try{
      const r=await fetch("/control-api/test/"+flow,{method:"POST",credentials:"same-origin"});
      const p=await r.json(),s=connectionState(flow,p);
      $("modalText").textContent=p.ok?`Live check passed: ${s.detail}`:`Live check failed: ${p.error||"Not configured"}`;
      await loadConnections();
    }finally{$("modalPrimary").disabled=false;$("modalPrimary").textContent=fake.textContent}
    return;
  }
  location.href="/admin/";
});
Promise.all([loadHealth(),loadConnections(),loadActivity()]);
