import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {purchaseError,readLicenseEvidence} from './license-read.mjs';

let passed=0;
async function test(name,fn){await fn(); console.log('PASS '+name); passed++;}
const html=readFileSync(process.argv[2]+'/ui/msp-guided-app.html','utf8');
const backend=readFileSync(process.argv[2]+'/aws-marketplace-ec2-deploy-v1.js','utf8');
const helper=readFileSync(new URL('./ui-helpers.js',import.meta.url),'utf8');
const chunk=(s,start,end)=>{const a=s.indexOf(start);assert(a>=0,start);const b=s.indexOf(end,a+start.length);assert(b>a,end);return s.slice(a,b);};
function ui() {
  const nodes=new Map(); const handlers={};
  const $=id=>{
    if(!nodes.has(id)) nodes.set(id,{value:'',textContent:'',disabled:false,dataset:{},
      classList:{classes:new Set(),add(x){this.classes.add(x)},remove(x){this.classes.delete(x)}},
      addEventListener(type,fn){handlers[id+':'+type]=fn},scrollIntoView(){}});
    return nodes.get(id);
  };
  const sandbox={$,handlers,nodes,Set,JSON,Boolean,Number,String,Error,performance,
    window:{openai:{callTool:async()=>({})}},debugLog(){},redactDebug:x=>x,
    reportSize(){},setMsg:(id,msg)=>{$(id).textContent=msg},updatePlanButton(){},
    renderMarketplaceSubscription(active,msg,r){sandbox.rendered=r;},
    customerId:()=>sandbox.customer,customer:'customer-a',VODIA_MARKETPLACE_PRODUCT_ID:'prod-test'};
  vm.createContext(sandbox);
  const globals=`let currentMarketplaceQuote=null, currentMarketplaceSubscription=null, currentDeploymentPlan=null,
    marketplaceSubscriptionActive=false;
    let currentMarketplaceOffer={offerId:'offer',plans:[{dimensionKey:'ca4'}]};
    globalThis.state=()=>({currentMarketplaceQuote,currentMarketplaceSubscription,currentDeploymentPlan,marketplaceSubscriptionActive});`;
  vm.runInContext(globals+helper+
    chunk(html,'  async function callTool(','  function toolErrorText(')+
    chunk(html,'  function dataFrom(','\n  function ')+
    chunk(html,'  async function checkMarketplaceSubscription(){','\n  function ')+
    chunk(html,'  $("prepareMarketplaceQuote").addEventListener("click",async()=>{','\n  $("marketplaceApproval")'),sandbox);
  return sandbox;
}
await test('MCP error envelopes preserve unsupported action, structured errors, and JSON text',async()=>{
  const c=ui();
  for(const response of [
    {isError:true,content:[{type:'text',text:'This action is not supported.'}]},
    {structuredContent:{success:false,error:{message:'This action is not supported.'}}},
    {content:[{type:'text',text:JSON.stringify({ok:false,error:'This action is not supported.'})}]}]){
    c.window.openai.callTool=async()=>response;
    await assert.rejects(c.callTool('aws_marketplace_prepare_vodia_purchase',{}),/This action is not supported/);
  }
});
await test('actual quote click shows original error and restores controls; clears old approval',async()=>{
  const c=ui(); c.$('marketplacePlanSelect').value='0'; c.$('marketplaceQuantity').value='1';
  c.$('marketplaceApproval').value='OLD APPROVAL';
  c.window.openai.callTool=async()=>({isError:true,content:[{type:'text',text:'This action is not supported.'}]});
  await c.handlers['prepareMarketplaceQuote:click']();
  assert.match(c.$('marketplaceErrorV76').textContent,/This action is not supported/);
  assert.equal(c.$('prepareMarketplaceQuote').disabled,false);
  assert.equal(c.$('acceptMarketplaceQuote').disabled,true);
  assert.equal(c.$('marketplaceApproval').value,'');
  assert.equal(c.state().currentMarketplaceQuote,null);
});
await test('successful preparation never accepts a purchase and quantity change invalidates quote',async()=>{
  const c=ui(); const calls=[]; c.$('marketplacePlanSelect').value='0';
  c.window.openai.callTool=async(name)=>{calls.push(name);return {structuredContent:{data:{agreementRequestId:'q1',confirmation:'APPROVE',expiresAt:'later'}}};};
  await c.handlers['prepareMarketplaceQuote:click']();
  assert.equal(c.state().currentMarketplaceQuote.agreementRequestId,'q1');
  assert.deepEqual(calls,['aws_marketplace_prepare_vodia_purchase']);
  assert.equal(c.$('acceptMarketplaceQuote').disabled,true);
  c.handlers['marketplaceQuantity:input']();
  assert.equal(c.state().currentMarketplaceQuote,null);
});
await test('duplicate quote click is ignored and changed customer response is discarded',async()=>{
  const c=ui(); c.$('marketplacePlanSelect').value='0'; let resolve; let calls=0;
  c.window.openai.callTool=()=>{calls++;return new Promise(r=>{resolve=r})};
  const first=c.handlers['prepareMarketplaceQuote:click']();
  await c.handlers['prepareMarketplaceQuote:click'](); assert.equal(calls,1);
  c.customer='customer-b'; resolve({structuredContent:{agreementRequestId:'q',confirmation:'APPROVE'}});
  await first; assert.equal(c.state().currentMarketplaceQuote,null);
  assert.match(c.$('marketplaceErrorV76').textContent,/Customer changed/);
});
await test('refresh failure invalidates stale deployment approval and shows error',async()=>{
  const c=ui(); c.$('deploymentApproval').value='OLD DEPLOY';
  c.window.openai.callTool=async()=>({structuredContent:{ok:false,error:'AccessDenied'}});
  assert.equal(await c.checkMarketplaceSubscription(),false);
  assert.equal(c.$('applyDeployment').disabled,true);
  assert.equal(c.$('deploymentApproval').value,'');
  assert.equal(c.$('approvalBox').dataset.planId,'');
  assert.equal(c.$('continueMarketplace').disabled,true);
  assert.equal(c.$('refreshMarketplaceLicensesV76').disabled,false);
  assert.match(c.$('marketplaceErrorV76').textContent,/AccessDenied/);
});
await test('AWS diagnostics preserve request ID without copying credentials',async()=>{
  const e=purchaseError({name:'ValidationException',message:'This action is not supported.',
    $metadata:{requestId:'req-123',httpStatusCode:400},credentials:'SECRET'});
  assert.match(e.message,/CreateAgreementRequest; ValidationException; request req-123; HTTP 400/);
  assert(!e.message.includes('SECRET'));
});
const fakeSDK=(send)=>({LicenseManagerClient:class{constructor(c){this.region=c.region}send(c){return send(c,this.region)}},
  ListReceivedLicensesCommand:class{constructor(input){this.input=input;this.kind='list'}},
  GetLicenseUsageCommand:class{constructor(input){this.input=input;this.kind='usage'}}});
