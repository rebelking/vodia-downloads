#!/usr/bin/env node
/* Checks public/data/guide.json before you deploy:
 * unique ids, images that exist, pins inside the picture, no empty text.
 * Usage: npm run check */
'use strict';
const fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..', 'public');
const guide = JSON.parse(fs.readFileSync(path.join(ROOT, 'data', 'guide.json'), 'utf8'));
const problems = [], ids = new Set();
let topics = 0, shots = 0, pins = 0;
const where = (c, s, i) => `${c.id}/${s.id}${i !== undefined ? ' part ' + String.fromCharCode(65 + i) : ''}`;
for(const c of guide.chapters || []){
  if(!c.id || !c.title) problems.push(`chapter missing id or title: ${JSON.stringify(c).slice(0, 60)}`);
  for(const s of c.scenarios || []){
    topics++;
    if(!s.id || !s.title) problems.push(`${c.id}: topic missing id or title`);
    if(ids.has(s.id)) problems.push(`${c.id}/${s.id}: topic id is used twice`); ids.add(s.id);
    const parts = s.parts || [s];
    parts.forEach((p, i) => {
      const w = where(c, s, s.parts ? i : undefined);
      if(p.image){
        shots++;
        if(!fs.existsSync(path.join(ROOT, p.image))) problems.push(`${w}: image not found: ${p.image}`);
        if(!p.alt) problems.push(`${w}: image has no alt text`);
      }
      (p.steps || []).forEach((st, n) => {
        if(!st.text || !st.text.trim()) problems.push(`${w} step ${n + 1}: empty text`);
        const hasX = typeof st.x === 'number', hasY = typeof st.y === 'number';
        if(hasX !== hasY) problems.push(`${w} step ${n + 1}: needs both x and y, or neither`);
        if(hasX){ pins++;
          if(!p.image) problems.push(`${w} step ${n + 1}: has a pin but the part has no image`);
          if(st.x < 0 || st.x > 100 || st.y < 0 || st.y > 100) problems.push(`${w} step ${n + 1}: pin outside the picture (x ${st.x}, y ${st.y})`);
        }
      });
    });
  }
}

// languages: every English string should have a translation
const SKIP = new Set(['image','id','x','y','wide','narrow']), strings = new Set();
(function walk(o){ if(Array.isArray(o)) o.forEach(walk); else if(o && typeof o === 'object'){ for(const k in o) if(!SKIP.has(k)) walk(o[k]); } else if(typeof o === 'string' && o.trim()) strings.add(o); })(guide);
JSON.parse(fs.readFileSync(path.join(ROOT, 'data', 'ui-strings.json'), 'utf8')).forEach(s => strings.add(s));
const idx = JSON.parse(fs.readFileSync(path.join(ROOT, 'data', 'i18n', 'index.json'), 'utf8')).languages || {};
for(const [name, e] of Object.entries(idx)){
  const f = path.join(ROOT, 'data', 'i18n', e.file);
  if(!fs.existsSync(f)){ problems.push(`language ${name}: file not found: data/i18n/${e.file}`); continue; }
  const map = JSON.parse(fs.readFileSync(f, 'utf8')).map || {};
  const missing = [...strings].filter(s => !map[s]);
  console.log(`${name}: ${strings.size - missing.length} of ${strings.size} strings translated`);
  if(missing.length) problems.push(`language ${name}: ${missing.length} untranslated (run: npm run strings -- ${e.file.replace(/\.json$/, '')})`);
}
console.log(`${(guide.chapters || []).length} chapters, ${topics} topics, ${shots} screenshots, ${pins} pins`);
if(problems.length){ console.log(`\n${problems.length} problem(s):`); problems.forEach(p => console.log(' - ' + p)); process.exit(1); }
console.log('All good.');
