/* Vodia User Portal Guide — browser app.
 * Content:    data/guide.json        (chapters → topics → steps; images in /images)
 * Languages:  data/i18n/index.json   lists the extra languages; each has a file
 *             data/i18n/<file>.json  mapping every English sentence to its translation.
 *             English is built in. The language switch shows English + every listed language.
 * Flags:      data/flags.json        (MIT-licensed country-flag-icons, 3x2)
 */
(async function(){
  'use strict';
  const getJSON = async (url, fallback) => {
    try { const r = await fetch(url, {cache:'no-cache'}); if(!r.ok) throw new Error(r.status); return await r.json(); }
    catch(e){ return fallback; }
  };
  const [ORIG, FLAGS_RAW, IDX] = await Promise.all([
    getJSON('data/guide.json', null),
    getJSON('data/flags.json', {region:[], lang:[], svg:{}}),
    getJSON('data/i18n/index.json', {languages:{}})
  ]);
  if(!ORIG){ document.getElementById('view').innerHTML = '<p class="empty">Couldn\'t load the guide. Please refresh the page.</p>'; return; }
  let DATA = ORIG;
  const SAVED = IDX.languages || {};   // language name -> {file, code, flag}
  const LOADED = {};                   // language name -> map (English -> translation)
  let TR = null;                       // active map (null = English)
  const tr = s => (TR && TR[s]) || s;
  const $ = s => document.querySelector(s);
  const view = $('#view'), nav = $('#nav'), q = $('#q');
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const ready = s => !!s.image || !!(s.parts && s.parts.some(p=>p.image));

  function renderNav(activeCh){
    nav.innerHTML = DATA.chapters.map((c,i) => `
      <div class="nav-ch">
        <a href="#/${c.id}" ${c.id===activeCh?'aria-current="page"':''}><span class="n">${i+1}</span><span>${esc(c.title)}</span></a>
        ${c.id===activeCh ? `<ul class="nav-sc">${c.scenarios.map(s=>`
          <li><a href="#/${c.id}/${s.id}"><span>${esc(s.title)}</span><span class="dot ${ready(s)?'ready':''}" title="${ready(s)?tr('Illustrated'):tr('Screenshot coming soon')}"></span></a></li>`).join('')}</ul>` : ''}
      </div>`).join('');
  }

  function home(){
    document.title = DATA.title;
    view.innerHTML = `
      <section class="hero">
        <div>
          <h1>${esc(DATA.title)}</h1>
          <p class="lede" style="margin-bottom:0">${esc(DATA.subtitle)}. ${esc(tr('Pick a topic below, or search for what you want to do.'))}</p>
        </div>
        <div class="legend">
          <p>${esc(tr('Screenshots are marked with numbered pins. Each pin matches a step next to the picture. Select either one to highlight the other, and select a screenshot to enlarge it.'))}</p>
          <div class="legend-demo"><span class="pin" aria-hidden="true">1</span><span style="font-size:15px">${esc(tr('Click here to open the settings for your extension.'))}</span></div>
        </div>
      </section>
      <ol class="chapters">
        ${DATA.chapters.map((c,i)=>`<li><a href="#/${c.id}">
          <span class="n">${i+1}</span>
          <span><h2>${esc(c.title)}</h2><p>${esc(c.intro)}</p></span>
          <span class="count">${esc(tr(c.scenarios.length===1?'{n} topic':'{n} topics').replace('{n}',c.scenarios.length))}</span>
        </a></li>`).join('')}
      </ol>`;
    renderNav(null);
  }

  function partHTML(s){
    const pinned = s.steps.map((st,i)=>({...st,n:i+1})).filter(st => typeof st.x==='number' && typeof st.y==='number');
    const figure = s.image
      ? `<figure class="shot${s.narrow?' narrow':''}">
           <img src="${s.image}" alt="${esc(s.alt||s.title)}" data-zoom>
           ${pinned.map(p=>`<button class="pin" style="left:${p.x}%;top:${p.y}%" data-n="${p.n}" aria-label="${esc(tr('Step'))} ${p.n}">${p.n}</button>`).join('')}
           ${s.caption?`<figcaption>${esc(s.caption)}</figcaption>`:''}
         </figure>`
      : `<figure class="shot"><div class="placeholder"><div>
           <svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="9" cy="11" r="2"/><path d="m21 17-5-5-9 7"/></svg>
           <b>${esc(tr('Screenshot coming soon'))}</b>${esc(tr('This walkthrough is being written.'))}</div></div></figure>`;
    const steps = s.steps.length
      ? `<ol class="steps">${s.steps.map((st,i)=>{
          const hp = typeof st.x==='number';
          return `<li class="${hp?'has-pin':''}" data-n="${i+1}" ${hp?'tabindex="0"':''}><span class="num">${i+1}</span><p>${esc(st.text)}</p></li>`;}).join('')}</ol>`
      : `<p style="color:var(--muted);margin:0">${esc(tr('Step-by-step instructions will appear here.'))}</p>`;
    return `<div class="shot-wrap part${s.wide?' wide':''}">${figure}<div>${steps}</div></div>`;
  }

  function scenarioHTML(c, s){
    const parts = s.parts || [s];
    const multi = parts.length>1;
    const body = parts.map((pt,i)=> multi
      ? `<section class="stage"><h4><span class="stage-n">${String.fromCharCode(65+i)}</span>${esc(pt.title)}</h4>${pt.intro?`<p class="stage-intro">${esc(pt.intro)}</p>`:''}${partHTML(pt)}</section>`
      : partHTML(pt)).join('');
    const tips = s.tips && s.tips.length ? `<div class="tips"><b>${esc(tr('Good to know'))}</b><ul>${s.tips.map(t=>`<li>${esc(t)}</li>`).join('')}</ul></div>` : '';
    return `<article class="scenario" id="${c.id}--${s.id}">
      <header><h3>${esc(s.title)}<button class="linkcopy" data-link="#/${c.id}/${s.id}" aria-label="${esc(tr('Copy link to this topic'))}">${esc(tr('Copy link'))}</button></h3><p>${esc(s.summary)}</p></header>
      ${body}${tips}
    </article>`;
  }

  function chapter(cid, sid){
    const idx = DATA.chapters.findIndex(c=>c.id===cid);
    if(idx<0) return home();
    const c = DATA.chapters[idx], prev = DATA.chapters[idx-1], next = DATA.chapters[idx+1];
    document.title = `${c.title} · ${DATA.title}`;
    view.innerHTML = `
      <div class="crumbs"><a href="#/">${esc(tr('Guide'))}</a> / ${esc(tr('Chapter'))} ${idx+1}</div>
      <h1>${esc(c.title)}</h1>
      <p class="lede">${esc(c.intro)}</p>
      ${c.scenarios.map(s=>scenarioHTML(c,s)).join('')}
      <nav class="pager" aria-label="Chapters">
        ${prev?`<a href="#/${prev.id}"><small>${esc(tr('Previous'))}</small><b>${esc(prev.title)}</b></a>`:'<span></span>'}
        ${next?`<a href="#/${next.id}" style="text-align:right"><small>${esc(tr('Next'))}</small><b>${esc(next.title)}</b></a>`:''}
      </nav>`;
    renderNav(cid);
    const target = sid && document.getElementById(`${cid}--${sid}`);
    if(target) requestAnimationFrame(()=>target.scrollIntoView({block:'start'}));
    else window.scrollTo(0,0);
  }

  function search(term){
    const t = term.trim().toLowerCase();
    if(!t){ route(); return; }
    const hits = [];
    DATA.chapters.forEach(c=>c.scenarios.forEach(s=>{
      const hay = [s.title,s.summary,...(s.parts||[s]).flatMap(p=>[p.title||'',...(p.steps||[]).map(x=>x.text)]),...(s.tips||[])].join(' ').toLowerCase();
      if(hay.includes(t) || c.title.toLowerCase().includes(t)) hits.push({c,s});
    }));
    const hl = str => esc(str).replace(new RegExp(t.replace(/[.*+?^${}()|[\]\\]/g,'\\$&'),'gi'), m=>`<mark>${m}</mark>`);
    view.innerHTML = `<h1>${esc(tr('Search'))}</h1><p class="lede">${esc(tr(hits.length===1?'{n} result for “{q}”':'{n} results for “{q}”').replace('{n}',hits.length).replace('{q}',term))}</p>
      ${hits.length?`<ul class="results">${hits.map(({c,s})=>`<li><a href="#/${c.id}/${s.id}"><small>${esc(c.title)}</small><b>${hl(s.title)}</b><br><span style="color:var(--muted)">${hl(s.summary)}</span></a></li>`).join('')}</ul>`
      :`<p class="empty">${esc(tr('Nothing matches that yet. Try a shorter word, like “voicemail” or “forward”.'))}</p>`}`;
  }

  function route(){
    const parts = location.hash.replace(/^#\/?/,'').split('/').filter(Boolean);
    closeMenu();
    if(!parts.length) home(); else chapter(parts[0], parts[1]);
  }

  // pin <-> step sync
  function highlight(article, n){
    article.querySelectorAll('.pin,.steps li').forEach(el=>el.classList.toggle('on', el.dataset.n===String(n)));
  }
  view.addEventListener('click', e=>{
    const pin = e.target.closest('.pin'), li = e.target.closest('.steps li.has-pin');
    const art = e.target.closest('.part');
    if(pin && art){ highlight(art, pin.dataset.n); art.querySelector(`.steps li[data-n="${pin.dataset.n}"]`)?.scrollIntoView({block:'nearest',behavior:'smooth'}); return; }
    if(li && art){ highlight(art, li.dataset.n); return; }
    const img = e.target.closest('img[data-zoom]');
    if(img){ openLightbox(img.closest('.shot')); return; }
    const lc = e.target.closest('.linkcopy');
    if(lc){
      const url = location.href.split('#')[0] + lc.dataset.link;
      (navigator.clipboard?navigator.clipboard.writeText(url):Promise.reject()).then(()=>toast(tr('Link copied')),()=>toast(url));
    }
  });
  view.addEventListener('mouseover', e=>{
    const t = e.target.closest('.pin,.steps li.has-pin'); const art = e.target.closest('.part');
    if(t && art) highlight(art, t.dataset.n);
  });
  view.addEventListener('keydown', e=>{
    const li = e.target.closest('.steps li.has-pin');
    if(li && (e.key==='Enter'||e.key===' ')){ e.preventDefault(); highlight(li.closest('.part'), li.dataset.n); }
  });

  // lightbox keeps pins in place
  const lb = $('#lightbox'), lbFrame = $('#lbFrame');
  function openLightbox(fig){
    const clone = fig.cloneNode(true);
    clone.querySelector('figcaption')?.remove();
    clone.style.boxShadow='none'; clone.style.border='0';
    clone.querySelector('img').style.cursor='default';
    lbFrame.innerHTML=''; lbFrame.appendChild(clone);
    lb.classList.add('open'); $('#lbClose').focus();
  }
  function closeLightbox(){ lb.classList.remove('open'); lbFrame.innerHTML=''; }
  $('#lbClose').addEventListener('click', closeLightbox);
  lb.addEventListener('click', e=>{ if(e.target===lb) closeLightbox(); });
  document.addEventListener('keydown', e=>{ if(e.key==='Escape'){ closeLightbox(); closeMenu(); } });

  // mobile menu
  const sb = $('#sidebar'), mb = $('#menuBtn');
  function closeMenu(){ sb.classList.remove('open'); mb.setAttribute('aria-expanded','false'); }
  mb.addEventListener('click', ()=>{ const o = sb.classList.toggle('open'); mb.setAttribute('aria-expanded', String(o)); });
  document.addEventListener('click', e=>{ if(sb.classList.contains('open') && !sb.contains(e.target) && !mb.contains(e.target)) closeMenu(); });

  let tmr; function toast(msg){ const t=$('#toast'); t.textContent=msg; t.classList.add('show'); clearTimeout(tmr); tmr=setTimeout(()=>t.classList.remove('show'),1800); }

  let st; q.addEventListener('input', ()=>{ clearTimeout(st); st=setTimeout(()=>search(q.value),120); });
  window.addEventListener('hashchange', ()=>{ q.value=''; route(); });


  // ================= Languages =================
  const SKIP = new Set(['image','id','x','y','wide','narrow']);
  function mapData(o){
    if(Array.isArray(o)) return o.map(mapData);
    if(o && typeof o==='object'){ const r={}; for(const k in o) r[k] = SKIP.has(k) ? o[k] : mapData(o[k]); return r; }
    if(typeof o==='string') return (TR && TR[o]) || o;
    return o;
  }
  const RTL_CODES = /^(ar|he|fa|ur|ps|yi|sd|dv|ug|ckb)(-|$)/i;
  const LS = { get(k){ try{ return JSON.parse(localStorage.getItem(k)); }catch(e){ return null; } }, set(k,v){ try{ localStorage.setItem(k, JSON.stringify(v)); }catch(e){} } };
  const LANGS = ['English', ...Object.keys(SAVED)];
  let current = 'English';

  // flags: a language entry can name its flag directly ("flag": "JP"); otherwise it's matched by name
  const FLAGS = FLAGS_RAW;
  FLAGS.region.sort((x,y)=>y[0].length-x[0].length); FLAGS.lang.sort((x,y)=>y[0].length-x[0].length);
  function flagCode(lang){
    if(lang==='English') return 'US';
    if(SAVED[lang] && SAVED[lang].flag) return SAVED[lang].flag;
    const n=(lang||'').toLowerCase();
    for(const [k,c] of FLAGS.region) if(n.includes(k)) return c;
    for(const [k,c] of FLAGS.lang) if(n.includes(k)) return c;
    return null;
  }
  function flagHTML(lang){ const c=flagCode(lang), s=c && FLAGS.svg[c]; return s ? `<img class="flag" alt="" src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(s)}">` : ''; }

  async function loadLang(lang){
    if(LOADED[lang]) return LOADED[lang];
    const e = SAVED[lang]; if(!e) return null;
    const j = await getJSON('data/i18n/' + e.file, null);
    return (LOADED[lang] = j && j.map ? j.map : null);
  }
  function renderSwitch(){
    const html = LANGS.map(l=>`<button type="button" data-lang="${esc(l)}" aria-pressed="${l===current}" lang="${l==='English'?'en':esc((SAVED[l]&&SAVED[l].code)||'')}">${flagHTML(l)}<span>${esc(l)}</span></button>`).join('');
    document.querySelectorAll('[data-lang-switch]').forEach(el=>{ el.innerHTML = html; el.hidden = LANGS.length < 2; });
  }
  async function applyLang(lang){
    let map = null;
    if(lang!=='English'){ map = await loadLang(lang); if(!map){ toast("Couldn't load " + lang); lang='English'; } }
    current = lang; TR = map; DATA = map ? mapData(ORIG) : ORIG;
    const code = lang==='English' ? 'en' : (SAVED[lang] && SAVED[lang].code) || '';
    document.documentElement.lang = code;
    const rtl = RTL_CODES.test(code);
    document.querySelector('main').dir = rtl ? 'rtl' : 'ltr'; nav.dir = rtl ? 'rtl' : 'ltr';
    document.querySelectorAll('[data-i18n]').forEach(el=>{ el.textContent = tr(el.getAttribute('data-i18n')); });
    document.querySelectorAll('[data-i18n-ph]').forEach(el=>{ const t=tr(el.getAttribute('data-i18n-ph')); el.placeholder=t; el.setAttribute('aria-label',t); });
    LS.set('vodia-guide-lang', lang);
    renderSwitch();
    q.value=''; route();
  }
  document.addEventListener('click', e=>{
    const b = e.target.closest('[data-lang-switch] button'); if(!b) return;
    const lang = b.dataset.lang; if(lang!==current){ closeMenu(); applyLang(lang); }
  });

  // start in the visitor's last choice; otherwise match their browser language (e.g. ja → 日本語)
  let start = LS.get('vodia-guide-lang');
  if(!LANGS.includes(start)){
    const pref = (navigator.languages || [navigator.language || '']).map(x=>String(x).toLowerCase());
    start = LANGS.find(l => l!=='English' && SAVED[l].code && pref.some(p => p===SAVED[l].code.toLowerCase() || p.startsWith(SAVED[l].code.toLowerCase()+'-'))) || 'English';
  }
  await applyLang(start);
})();
