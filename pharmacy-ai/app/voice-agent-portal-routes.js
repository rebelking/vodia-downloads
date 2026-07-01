'use strict';

const fs = require('fs');
const path = require('path');

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function requirePortalAdmin(req, res, next) {
  if (!req.session || !req.session.portalUser) {
    return res.redirect('/portal/login');
  }

  if (req.session.portalUser.role !== 'admin') {
    return res.status(403).send(`
      <html>
        <head><title>Forbidden</title></head>
        <body style="font-family:Arial,sans-serif;padding:32px;">
          <h2>Admin access required</h2>
          <p>This page is only available to portal administrators.</p>
          <p><a href="/portal/orders">Back to portal</a></p>
        </body>
      </html>
    `);
  }

  return next();
}

function getVoiceAgentScriptPath() {
  return process.env.VOICE_AGENT_LOCAL_SCRIPT ||
    path.join(__dirname, 'voice-agent', 'vodia-pharmacy-ai-voice-agent.local.js');
}

function readVoiceAgentScript() {
  const scriptPath = getVoiceAgentScriptPath();

  if (!fs.existsSync(scriptPath)) {
    return {
      exists: false,
      scriptPath,
      content: ''
    };
  }

  return {
    exists: true,
    scriptPath,
    content: fs.readFileSync(scriptPath, 'utf8')
  };
}

function renderVoiceAgentPage(result) {
  const scriptContent = result.exists
    ? result.content
    : '// Voice Agent local script was not found yet.\n// Expected path:\n// ' + result.scriptPath + '\n\n// Run the installer again or regenerate the script during install.';

  const statusBadge = result.exists
    ? '<span class="badge ok">Ready</span>'
    : '<span class="badge warn">Not generated</span>';

  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Voice Agent Script - Vodia Pharmacy AI</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg: #0f172a;
      --card: #111827;
      --muted: #94a3b8;
      --text: #e5e7eb;
      --border: #334155;
      --accent: #38bdf8;
      --ok: #22c55e;
      --warn: #f59e0b;
    }
    body {
      margin: 0;
      font-family: Arial, sans-serif;
      background: radial-gradient(circle at top, #1e293b, #020617);
      color: var(--text);
    }
    .wrap {
      max-width: 1180px;
      margin: 0 auto;
      padding: 28px;
    }
    .top {
      display: flex;
      justify-content: space-between;
      gap: 16px;
      align-items: center;
      margin-bottom: 18px;
    }
    .card {
      background: rgba(15, 23, 42, 0.92);
      border: 1px solid var(--border);
      border-radius: 18px;
      padding: 22px;
      box-shadow: 0 18px 50px rgba(0,0,0,.35);
    }
    h1 {
      margin: 0 0 6px 0;
      font-size: 28px;
    }
    p {
      color: var(--muted);
      line-height: 1.5;
    }
    .badge {
      display: inline-block;
      padding: 7px 11px;
      border-radius: 999px;
      font-size: 13px;
      font-weight: bold;
      margin-left: 8px;
    }
    .ok {
      background: rgba(34,197,94,.15);
      color: #86efac;
      border: 1px solid rgba(34,197,94,.45);
    }
    .warn {
      background: rgba(245,158,11,.15);
      color: #fcd34d;
      border: 1px solid rgba(245,158,11,.45);
    }
    .buttons {
      display: flex;
      flex-wrap: wrap;
      gap: 10px;
      margin: 18px 0;
    }
    button, a.button {
      border: 0;
      background: var(--accent);
      color: #00111f;
      padding: 11px 15px;
      border-radius: 10px;
      font-weight: bold;
      cursor: pointer;
      text-decoration: none;
      display: inline-block;
    }
    a.secondary, button.secondary {
      background: #1f2937;
      color: var(--text);
      border: 1px solid var(--border);
    }
    textarea {
      width: 100%;
      min-height: 68vh;
      box-sizing: border-box;
      background: #020617;
      color: #dbeafe;
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 16px;
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      font-size: 13px;
      line-height: 1.45;
      white-space: pre;
    }
    .note {
      font-size: 13px;
      color: var(--muted);
      margin-top: 10px;
    }
    .path {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      color: #bfdbfe;
      word-break: break-all;
    }
    #copyStatus {
      color: #86efac;
      font-weight: bold;
      margin-left: 8px;
    }
  </style>
</head>
<body>
  <div class="wrap">
    <div class="top">
      <div>
        <h1>Vodia Voice Agent Script ${statusBadge}</h1>
        <p>Copy this script into the Vodia Voice Agent JavaScript field. Put the OpenAI key in the Vodia Voice Agent OpenAI key field, not inside this script.</p>
      </div>
      <div>
        <a class="button secondary" href="/portal/orders">Back to Portal</a>
      </div>
    </div>

    <div class="card">
      <p>Script path:</p>
      <p class="path">${escapeHtml(result.scriptPath)}</p>

      <div class="buttons">
        <button type="button" onclick="copyScript()">Copy Script</button>
        <a class="button secondary" href="/portal/voice-agent/download">Download Script</a>
        <a class="button secondary" href="/portal/voice-agent/raw" target="_blank">Open Raw</a>
        <span id="copyStatus"></span>
      </div>

      <textarea id="voiceScript" spellcheck="false">${escapeHtml(scriptContent)}</textarea>

      <p class="note">
        Security note: this page is admin-only because the generated local script contains the pharmacy backend secret.
      </p>
    </div>
  </div>

  <script>
    async function copyScript() {
      var text = document.getElementById('voiceScript').value;
      var status = document.getElementById('copyStatus');

      try {
        await navigator.clipboard.writeText(text);
        status.textContent = 'Copied';
      } catch (e) {
        document.getElementById('voiceScript').focus();
        document.getElementById('voiceScript').select();
        document.execCommand('copy');
        status.textContent = 'Copied';
      }

      setTimeout(function () {
        status.textContent = '';
      }, 3000);
    }
  </script>
</body>
</html>`;
}

function installVoiceAgentPortalRoutes(app) {
  app.get('/portal/voice-agent', requirePortalAdmin, function (req, res) {
    const result = readVoiceAgentScript();
    res.setHeader('Cache-Control', 'no-store');
    res.send(renderVoiceAgentPage(result));
  });

  app.get('/portal/voice-agent/raw', requirePortalAdmin, function (req, res) {
    const result = readVoiceAgentScript();

    if (!result.exists) {
      return res.status(404).type('text/plain').send('Voice Agent local script not found at: ' + result.scriptPath);
    }

    res.setHeader('Cache-Control', 'no-store');
    res.type('text/plain').send(result.content);
  });

  app.get('/portal/voice-agent/download', requirePortalAdmin, function (req, res) {
    const result = readVoiceAgentScript();

    if (!result.exists) {
      return res.status(404).type('text/plain').send('Voice Agent local script not found at: ' + result.scriptPath);
    }

    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="vodia-pharmacy-ai-voice-agent.local.js"');
    res.send(result.content);
  });
}

module.exports = {
  installVoiceAgentPortalRoutes
};
