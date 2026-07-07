const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const router = express.Router();

router.use(express.urlencoded({ extended: true, limit: '1mb' }));
router.use(express.json({ limit: '1mb' }));

const DATA_DIR = process.env.PHARMACY_SETTINGS_DIR || path.join(__dirname, '..', 'data');
const SETTINGS_FILE = path.join(DATA_DIR, 'admin-settings.json');

const defaults = {
  smtp: {
    enabled: false,
    host: '',
    port: 587,
    secure: false,
    username: '',
    passwordSecret: '',
    fromEmail: '',
    fromName: 'Vodia Pharmacy AI',
    lastTestAt: '',
    lastTestStatus: ''
  },
  security: {
    maskPhi: true,
    requireRevealVerification: true,
    auditReveal: true,
    email2fa: false,
    totp2fa: false,
    passkey: false,
    sso: false
  },
  tenant: {
    pbxServer: '',
    tenantId: '',
    allowedHost: '',
    allowedPbxSourceIp: '',
    webhookSecretHash: '',
    webhookSecretLast4: '',
    webhookSecretRotatedAt: ''
  },
  crm: {
    provider: 'none',
    baseUrl: '',
    apiKeySecret: '',
    patientLookupEndpoint: '',
    doctorLookupEndpoint: '',
    pharmacyLocationEndpoint: '',
    lookupMode: 'crm_first',
    lastTestAt: '',
    lastTestStatus: ''
  }
};

function clone(obj) {
  return JSON.parse(JSON.stringify(obj));
}

function merge(base, incoming) {
  const out = clone(base);
  if (!incoming || typeof incoming !== 'object') return out;

  for (const key of Object.keys(incoming)) {
    if (
      incoming[key] &&
      typeof incoming[key] === 'object' &&
      !Array.isArray(incoming[key]) &&
      out[key] &&
      typeof out[key] === 'object'
    ) {
      out[key] = merge(out[key], incoming[key]);
    } else {
      out[key] = incoming[key];
    }
  }

  return out;
}

function loadSettings() {
  try {
    if (!fs.existsSync(SETTINGS_FILE)) return clone(defaults);
    const raw = fs.readFileSync(SETTINGS_FILE, 'utf8');
    return merge(defaults, JSON.parse(raw));
  } catch {
    return clone(defaults);
  }
}

function saveSettings(settings) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const tmp = SETTINGS_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, SETTINGS_FILE);

  try {
    fs.chmodSync(SETTINGS_FILE, 0o600);
  } catch {}
}

function getSecretKey() {
  const raw =
    process.env.PHARMACY_SETTINGS_KEY ||
    process.env.SETTINGS_ENCRYPTION_KEY ||
    process.env.PHARMACY_SECRET ||
    process.env.X_PHARMACY_SECRET ||
    process.env.SESSION_SECRET ||
    '';

  if (!raw) return null;
  return crypto.createHash('sha256').update(String(raw)).digest();
}

function sealSecret(value) {
  if (!value) return '';

  const key = getSecretKey();

  if (!key) {
    return 'plain:' + Buffer.from(String(value), 'utf8').toString('base64');
  }

  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([
    cipher.update(String(value), 'utf8'),
    cipher.final()
  ]);
  const tag = cipher.getAuthTag();

  return [
    'enc',
    iv.toString('base64'),
    tag.toString('base64'),
    encrypted.toString('base64')
  ].join(':');
}

function openSecret(value) {
  if (!value) return '';

  if (value.startsWith('plain:')) {
    return Buffer.from(value.slice(6), 'base64').toString('utf8');
  }

  if (!value.startsWith('enc:')) return '';

  const key = getSecretKey();
  if (!key) return '';

  const parts = value.split(':');
  if (parts.length !== 4) return '';

  const iv = Buffer.from(parts[1], 'base64');
  const tag = Buffer.from(parts[2], 'base64');
  const encrypted = Buffer.from(parts[3], 'base64');

  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAuthTag(tag);

  return Buffer.concat([
    decipher.update(encrypted),
    decipher.final()
  ]).toString('utf8');
}

