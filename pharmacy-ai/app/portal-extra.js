'use strict';

const bcrypt = require('bcrypt');
const crypto = require('crypto');
const nodemailer = require('nodemailer');

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function generatePassword() {
  return crypto.randomBytes(12).toString('base64').replace(/[^a-zA-Z0-9]/g, '').slice(0, 16);
}

function createEmailTransporter() {
  return nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: String(process.env.SMTP_SECURE || 'false') === 'true',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS
    }
  });
}

function sanitizeBody(body) {
  const safe = Object.assign({}, body || {});

  [
    'password',
    'password_hash',
    'SMTP_PASS',
    'smtp_pass',
    'secret',
    'token'
  ].forEach(function (key) {
    if (safe[key]) safe[key] = '[redacted]';
  });

  if (safe.csv_data) {
    safe.csv_data = '[csv_data redacted, length=' + String(body.csv_data || '').length + ']';
  }

  return safe;
}

function getClientIp(req) {
  return String(req.headers['x-forwarded-for'] || req.ip || req.connection.remoteAddress || '').split(',')[0].trim();
}

function inferAction(req) {
  const path = req.path || '';

  if (path.includes('/admin/users') && path.includes('/reset-password')) return 'user_reset_password';
  if (path.includes('/admin/users') && path.includes('/disable')) return 'user_disabled';
  if (path.includes('/admin/users') && path.includes('/enable')) return 'user_enabled';
  if (path === '/admin/users') return 'user_created';

  if (path.includes('/admin/patients/import-csv')) return 'patients_csv_import';
  if (path === '/admin/patients') return 'patient_saved';

  if (path.includes('/admin/medications/import-csv')) return 'medications_csv_import';
  if (path.includes('/admin/medications') && path.includes('/update')) return 'medication_updated';
  if (path === '/admin/medications') return 'medication_saved';

  if (path.includes('/portal/orders') && path.includes('/quick')) return 'refill_quick_status_update';
  if (path.includes('/portal/orders') && path.includes('/update')) return 'refill_status_notes_update';

  if (path.includes('/portal/forgot-password')) return 'forgot_password_requested';

  return req.method + ' ' + path;
}

function inferEntityType(req) {
  const path = req.path || '';

  if (path.includes('/admin/users')) return 'portal_user';
  if (path.includes('/admin/patients')) return 'patient';
  if (path.includes('/admin/medications')) return 'medication';
  if (path.includes('/portal/orders')) return 'refill_request';
  if (path.includes('/portal/forgot-password')) return 'portal_user';

  return 'unknown';
}

function inferEntityId(req) {
  const path = req.path || '';
  const match = path.match(/\/(\d+)(\/|$)/);

  if (match) return match[1];

  if (req.body && req.body.id) return String(req.body.id);

  return '';
}

function insertAuditLog(openDb, req, data) {
  const user = (req.session && req.session.portalUser) || {};
  const db = openDb();

  db.run(
    `
      INSERT INTO audit_logs
      (actor_user_id, actor_name, actor_username, actor_role, action, entity_type, entity_id, summary, before_json, after_json, ip_address)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `,
    [
      user.id || null,
      user.name || '',
      user.username || '',
      user.role || '',
      data.action || inferAction(req),
      data.entity_type || inferEntityType(req),
      data.entity_id || inferEntityId(req),
      data.summary || '',
      data.before_json ? JSON.stringify(data.before_json) : '',
      data.after_json ? JSON.stringify(data.after_json) : '',
      getClientIp(req)
    ],
    function (err) {
      db.close();

      if (err) {
        console.error('Audit log insert failed:', err.message);
      }
    }
  );
}

