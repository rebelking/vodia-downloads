#!/usr/bin/env node
/* Lists the English text a language file is missing, so you can translate just that.
 *   npm run strings -- ja            -> prints missing strings for data/i18n/ja.json as JSON
 *   npm run strings -- ja --all      -> prints every string (to start a new language)
 * Paste the translations back into the "map" of that file: { "English text": "translation" }. */
'use strict';
const fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..', 'public', 'data');
const [file, flag] = process.argv.slice(2);
if(!file){ console.error('Usage: npm run strings -- <language-file-name> [--all]   e.g. npm run strings -- ja'); process.exit(1); }
const SKIP = new Set(['image','id','x','y','wide','narrow']);
const all = [], seen = new Set();
(function walk(o){
  if(Array.isArray(o)) o.forEach(walk);
  else if(o && typeof o === 'object'){ for(const k in o) if(!SKIP.has(k)) walk(o[k]); }
  else if(typeof o === 'string' && o.trim() && !seen.has(o)){ seen.add(o); all.push(o); }
})(JSON.parse(fs.readFileSync(path.join(ROOT, 'guide.json'), 'utf8')));
for(const s of JSON.parse(fs.readFileSync(path.join(ROOT, 'ui-strings.json'), 'utf8'))) if(!seen.has(s)){ seen.add(s); all.push(s); }
const f = path.join(ROOT, 'i18n', file.replace(/\.json$/, '') + '.json');
const map = fs.existsSync(f) ? (JSON.parse(fs.readFileSync(f, 'utf8')).map || {}) : {};
const out = flag === '--all' ? all : all.filter(s => !map[s]);
console.error(`${out.length} of ${all.length} strings ${flag === '--all' ? 'in total' : 'need translating'}.`);
console.log(JSON.stringify(Object.fromEntries(out.map(s => [s, ''])), null, 2));
