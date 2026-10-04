/* Vodia User Portal Guide — web server
 * Serves the site in ../public. No dependencies; needs Node.js 18 or newer.
 * Settings (environment variables or a .env file next to package.json):
 *   PORT  port to listen on (default 8080)
 *   HOST  address to listen on (default 0.0.0.0; use 127.0.0.1 behind nginx or a tunnel)
 */
'use strict';
const http = require('http');
const fs = require('fs');
const fsp = fs.promises;
const path = require('path');

loadDotEnv(path.join(__dirname, '..', '.env'));
const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const ROOT = path.resolve(__dirname, '..', 'public');

const MIME = { '.html':'text/html; charset=utf-8', '.css':'text/css; charset=utf-8', '.js':'text/javascript; charset=utf-8',
  '.json':'application/json; charset=utf-8', '.webp':'image/webp', '.png':'image/png', '.jpg':'image/jpeg', '.jpeg':'image/jpeg',
  '.gif':'image/gif', '.svg':'image/svg+xml', '.ico':'image/x-icon', '.txt':'text/plain; charset=utf-8', '.woff2':'font/woff2' };

function send(res, code, body){
  res.writeHead(code, { 'Content-Type':'text/plain; charset=utf-8', 'Cache-Control':'no-store' });
  res.end(body);
}

async function serve(req, res){
  if(req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'Method not allowed');
  let rel;
  try { rel = decodeURIComponent((req.url || '/').split('?')[0]); } catch(e){ return send(res, 400, 'Bad request'); }
  if(rel === '/healthz') return send(res, 200, 'ok');
  if(rel.endsWith('/')) rel += 'index.html';
  const file = path.resolve(ROOT, '.' + rel);
  if(!file.startsWith(ROOT + path.sep)) return send(res, 403, 'Forbidden');
  let stat;
  try { stat = await fsp.stat(file); } catch(e){ return send(res, 404, 'Not found'); }
  if(stat.isDirectory()){ res.writeHead(301, { Location: rel + '/' }); return res.end(); }
  const ext = path.extname(file).toLowerCase();
  res.writeHead(200, {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Content-Length': stat.size,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'strict-origin-when-cross-origin',
    // images rarely change; text and data are rechecked so edits show up straight away
    'Cache-Control': /\.(webp|png|jpe?g|gif|svg|woff2)$/.test(ext) ? 'public, max-age=86400' : 'no-cache'
  });
  if(req.method === 'HEAD') return res.end();
  fs.createReadStream(file).pipe(res);
}

http.createServer((req, res) => serve(req, res).catch(e => { console.error(e); if(!res.headersSent) send(res, 500, 'Server error'); }))
  .listen(PORT, HOST, () => console.log(`Vodia User Portal Guide on http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${PORT}`));

function loadDotEnv(file){
  try {
    for(const line of fs.readFileSync(file, 'utf8').split(/\r?\n/)){
      const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/);
      if(m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
    }
  } catch(e){}
}
