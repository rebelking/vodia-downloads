const THEME_KEY="vodia-mcp-theme";
function applyTheme(theme){
  const next=theme==="light"?"light":"dark";
  document.documentElement.dataset.theme=next;
  const btn=document.getElementById("themeToggle");
  if(btn) btn.dataset.mode=next;
  try{localStorage.setItem(THEME_KEY,next)}catch{}
}
function initTheme(){
  let saved=null;
  try{saved=localStorage.getItem(THEME_KEY)}catch{}
  if(saved!=="light"&&saved!=="dark"){
    saved=window.matchMedia&&window.matchMedia("(prefers-color-scheme: light)").matches?"light":"dark";
  }
  applyTheme(saved);
}

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
  const candidates=[
    ["Version",d.version],
    ["Build",d.buildDate],
    ["Status",d.status||"online"],
    ["Total calls",d.totalCalls],
    ["Extension CDRs",d.extensionCdrs],
    ["Trunk CDRs",d.trunkCdrs]
  ].filter(([,v])=>v!==null&&v!==undefined&&v!=="");
  if(!candidates.length){box.innerHTML="<strong>PBX connected</strong><span>Live get_system_status completed successfully.</span>";return}
  box.innerHTML=candidates.map(([k,v])=>`<div class="pbx-row"><span>${escapeHtml(k)}</span><strong>${escapeHtml(v)}</strong></div>`).join("");
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
async function copyText(text){
  try{await navigator.clipboard.writeText(text);return true}catch{return false}
}
function renderModalSteps(steps){
  $("modalSteps").innerHTML=steps.map((s,i)=>`<div class="step"><span class="step-num">${i+1}</span><div><strong>${escapeHtml(s[0])}</strong><small>${escapeHtml(s[1]||"")}</small></div></div>`).join("");
}
async function openAwsFlow(forDeployment=false){
  $("modalEyebrow").textContent=forDeployment?"AWS DEPLOYMENT":"AWS CONNECTION";
  $("modalTitle").textContent=forDeployment?"Deploy a Vodia PBX":"Amazon Web Services";
  $("modalText").textContent="Checking the saved AWS connection…";
  renderModalSteps([["Loading","Reading the saved connection, Marketplace visibility, and available regions."]]);
  $("modalPrimary").textContent="Checking…";
  $("modalPrimary").disabled=true;
  $("modalPrimary").dataset.flow="aws-loading";
  $("modalBackdrop").hidden=false;
  try{
    const r=await fetch("/control-api/aws/overview",{credentials:"same-origin"});
    const p=await r.json(),a=p.aws||{};
    if(!a.configured){
      $("modalText").textContent="AWS is not connected yet. The customer dashboard does not ask for or display the Role ARN or External ID. Run the one-time secure AWS connection setup from an MCP client, then return here.";
      renderModalSteps([
        ["One-time setup","Use the Vodia AWS connection MCP App."],
        ["Secure verification","STS AssumeRole is tested before the profile is saved."],
        ["Return here","The dashboard will detect the saved profile automatically."]
      ]);
      $("modalPrimary").textContent="Copy AWS setup command";
      $("modalPrimary").dataset.flow="aws-copy-setup";
      return;
    }
    const account=a.profile?.account||a.connection?.account||"Connected account";
    const listingCount=a.marketplace?.listingCount??0;
    const regionCount=a.regions?.count??0;
    $("modalText").textContent=forDeployment
      ? `AWS account ${account} is connected. Marketplace discovery found ${listingCount} Vodia listing(s), and ${regionCount} deployment region(s) are available.`
      : `AWS account ${account} is connected and reusable. Marketplace discovery found ${listingCount} Vodia listing(s); ${regionCount} deployment region(s) are available.`;
    renderModalSteps([
      ["Connection","Saved AWS profile verified through STS."],
      ["Marketplace",`${listingCount} Vodia listing(s) visible.`],
      ["Regions",`${regionCount} EC2 region(s) available.`]
    ]);
    $("modalPrimary").textContent=forDeployment?"Copy deployment command":"Test AWS now";
    $("modalPrimary").dataset.flow=forDeployment?"aws-copy-deploy":"aws";
  }catch(e){
    $("modalText").textContent="AWS overview could not be loaded. Use Test to retry the live connection.";
    renderModalSteps([["Retry","The control API could not load the AWS overview."]]);
    $("modalPrimary").textContent="Test AWS now";
    $("modalPrimary").dataset.flow="aws";
  }finally{
    $("modalPrimary").disabled=false;
  }
}
function openFlow(key){
  if(key==="aws") return openAwsFlow(false);
  const f=flows[key]; if(!f)return;
  $("modalEyebrow").textContent=f.eyebrow;$("modalTitle").textContent=f.title;$("modalText").textContent=f.text;
  renderModalSteps(f.steps);
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
  if(w==="deploy-aws")return openAwsFlow(true);
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
  if(flow==="aws-copy-setup"){
    const ok=await copyText("aws_connect_customer_account");
    $("modalPrimary").textContent=ok?"Copied ✓":"Copy failed";
    $("modalText").textContent=ok
      ?"Paste the copied command into your MCP client once. After the AWS profile is saved, this dashboard will detect it automatically."
      :"Copy the MCP tool name aws_connect_customer_account and invoke it from your MCP client.";
    return;
  }
  if(flow==="aws-copy-deploy"){
    const command="Plan a Vodia PBX deployment on AWS using my saved AWS connection. First verify the Marketplace subscription and show me the deployment plan before making any changes.";
    const ok=await copyText(command);
    $("modalPrimary").textContent=ok?"Copied ✓":"Copy failed";
    $("modalText").textContent=ok
      ?"Paste the command into your MCP client. The existing DryRun and explicit approval guard remain in place."
      :"Open your MCP client and ask it to plan a Vodia PBX deployment using the saved AWS connection.";
    return;
  }
  if(["aws","cloudflare","microsoft","pbx"].includes(flow)){
    const old=$("modalPrimary").textContent;
    $("modalPrimary").disabled=true;$("modalPrimary").textContent="Testing…";
    try{
      const r=await fetch("/control-api/test/"+flow,{method:"POST",credentials:"same-origin"});
      const p=await r.json(),state=connectionState(flow,p);
      $("modalText").textContent=p.ok?`Live check passed: ${state.detail}`:`Live check failed: ${p.error||"Not configured"}`;
      await loadConnections();
      if(flow==="aws"&&p.ok) await openAwsFlow(false);
    }finally{
      $("modalPrimary").disabled=false;
      if(flow!=="aws")$("modalPrimary").textContent=old;
    }
    return;
  }
  location.href="/admin/";
});
document.querySelectorAll("[data-admin]").forEach(el=>el.addEventListener("click",()=>location.href="/admin/"));
const themeToggle=$("themeToggle");
if(themeToggle) themeToggle.addEventListener("click",()=>applyTheme(document.documentElement.dataset.theme==="dark"?"light":"dark"));
initTheme();
Promise.all([loadHealth(),loadConnections(),loadActivity()]);