await test('license refresh paginates, deduplicates, rejects unrelated SKU, uses home region, does not unlock',async()=>{
  const calls=[];const sdk=fakeSDK(async(c,region)=>{
    calls.push([c.kind,c.input,region]);
    if(c.kind==='usage') return {LicenseUsage:{EntitlementUsages:[{Name:'ca4',Unit:'Count',ConsumedValue:'1',MaxCount:'2'}]}};
    if(c.input.NextToken) return {Licenses:[{LicenseArn:'wrong',ProductSKU:'another-product'}]};
    return {Licenses:[{LicenseArn:'license1',ProductSKU:'prod-test',HomeRegion:'us-west-2',Status:'AVAILABLE',Entitlements:[{Name:'ca4',Unit:'Count',MaxCount:2}]}],NextToken:'page2'};
  });
  const r=await readLicenseEvidence({sdk,credentials:{},productId:'prod-test',productCode:'code-test'});
  assert.equal(r.status,'READ');assert.equal(r.licenses.length,1);
  assert.equal(r.licenses[0].usage[0].ConsumedValue,'1');
  assert.equal(calls.find(x=>x[0]==='usage')[2],'us-west-2');
  assert.equal(r.deploymentCapacityVerified,false);
});
await test('license denied, empty, and partial results are never spare capacity',async()=>{
  for(const mode of ['denied','empty','partial']){
    const sdk=fakeSDK(async c=>{
      if(mode==='denied'||c.kind==='usage') throw {name:'AccessDeniedException',message:'Denied'};
      return {Licenses:mode==='empty'?[]:[{LicenseArn:'l',ProductSKU:'p'}]};
    });
    const r=await readLicenseEvidence({sdk,productId:'p'});
    assert.equal(r.status,{denied:'UNKNOWN',empty:'NO_EXACT_SKU_MATCH',partial:'PARTIAL'}[mode]);
    assert.equal(r.deploymentCapacityVerified,false);
  }
});
await test('agreement refresh reads all pages',async()=>{
  let count=0;
  const c={SearchAgreementsCommand:class{constructor(input){this.input=input}},agreementClient:()=>({send:async()=>{
    count++;return count===1?{agreementViewSummaries:[{agreementId:'first'}],nextToken:'page2'}:{agreementViewSummaries:[{agreementId:'second'}]};
  }})};
  vm.createContext(c);vm.runInContext(chunk(backend,'async function checkSubscription(','\nasync function '),c);
  const r=await c.checkSubscription('role','external','product');
  assert.equal(r.agreements.length,2);assert.equal(count,2);
});
await test('partial regional inventory cannot mark an agreement AVAILABLE',async()=>{
  const c={scanVodiaManagedInventory:async()=>({regionsScanned:2,regionErrors:[{region:'r',error:'Denied'}]}),
    agreementInventoryMatches:()=>[],reconcileMarketplaceAgreementUsage:async()=>({status:'AVAILABLE'}),
    readLicenseEvidence:async()=>({status:'UNKNOWN'}),customerCredentials:()=>({}),configuredMarketplaceProductCode:()=>'',AWS_DISCOVERY_REGION:'us-east-1'};
  vm.createContext(c);vm.runInContext(chunk(backend,'async function enrichMarketplaceSubscriptionUsage(','\n\nconst VODIA_TERMINATE'),c);
  const r=await c.enrichMarketplaceSubscriptionUsage('r','e','c','p',{agreements:[{agreementId:'a'}]});
  assert.equal(r.availableAgreementCount,0);
  assert.equal(r.agreements[0].deploymentUsage.status,'RECONCILIATION_NEEDED');
});
await test('existing launch and purchase approval guards remain; new inventory gates cover plan/apply',async()=>{
  assert.match(backend,/if\(launchMatches.length\) throw agreementInUseError/);
  assert.match(backend,/if\(planningMatches.length\) throw agreementInUseError/);
  assert.equal((backend.match(/MARKETPLACE_INVENTORY_INCOMPLETE/g)||[]).length,2);
  assert.match(html,/confirmation!==currentMarketplaceQuote.confirmation/);
  assert.match(html,/target="_blank" rel="noopener noreferrer"/);
  assert.match(html,/id="marketplaceUrlV76" readonly/);
});
console.log(`${passed} regression tests passed; no AWS calls or purchases.`);