function auditPostMiddleware(openDb) {
  return function (req, res, next) {
    const method = String(req.method || '').toUpperCase();
    const path = req.path || '';

    const shouldAudit =
      ['POST', 'PATCH', 'DELETE'].includes(method) &&
      (
        path.startsWith('/admin/') ||
        path.startsWith('/portal/orders')
      );

    if (!shouldAudit) {
      return next();
    }

    res.on('finish', function () {
      if (res.statusCode >= 400) return;
      if (!req.session || !req.session.portalUser) return;

      insertAuditLog(openDb, req, {
        action: inferAction(req),
        entity_type: inferEntityType(req),
        entity_id: inferEntityId(req),
        summary: method + ' ' + path,
        after_json: sanitizeBody(req.body)
      });
    });

    next();
  };
}

async function sendTempPasswordEmail(user, temporaryPassword) {
  if (!user.email) {
    return {
      sent: false,
      reason: 'No email address on file.'
    };
  }

  if (!process.env.SMTP_HOST || !process.env.SMTP_USER || !process.env.SMTP_PASS || !process.env.EMAIL_FROM) {
    return {
      sent: false,
      reason: 'SMTP settings are missing.'
    };
  }

  const portalUrl = process.env.PORTAL_LOGIN_URL || 'https://pharmacy.audiomercy.com/portal/login';
  const transporter = createEmailTransporter();

  const subject = 'Vodia Pharmacy Portal Password Reset';

  const text = `
Hello ${user.name || user.username},

A temporary password was generated for your Vodia Pharmacy Portal account.

Portal:
${portalUrl}

Username:
${user.username}

Temporary password:
${temporaryPassword}

Please log in and keep this information secure.
`;

  const html = `
    <h2>Vodia Pharmacy Portal Password Reset</h2>
    <p>Hello ${escapeHtml(user.name || user.username)},</p>
    <p>A temporary password was generated for your Vodia Pharmacy Portal account.</p>
    <p><strong>Portal:</strong><br><a href="${escapeHtml(portalUrl)}">${escapeHtml(portalUrl)}</a></p>
    <p><strong>Username:</strong><br>${escapeHtml(user.username)}</p>
    <p><strong>Temporary password:</strong><br>${escapeHtml(temporaryPassword)}</p>
    <p>Please log in and keep this information secure.</p>
  `;

  const info = await transporter.sendMail({
    from: process.env.EMAIL_FROM,
    to: user.email,
    subject: subject,
    text: text,
    html: html
  });

  return {
    sent: true,
    accepted: info.accepted,
    rejected: info.rejected,
    messageId: info.messageId
  };
}

