const $=(id)=>document.getElementById(id);
let csrf="";

async function api(path,opts={}){
  const headers={"content-type":"application/json",...(opts.headers||{})};
  if(csrf) headers["x-vodia-csrf"]=csrf;
  const r=await fetch(path,{credentials:"same-origin",...opts,headers});
  const j=await r.json().catch(()=>({}));
  if(!r.ok) throw new Error(j.error||("HTTP "+r.status));
  return j;
}

function setMessage(text,bad=false){
  const el=$("pageMessage"); if(!el)return;
  el.textContent=text||""; el.className="message "+(bad?"bad":"good");
}
function status(id,configured){
  const el=$(id+"Status"); if(!el)return;
  el.textContent=configured?"Configured":"Not configured";
  el.className="status"+(configured?" ok":"");
}
function fill(formName,data){
  const form=document.querySelector(`[data-form="${formName}"]`);
  if(!form||!data)return;
  for(const [k,v] of Object.entries(data)){
    const el=form.elements.namedItem(k);
    if(!el || el.type==="password" || v==null) continue;
    el.value=String(v);
  }
}
async function refresh(){
  const p=await api("/admin-connections-api/providers");
  for(const name of ["pbx","aws","microsoft","cloudflare"]){
    const d=p.providers?.[name]||{};
    status(name,Boolean(d.configured));
    fill(name,d);
  }
}
async function login(key){
  const p=await api("/admin-connections-api/login",{method:"POST",body:JSON.stringify({key})});
  csrf=p.csrf||"";
  $("loginCard").hidden=true;
  $("connectionsView").hidden=false;
  $("logoutBtn").hidden=false;
  await refresh();
}

$("loginForm").addEventListener("submit",async(e)=>{
  e.preventDefault();
  const msg=$("loginMessage");
  msg.textContent="";
  try{
    await login($("adminKey").value);
    $("adminKey").value="";
  }catch(err){
    msg.textContent=err.message;
    msg.className="message bad";
  }
});

$("logoutBtn").addEventListener("click",async()=>{
  try{await api("/admin-connections-api/logout",{method:"POST",body:"{}"});}catch{}
  location.reload();
});

$("refreshBtn").addEventListener("click",()=>refresh().catch(e=>setMessage(e.message,true)));

document.querySelectorAll(".provider-form").forEach(form=>form.addEventListener("submit",async(e)=>{
  e.preventDefault();
  const provider=form.dataset.form;
  const data=Object.fromEntries(new FormData(form).entries());
  for(const key of Object.keys(data)){if(data[key]==="")delete data[key];}
  const btn=form.querySelector('button[type="submit"]');
  const old=btn.textContent;
  btn.disabled=true;
  btn.textContent="Saving…";
  try{
    await api("/admin-connections-api/providers/"+provider,{method:"PUT",body:JSON.stringify(data)});
    setMessage(provider+" settings saved.");
    [...form.querySelectorAll('input[type="password"]')].forEach(x=>x.value="");
    await refresh();
  }catch(err){
    setMessage(err.message,true);
  }finally{
    btn.disabled=false;
    btn.textContent=old;
  }
}));

document.querySelectorAll("[data-test]").forEach(btn=>btn.addEventListener("click",async()=>{
  const provider=btn.dataset.test;
  const old=btn.textContent;
  btn.disabled=true;
  btn.textContent="Testing…";
  try{
    const p=await api("/admin-connections-api/providers/"+provider+"/test",{method:"POST",body:"{}"});
    setMessage(p.message||provider+" connection test passed.");
  }catch(err){
    setMessage(provider+" test failed: "+err.message,true);
  }finally{
    btn.disabled=false;
    btn.textContent=old;
  }
}));

(async()=>{
  try{
    const p=await api("/admin-connections-api/providers");
    $("loginCard").hidden=true;
    $("connectionsView").hidden=false;
    $("logoutBtn").hidden=false;
    for(const name of ["pbx","aws","microsoft","cloudflare"]){
      status(name,Boolean(p.providers?.[name]?.configured));
      fill(name,p.providers?.[name]||{});
    }
  }catch{}
})();