function htmlEscape(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function checked(value) {
  return value ? 'checked' : '';
}

function selected(a, b) {
  return String(a) === String(b) ? 'selected' : '';
}

function maskSecret(value) {
  return value ? 'Configured' : 'Not configured';
}

function isAdminRequest(req) {
  if (process.env.ALLOW_ADMIN_SETTINGS_WITHOUT_SESSION === 'true') return true;

  const s = req.session || {};

  return Boolean(
    s.isAdmin ||
    s.admin ||
    s.adminId ||
    s.adminUser ||
    s.userId ||
    s.authenticated ||
    s.loggedIn ||
    s.role === 'admin' ||
    s.user?.role === 'admin' ||
    s.user?.isAdmin ||
    s.account?.role === 'admin'
  );
}

function requireAdmin(req, res, next) {
  if (isAdminRequest(req)) return next();

  res.status(401).send(`
    <!doctype html>
    <html>
      <head>
        <title>Admin Login Required</title>
        <style>
          body { font-family: Arial, sans-serif; background:#f6f7fb; padding:40px; }
          .card { max-width:680px; margin:auto; background:white; border-radius:16px; padding:28px; box-shadow:0 12px 35px rgba(0,0,0,.08); }
          a { color:#155EEF; font-weight:700; }
        </style>
      </head>
      <body>
        <div class="card">
          <h1>Admin login required</h1>
          <p>This settings page is restricted to portal admins.</p>
          <p><a href="/portal">Go to login</a> &nbsp; | &nbsp; <a href="/portal">Go to portal</a></p>
        </div>
      </body>
    </html>
  `);
}

function boolFromBody(req, name) {
  return req.body[name] === 'on' || req.body[name] === 'true' || req.body[name] === '1';
}

function renderPage(res, options = {}) {
  const settings = loadSettings();

  const smtpConfigured = Boolean(settings.smtp.host && settings.smtp.fromEmail);
  const tenantConfigured = Boolean(settings.tenant.pbxServer && settings.tenant.tenantId);
  const crmConfigured = settings.crm.provider !== 'none' && Boolean(settings.crm.baseUrl);
  const secretKeyConfigured = Boolean(getSecretKey());

  const message = options.message || '';
  const error = options.error || '';
  const oneTimeWebhookSecret = options.oneTimeWebhookSecret || '';

  res.send(`<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Pharmacy AI Settings</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    :root {
      --bg:#f5f7fb;
      --card:#ffffff;
      --text:#172033;
      --muted:#667085;
      --line:#e5e7eb;
      --blue:#155EEF;
      --green:#07884f;
      --red:#b42318;
      --amber:#b54708;
    }

    * { box-sizing:border-box; }

    body {
      margin:0;
      font-family: Arial, Helvetica, sans-serif;
      background:var(--bg);
      color:var(--text);
    }

    header {
      background:#0b1220;
      color:white;
      padding:22px 28px;
    }

    header h1 {
      margin:0;
      font-size:24px;
    }

    header p {
      margin:8px 0 0;
      color:#cbd5e1;
    }

    main {
      max-width:1180px;
      margin:24px auto;
      padding:0 18px 60px;
    }

    .topnav {
      display:flex;
      flex-wrap:wrap;
      gap:10px;
      margin-bottom:18px;
    }

    .topnav a {
      text-decoration:none;
      color:var(--blue);
      background:white;
      border:1px solid var(--line);
      padding:10px 14px;
      border-radius:999px;
      font-weight:700;
    }

    .grid {
      display:grid;
      grid-template-columns:repeat(4,minmax(0,1fr));
      gap:14px;
      margin-bottom:18px;
    }

    .status-card {
      background:white;
      border:1px solid var(--line);
      border-radius:16px;
      padding:16px;
      box-shadow:0 8px 22px rgba(0,0,0,.04);
    }

    .status-card strong {
      display:block;
      margin-bottom:8px;
      font-size:15px;
    }

    .pill {
      display:inline-block;
      padding:5px 10px;
      border-radius:999px;
      font-size:12px;
      font-weight:700;
    }

    .ok { background:#dcfae6; color:#067647; }
    .warn { background:#fef0c7; color:#93370d; }
    .bad { background:#fee4e2; color:#912018; }
    .neutral { background:#eef4ff; color:#3538cd; }

    .card {
      background:var(--card);
      border:1px solid var(--line);
      border-radius:18px;
      padding:22px;
      margin-bottom:18px;
      box-shadow:0 10px 30px rgba(0,0,0,.05);
    }

    h2 {
      margin:0 0 8px;
      font-size:20px;
    }

    .sub {
      color:var(--muted);
      margin:0 0 18px;
      line-height:1.45;
    }

    label {
      display:block;
      font-weight:700;
      margin:14px 0 6px;
    }

    input, select {
      width:100%;
      padding:11px 12px;
      border:1px solid #d0d5dd;
      border-radius:10px;
      font-size:14px;
      background:white;
    }

    .row {
      display:grid;
      grid-template-columns:1fr 1fr;
      gap:14px;
    }

    .check {
      display:flex;
      align-items:center;
      gap:10px;
      margin:10px 0;
      font-weight:600;
    }

    .check input {
      width:auto;
    }

    .actions {
      display:flex;
      flex-wrap:wrap;
      gap:10px;
      margin-top:18px;
    }

    button {
      border:0;
      background:var(--blue);
      color:white;
      border-radius:10px;
      padding:11px 16px;
      font-weight:800;
      cursor:pointer;
    }

    button.secondary {
      background:#344054;
    }

    button.warning {
      background:#b54708;
    }

    .notice {
      border-radius:14px;
      padding:14px 16px;
      margin-bottom:18px;
      font-weight:700;
    }

    .notice.success {
      background:#dcfae6;
      color:#067647;
    }

    .notice.error {
      background:#fee4e2;
      color:#912018;
    }

    code {
      display:block;
      padding:12px;
      border-radius:12px;
      background:#101828;
      color:#e5e7eb;
      overflow:auto;
      white-space:pre-wrap;
    }

    .secret-box {
      border:1px solid #fdb022;
      background:#fffaeb;
      padding:14px;
      border-radius:14px;
      margin-bottom:16px;
    }

    .tiny {
      font-size:12px;
      color:var(--muted);
    }

    @media (max-width:900px) {
      .grid, .row { grid-template-columns:1fr; }
    }
  </style>
</head>
<body>
  <header>
    <h1>Pharmacy AI Admin Settings</h1>
    <p>SMTP, security posture, tenant binding, and CRM integration foundation.</p>
  </header>

  <main>
    <div class="topnav">
      <a href="/portal">Portal</a>
      <a href="/admin">Admin</a>
      <a href="/portal/settings">Settings</a>
      <a href="/health">Health</a>
    </div>

    ${message ? `<div class="notice success">${htmlEscape(message)}</div>` : ''}
    ${error ? `<div class="notice error">${htmlEscape(error)}</div>` : ''}

    <div class="grid">
      <div class="status-card">
        <strong>SMTP</strong>
        <span class="pill ${smtpConfigured ? 'ok' : 'warn'}">${smtpConfigured ? 'Configured' : 'Needs setup'}</span>
      </div>
      <div class="status-card">
        <strong>PHI Protection</strong>
        <span class="pill ${settings.security.maskPhi ? 'ok' : 'bad'}">${settings.security.maskPhi ? 'Masking enabled' : 'Masking disabled'}</span>
      </div>
      <div class="status-card">
        <strong>Tenant Binding</strong>
        <span class="pill ${tenantConfigured ? 'ok' : 'warn'}">${tenantConfigured ? 'Configured' : 'Not configured'}</span>
      </div>
      <div class="status-card">
        <strong>CRM Mode</strong>
        <span class="pill ${crmConfigured ? 'ok' : 'neutral'}">${crmConfigured ? 'CRM configured' : 'Placeholder'}</span>
      </div>
    </div>

    <section class="card">
      <h2>SMTP / Email</h2>
      <p class="sub">Used for admin invites, password reset, refill alerts, test emails, and future 2FA email workflows.</p>

      <form method="post" action="/portal/settings/smtp">
        <div class="row">
          <div>
            <label>SMTP Host</label>
            <input name="host" value="${htmlEscape(settings.smtp.host)}" placeholder="smtp.example.com">
          </div>
          <div>
            <label>SMTP Port</label>
            <input name="port" type="number" value="${htmlEscape(settings.smtp.port)}" placeholder="587">
          </div>
        </div>

        <div class="row">
          <div>
            <label>SMTP Username</label>
            <input name="username" value="${htmlEscape(settings.smtp.username)}" autocomplete="off">
          </div>
          <div>
            <label>SMTP Password</label>
            <input name="password" type="password" value="" placeholder="${settings.smtp.passwordSecret ? 'Saved - enter new password to replace' : 'Not saved'}" autocomplete="new-password">
            <p class="tiny">Password is never displayed after saving. Secret storage: ${secretKeyConfigured ? 'encrypted' : 'local file protected; set PHARMACY_SETTINGS_KEY for encryption'}.</p>
          </div>
        </div>

        <div class="row">
          <div>
            <label>From Email</label>
            <input name="fromEmail" value="${htmlEscape(settings.smtp.fromEmail)}" placeholder="no-reply@example.com">
          </div>
          <div>
            <label>From Name</label>
            <input name="fromName" value="${htmlEscape(settings.smtp.fromName)}" placeholder="Vodia Pharmacy AI">
          </div>
        </div>

        <label class="check">
          <input type="checkbox" name="enabled" ${checked(settings.smtp.enabled)}>
          Enable SMTP email
        </label>

        <label class="check">
          <input type="checkbox" name="secure" ${checked(settings.smtp.secure)}>
          Use SMTPS / secure connection
        </label>

        <div class="actions">
          <button type="submit">Save SMTP Settings</button>
        </div>
      </form>

      <hr style="border:0;border-top:1px solid var(--line);margin:22px 0;">

      <form method="post" action="/portal/settings/smtp/test">
        <label>Send Test Email To</label>
        <input name="to" placeholder="admin@example.com">
        <div class="actions">
          <button class="secondary" type="submit">Send Test Email</button>
        </div>
        <p class="tiny">Last test: ${htmlEscape(settings.smtp.lastTestAt || 'Never')} — ${htmlEscape(settings.smtp.lastTestStatus || 'No status')}</p>
      </form>
    </section>

    <section class="card">
      <h2>Security Settings</h2>
      <p class="sub">This is the customer-facing control center for 2FA, passkeys, SSO, PHI masking, and audit posture.</p>

      <form method="post" action="/portal/settings/security">
        <label class="check"><input type="checkbox" name="maskPhi" ${checked(settings.security.maskPhi)}> Mask PHI by default</label>
        <label class="check"><input type="checkbox" name="requireRevealVerification" ${checked(settings.security.requireRevealVerification)}> Require verification before revealing patient details</label>
        <label class="check"><input type="checkbox" name="auditReveal" ${checked(settings.security.auditReveal)}> Audit every PHI reveal</label>

        <hr style="border:0;border-top:1px solid var(--line);margin:18px 0;">

        <label class="check"><input type="checkbox" name="email2fa" ${checked(settings.security.email2fa)}> Email 2FA foundation</label>
        <label class="check"><input type="checkbox" name="totp2fa" ${checked(settings.security.totp2fa)}> TOTP 2FA planned</label>
        <label class="check"><input type="checkbox" name="passkey" ${checked(settings.security.passkey)}> Passkey / WebAuthn planned</label>
        <label class="check"><input type="checkbox" name="sso" ${checked(settings.security.sso)}> SSO planned</label>

        <div class="actions">
          <button type="submit">Save Security Settings</button>
        </div>
      </form>
    </section>

    <section class="card">
      <h2>Tenant / Server Binding</h2>
      <p class="sub">Bind the app to the intended PBX server and tenant so the webhook cannot be reused from another tenant by mistake.</p>

      ${oneTimeWebhookSecret ? `
        <div class="secret-box">
          <strong>Webhook secret generated. Copy it now. It will not be shown again.</strong>
          <code>${htmlEscape(oneTimeWebhookSecret)}</code>
        </div>
      ` : ''}

      <form method="post" action="/portal/settings/tenant">
        <div class="row">
          <div>
            <label>PBX Server FQDN</label>
            <input name="pbxServer" value="${htmlEscape(settings.tenant.pbxServer)}" placeholder="pbx.example.com">
          </div>
          <div>
            <label>Tenant / Domain</label>
            <input name="tenantId" value="${htmlEscape(settings.tenant.tenantId)}" placeholder="pharmacy.example.com">
          </div>
        </div>

        <div class="row">
          <div>
            <label>Allowed Portal Host</label>
            <input name="allowedHost" value="${htmlEscape(settings.tenant.allowedHost)}" placeholder="pharmacyhub.example.com">
          </div>
          <div>
            <label>Allowed PBX Source IP</label>
            <input name="allowedPbxSourceIp" value="${htmlEscape(settings.tenant.allowedPbxSourceIp)}" placeholder="Optional">
          </div>
        </div>

        <p class="tiny">
          Webhook secret: ${htmlEscape(maskSecret(settings.tenant.webhookSecretHash))}
          ${settings.tenant.webhookSecretLast4 ? `(last 4: ${htmlEscape(settings.tenant.webhookSecretLast4)})` : ''}
        </p>

        <div class="actions">
          <button type="submit">Save Tenant Binding</button>
        </div>
      </form>

      <form method="post" action="/portal/settings/tenant/rotate-secret">
        <div class="actions">
          <button class="warning" type="submit">Generate / Rotate Webhook Secret</button>
        </div>
      </form>
    </section>

    <section class="card">
      <h2>CRM Integration</h2>
      <p class="sub">Foundation for CRM-first lookup. The safer model is to store external patient IDs locally, not the full patient profile.</p>

      <form method="post" action="/portal/settings/crm">
        <div class="row">
          <div>
            <label>CRM Provider</label>
            <select name="provider">
              <option value="none" ${selected(settings.crm.provider, 'none')}>None</option>
              <option value="custom_rest" ${selected(settings.crm.provider, 'custom_rest')}>Custom REST API</option>
              <option value="cliniko" ${selected(settings.crm.provider, 'cliniko')}>Cliniko / Clinkco</option>
              <option value="other" ${selected(settings.crm.provider, 'other')}>Other</option>
            </select>
          </div>
          <div>
            <label>Lookup Mode</label>
            <select name="lookupMode">
              <option value="crm_first" ${selected(settings.crm.lookupMode, 'crm_first')}>CRM-first lookup</option>
              <option value="local_only" ${selected(settings.crm.lookupMode, 'local_only')}>Local only</option>
              <option value="disabled" ${selected(settings.crm.lookupMode, 'disabled')}>Disabled</option>
            </select>
          </div>
        </div>

        <label>API Base URL</label>
        <input name="baseUrl" value="${htmlEscape(settings.crm.baseUrl)}" placeholder="https://crm.example.com/api">

        <label>API Key / Token</label>
        <input name="apiKey" type="password" value="" placeholder="${settings.crm.apiKeySecret ? 'Saved - enter new key to replace' : 'Not saved'}" autocomplete="new-password">

        <div class="row">
          <div>
            <label>Patient Lookup Endpoint</label>
            <input name="patientLookupEndpoint" value="${htmlEscape(settings.crm.patientLookupEndpoint)}" placeholder="/patients/lookup?phone={phone}">
          </div>
          <div>
            <label>Doctor Lookup Endpoint</label>
            <input name="doctorLookupEndpoint" value="${htmlEscape(settings.crm.doctorLookupEndpoint)}" placeholder="/doctors/{id}">
          </div>
        </div>

        <label>Pharmacy Location Endpoint</label>
        <input name="pharmacyLocationEndpoint" value="${htmlEscape(settings.crm.pharmacyLocationEndpoint)}" placeholder="/locations">

        <div class="actions">
          <button type="submit">Save CRM Settings</button>
        </div>

        <p class="tiny">Last CRM status: ${htmlEscape(settings.crm.lastTestAt || 'Never')} — ${htmlEscape(settings.crm.lastTestStatus || 'No status')}</p>
      </form>
    </section>
  </main>
</body>
</html>`);
}

router.get('/', requireAdmin, (req, res) => {
  renderPage(res);
});

router.get('/api', requireAdmin, (req, res) => {
  const settings = loadSettings();

  res.json({
    success: true,
    smtp: {
      enabled: settings.smtp.enabled,
      host: settings.smtp.host,
      port: settings.smtp.port,
      secure: settings.smtp.secure,
      username: settings.smtp.username ? 'configured' : '',
      password: settings.smtp.passwordSecret ? 'configured' : '',
      fromEmail: settings.smtp.fromEmail,
      fromName: settings.smtp.fromName,
      lastTestAt: settings.smtp.lastTestAt,
      lastTestStatus: settings.smtp.lastTestStatus
    },
    security: settings.security,
    tenant: {
      ...settings.tenant,
      webhookSecretHash: settings.tenant.webhookSecretHash ? 'configured' : ''
    },
    crm: {
      ...settings.crm,
      apiKeySecret: settings.crm.apiKeySecret ? 'configured' : ''
    }
  });
});

router.post('/smtp', requireAdmin, (req, res) => {
  const settings = loadSettings();

  settings.smtp.enabled = boolFromBody(req, 'enabled');
  settings.smtp.host = String(req.body.host || '').trim();
  settings.smtp.port = Number(req.body.port || 587);
  settings.smtp.secure = boolFromBody(req, 'secure');
  settings.smtp.username = String(req.body.username || '').trim();
  settings.smtp.fromEmail = String(req.body.fromEmail || '').trim();
  settings.smtp.fromName = String(req.body.fromName || '').trim() || 'Vodia Pharmacy AI';

  if (Object.prototype.hasOwnProperty.call(req.body, 'password') && String(req.body.password || '') !== '') {
    settings.smtp.passwordSecret = sealSecret(String(req.body.password));
  }

  saveSettings(settings);
  renderPage(res, { message: 'SMTP settings saved.' });
});

router.post('/smtp/test', requireAdmin, async (req, res) => {
  const settings = loadSettings();

  try {
    let nodemailer;
    try {
      nodemailer = require('nodemailer');
    } catch {
      throw new Error('Nodemailer is not installed. Run: npm install nodemailer --save');
    }

    const to = String(req.body.to || '').trim();
    if (!to || !to.includes('@')) throw new Error('Enter a valid test recipient email.');
    if (!settings.smtp.host) throw new Error('SMTP host is required.');
    if (!settings.smtp.fromEmail) throw new Error('From email is required.');

    const pass = openSecret(settings.smtp.passwordSecret);

    const transportOptions = {
      host: settings.smtp.host,
      port: Number(settings.smtp.port || 587),
      secure: Boolean(settings.smtp.secure)
    };

    if (settings.smtp.username) {
      transportOptions.auth = {
        user: settings.smtp.username,
        pass
      };
    }

    const transporter = nodemailer.createTransport(transportOptions);

    await transporter.verify();

    const from = settings.smtp.fromName
      ? `"${settings.smtp.fromName.replaceAll('"', '')}" <${settings.smtp.fromEmail}>`
      : settings.smtp.fromEmail;

    await transporter.sendMail({
      from,
      to,
      subject: 'Vodia Pharmacy AI SMTP Test',
      text: 'SMTP test successful from Vodia Pharmacy AI.',
      html: '<p>SMTP test successful from <strong>Vodia Pharmacy AI</strong>.</p>'
    });

    settings.smtp.lastTestAt = new Date().toISOString();
    settings.smtp.lastTestStatus = 'success';
    saveSettings(settings);

    renderPage(res, { message: 'Test email sent successfully.' });
  } catch (err) {
    settings.smtp.lastTestAt = new Date().toISOString();
    settings.smtp.lastTestStatus = 'failed: ' + String(err.message || err);
    saveSettings(settings);

    renderPage(res, { error: 'SMTP test failed: ' + String(err.message || err) });
  }
});

router.post('/security', requireAdmin, (req, res) => {
  const settings = loadSettings();

  settings.security.maskPhi = boolFromBody(req, 'maskPhi');
  settings.security.requireRevealVerification = boolFromBody(req, 'requireRevealVerification');
  settings.security.auditReveal = boolFromBody(req, 'auditReveal');
  settings.security.email2fa = boolFromBody(req, 'email2fa');
  settings.security.totp2fa = boolFromBody(req, 'totp2fa');
  settings.security.passkey = boolFromBody(req, 'passkey');
  settings.security.sso = boolFromBody(req, 'sso');

  saveSettings(settings);
  renderPage(res, { message: 'Security settings saved.' });
});

router.post('/tenant', requireAdmin, (req, res) => {
  const settings = loadSettings();

  settings.tenant.pbxServer = String(req.body.pbxServer || '').trim();
  settings.tenant.tenantId = String(req.body.tenantId || '').trim();
  settings.tenant.allowedHost = String(req.body.allowedHost || '').trim();
  settings.tenant.allowedPbxSourceIp = String(req.body.allowedPbxSourceIp || '').trim();

  saveSettings(settings);
  renderPage(res, { message: 'Tenant binding settings saved.' });
});

router.post('/tenant/rotate-secret', requireAdmin, (req, res) => {
  const settings = loadSettings();

  const secret = crypto.randomBytes(32).toString('base64url');
  settings.tenant.webhookSecretHash = crypto.createHash('sha256').update(secret).digest('hex');
  settings.tenant.webhookSecretLast4 = secret.slice(-4);
  settings.tenant.webhookSecretRotatedAt = new Date().toISOString();

  saveSettings(settings);

  renderPage(res, {
    message: 'Webhook secret generated. Copy it now.',
    oneTimeWebhookSecret: secret
  });
});

router.post('/crm', requireAdmin, (req, res) => {
  const settings = loadSettings();

  settings.crm.provider = String(req.body.provider || 'none').trim();
  settings.crm.lookupMode = String(req.body.lookupMode || 'crm_first').trim();
  settings.crm.baseUrl = String(req.body.baseUrl || '').trim();
  settings.crm.patientLookupEndpoint = String(req.body.patientLookupEndpoint || '').trim();
  settings.crm.doctorLookupEndpoint = String(req.body.doctorLookupEndpoint || '').trim();
  settings.crm.pharmacyLocationEndpoint = String(req.body.pharmacyLocationEndpoint || '').trim();

  if (Object.prototype.hasOwnProperty.call(req.body, 'apiKey') && String(req.body.apiKey || '') !== '') {
    settings.crm.apiKeySecret = sealSecret(String(req.body.apiKey));
  }

  settings.crm.lastTestAt = new Date().toISOString();
  settings.crm.lastTestStatus = settings.crm.provider === 'none'
    ? 'disabled'
    : 'saved - connector test not enabled yet';

  saveSettings(settings);
  renderPage(res, { message: 'CRM integration settings saved.' });
});

module.exports = router;