function forgotPasswordPage(message, isError) {
  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Forgot Password</title>
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
  <style>
    body {
      font-family: Arial, sans-serif;
      background:
        linear-gradient(90deg, rgba(245, 248, 250, 0.05), rgba(245, 248, 250, 0.96)),
        url('/assets/images/pharmacy-login.png');
      background-size: cover;
      background-position: center;
      display: flex;
      align-items: center;
      justify-content: flex-end;
      height: 100vh;
      margin: 0;
      padding-right: 9%;
    }
    .box {
      background: rgba(255, 255, 255, 0.94);
      padding: 34px;
      border-radius: 18px;
      width: 390px;
      box-shadow: 0 14px 40px rgba(23, 32, 51, 0.20);
      backdrop-filter: blur(8px);
    }
    h2 {
      margin-top: 0;
      color: #172033;
    }
    p {
      color: #5f6b7a;
      line-height: 1.45;
    }
    input, button {
      width: 100%;
      box-sizing: border-box;
      padding: 12px;
      font-size: 15px;
      margin-top: 10px;
    }
    input {
      border: 1px solid #d7dce2;
      border-radius: 9px;
    }
    button {
      background: #0f766e;
      color: white;
      border: 0;
      border-radius: 9px;
      cursor: pointer;
      font-weight: bold;
      margin-top: 18px;
    }
    .message {
      margin-top: 14px;
      padding: 10px;
      border-radius: 8px;
      background: ${isError ? '#fee2e2' : '#dcfce7'};
      border: 1px solid ${isError ? '#fecaca' : '#86efac'};
      color: #172033;
      font-size: 14px;
    }
    a {
      color: #0f766e;
      text-decoration: none;
    }
  </style>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <form class="box" method="post" action="/portal/forgot-password">
    <h2>Forgot Password</h2>
    <p>Enter your username or email. If the account has an email address, a temporary password will be sent.</p>

    <input name="identity" placeholder="Username or email" required>

    <button type="submit">Send Temporary Password</button>

    ${message ? `<div class="message">${escapeHtml(message)}</div>` : ''}

    <p><a href="/portal/login">Back to login</a></p>
  </form>
</body>
</html>
`;
}

function adminHistoryPage(rows, search) {
  const renderedRows = rows.map(function (row) {
    return `
      <tr>
        <td>#${row.id}</td>
        <td>
          <strong>${escapeHtml(row.actor_name || row.actor_username || 'System')}</strong><br>
          <span class="muted">${escapeHtml(row.actor_role || '')}</span>
        </td>
        <td>
          <strong>${escapeHtml(row.action)}</strong><br>
          <span class="muted">${escapeHtml(row.entity_type || '')} ${escapeHtml(row.entity_id || '')}</span>
        </td>
        <td>${escapeHtml(row.summary || '')}</td>
        <td><pre>${escapeHtml(row.after_json || '')}</pre></td>
        <td>
          <span class="muted">${escapeHtml(row.ip_address || '')}</span><br>
          ${escapeHtml(row.created_at || '')}
        </td>
      </tr>
    `;
  }).join('');

  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Change History</title>
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
  <style>
    body {
      font-family: Arial, sans-serif;
      background: #f5f5f5;
      margin: 0;
      color: #222;
    }
    header {
      background: #172033;
      color: white;
      padding: 16px 24px;
    }
    header a {
      color: white;
      margin-right: 14px;
      text-decoration: none;
    }
    main {
      padding: 24px;
    }
    .card {
      background: white;
      border-radius: 10px;
      padding: 20px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      margin-bottom: 20px;
    }
    input, button {
      font-size: 14px;
      padding: 9px;
    }
    input {
      width: 420px;
      max-width: 100%;
      border: 1px solid #d7dce2;
      border-radius: 8px;
    }
    button {
      background: #172033;
      color: white;
      border: 0;
      border-radius: 6px;
      cursor: pointer;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      background: white;
      border-radius: 10px;
      overflow: hidden;
    }
    th, td {
      padding: 10px;
      border-bottom: 1px solid #ddd;
      vertical-align: top;
      text-align: left;
    }
    th {
      background: #eef0f4;
    }
    .muted {
      color: #666;
      font-size: 13px;
    }
    pre {
      white-space: pre-wrap;
      max-width: 480px;
      overflow-wrap: anywhere;
      background: #f8f8f8;
      padding: 8px;
      border-radius: 6px;
      font-size: 12px;
    }
  </style>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <header>
    <h2>Vodia Pharmacy Admin</h2>
    <a href="/portal/orders">Agent Orders</a><a href="/portal/chat">Chat</a>
    <a href="/admin/users">Admin Users</a>
    <a href="/admin/patients">Patients</a>
    <a href="/admin/medications">Medications</a>
    <a href="/admin/history">History</a><a href="/portal/settings">Settings</a><a href="/portal/voice-agent">Voice Agent</a>
    <a href="/portal/logout">Logout</a>
  </header>
  <main>
    <div class="card">
      <h3>Change History</h3>
      <p class="muted">Shows admin and agent changes from this point forward.</p>
      <form method="get" action="/admin/history">
        <input name="q" value="${escapeHtml(search || '')}" placeholder="Search action, user, entity, summary">
        <button type="submit">Search</button>
        <a href="/admin/history">Clear</a>
      </form>
    </div>

    <table>
      <thead>
        <tr>
          <th>ID</th>
          <th>User</th>
          <th>Action</th>
          <th>Summary</th>
          <th>Submitted Data</th>
          <th>IP / Date</th>
        </tr>
      </thead>
      <tbody>
        ${renderedRows || '<tr><td colspan="6">No history found.</td></tr>'}
      </tbody>
    </table>
  </main>
</body>
</html>
`;
}

function installPortalExtraRoutes(app, openDb) {
  app.get('/favicon.ico', function (req, res) {
    res.redirect('/assets/favicon.svg');
  });

  app.get('/portal/forgot-password', function (req, res) {
    res.send(forgotPasswordPage('', false));
  });

  app.post('/portal/forgot-password', function (req, res) {
    const identity = String(req.body.identity || '').trim();

    if (!identity) {
      return res.status(400).send(forgotPasswordPage('Username or email is required.', true));
    }

    const db = openDb();

    db.get(
      `
        SELECT id, name, email, username, active
        FROM portal_users
        WHERE username = ?
        OR lower(email) = lower(?)
        LIMIT 1
      `,
      [identity, identity],
      function (err, user) {
        if (err) {
          db.close();
          console.error('Forgot password lookup failed:', err.message);
          return res.status(500).send(forgotPasswordPage('Password reset system error.', true));
        }

        if (!user || user.active !== 1 || !user.email) {
          db.close();

          return res.send(forgotPasswordPage(
            'If this account exists and has an email address, a temporary password will be sent.',
            false
          ));
        }

        const temporaryPassword = generatePassword();

        bcrypt.hash(temporaryPassword, 12, function (hashErr, passwordHash) {
          if (hashErr) {
            db.close();
            return res.status(500).send(forgotPasswordPage('Could not generate temporary password.', true));
          }

          db.run(
            `
              UPDATE portal_users
              SET password_hash = ?, updated_at = CURRENT_TIMESTAMP
              WHERE id = ?
            `,
            [passwordHash, user.id],
            async function (updateErr) {
              db.close();

              if (updateErr) {
                return res.status(500).send(forgotPasswordPage('Could not update password.', true));
              }

              try {
                await sendTempPasswordEmail(user, temporaryPassword);
              } catch (emailErr) {
                console.error('Forgot password email failed:', emailErr.message);
                return res.status(500).send(forgotPasswordPage('Temporary password was created, but email failed. Contact admin.', true));
              }

              insertAuditLog(openDb, req, {
                action: 'forgot_password_temp_password_sent',
                entity_type: 'portal_user',
                entity_id: String(user.id),
                summary: 'Temporary password emailed for ' + user.username,
                after_json: {
                  username: user.username,
                  email: user.email
                }
              });

              return res.send(forgotPasswordPage(
                'If this account exists and has an email address, a temporary password will be sent.',
                false
              ));
            }
          );
        });
      }
    );
  });

  app.get('/admin/history', function (req, res, next) {
    if (!req.session || !req.session.portalUser) {
      return res.redirect('/portal/login');
    }

    if (req.session.portalUser.role !== 'admin') {
      return res.status(403).send('Access denied');
    }

    const q = String(req.query.q || '').trim();
    const db = openDb();

    let whereSql = '';
    let params = [];

    if (q) {
      whereSql = `
        WHERE lower(
          ifnull(actor_name, '') || ' ' ||
          ifnull(actor_username, '') || ' ' ||
          ifnull(actor_role, '') || ' ' ||
          ifnull(action, '') || ' ' ||
          ifnull(entity_type, '') || ' ' ||
          ifnull(entity_id, '') || ' ' ||
          ifnull(summary, '') || ' ' ||
          ifnull(after_json, '')
        ) LIKE lower(?)
      `;
      params = ['%' + q + '%'];
    }

    db.all(
      `
        SELECT id, actor_user_id, actor_name, actor_username, actor_role, action, entity_type, entity_id, summary, before_json, after_json, ip_address, created_at
        FROM audit_logs
        ${whereSql}
        ORDER BY created_at DESC
        LIMIT 300
      `,
      params,
      function (err, rows) {
        db.close();

        if (err) {
          return res.status(500).send('History error: ' + err.message);
        }

        res.send(adminHistoryPage(rows, q));
      }
    );
  });
}

module.exports = {
  auditPostMiddleware,
  installPortalExtraRoutes
};
