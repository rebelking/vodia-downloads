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

function statusLabel(status) {
  const labels = {
    active: 'Active',
    all: 'All',
    pending: 'Pending',
    called_back: 'Called Back',
    fulfilled: 'Fulfilled',
    needs_follow_up: 'Needs Follow-Up',
    out_of_stock: 'Out of Stock'
  };

  return labels[status] || status;
}

function generatePassword() {
  return crypto.randomBytes(12).toString('base64').replace(/[^a-zA-Z0-9]/g, '').slice(0, 16);
}

function normalizePhoneE164(phone) {
  const raw = String(phone || '').trim();

  if (!raw) return '';

  // Already has country code. Keep plus and digits only.
  if (raw.startsWith('+')) {
    const digits = raw.replace(/\D/g, '');
    const e164 = '+' + digits;

    if (/^\+\d{8,15}$/.test(e164)) {
      return e164;
    }

    return '';
  }

  const digits = raw.replace(/\D/g, '');

  // US 10-digit number: 9785551234 -> +19785551234
  if (digits.length === 10) {
    return '+1' + digits;
  }

  // US 11-digit number starting with 1: 19785551234 -> +19785551234
  if (digits.length === 11 && digits.startsWith('1')) {
    return '+' + digits;
  }

  // International-looking number without plus. Best effort.
  if (digits.length >= 8 && digits.length <= 15) {
    return '+' + digits;
  }

  return '';
}

function telHref(phone) {
  const e164 = normalizePhoneE164(phone);

  if (!e164) return '';

  return 'tel:' + e164;
}

function renderPhone(phone) {
  const display = escapeHtml(phone || 'Not provided');
  const e164 = normalizePhoneE164(phone);
  const href = telHref(phone);

  if (!href) return display;

  return `<a href="${escapeHtml(href)}" title="Dial ${escapeHtml(e164)}">${display}</a><br><span class="muted">${escapeHtml(e164)}</span>`;
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

async function sendUserWelcomeEmail(user, temporaryPassword) {
  if (!user.email) {
    return { sent: false, reason: 'No email address provided.' };
  }

  if (!process.env.SMTP_HOST || !process.env.SMTP_USER || !process.env.SMTP_PASS || !process.env.EMAIL_FROM) {
    return { sent: false, reason: 'SMTP settings missing.' };
  }

  const portalUrl = process.env.PORTAL_LOGIN_URL || 'https://pharmacy.audiomercy.com/portal/login';
  const transporter = createEmailTransporter();

  const subject = 'Your Vodia Pharmacy Portal Login';

  const text = `
Hello ${user.name},

Your Vodia Pharmacy Portal account has been created.

Portal:
${portalUrl}

Username:
${user.username}

Temporary password:
${temporaryPassword}

Please log in and keep this information secure.
`;

  const html = `
    <h2>Your Vodia Pharmacy Portal Login</h2>
    <p>Hello ${escapeHtml(user.name)},</p>
    <p>Your Vodia Pharmacy Portal account has been created.</p>
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

function requirePortalLogin(req, res, next) {
  if (req.session && req.session.portalUser) {
    return next();
  }

  return res.redirect('/portal/login');
}

function requireAdmin(req, res, next) {
  if (req.session && req.session.portalUser && req.session.portalUser.role === 'admin') {
    return next();
  }

  return res.status(403).send(layout('Access Denied', `
    <div class="card">
      <h3>Access denied</h3>
      <p>You do not have admin access.</p>
      <a href="/portal/orders">Back to orders</a>
    </div>
  `, req.session.portalUser));
}

function layout(title, body, user) {
  const isAdmin = user && user.role === 'admin';

  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
  <title>${escapeHtml(title)}</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      background: #f5f5f5;
      margin: 0;
      padding: 0;
      color: #222;
    }
    header {
      background: #172033;
      color: white;
      padding: 16px 24px;
    }
    main {
      padding: 24px;
    }
    a {
      color: #172033;
    }
    .topnav a {
      color: white;
      margin-right: 14px;
      text-decoration: none;
    }
    .card {
      background: white;
      border-radius: 10px;
      padding: 20px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      margin-bottom: 20px;
    }
    .filters {
      display: flex;
      gap: 8px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    .filter {
      display: inline-block;
      padding: 8px 12px;
      border-radius: 999px;
      text-decoration: none;
      background: #e8eaf0;
      color: #172033;
      font-size: 14px;
    }
    .filter.active {
      background: #172033;
      color: white;
    }
    input, textarea, select, button {
      font-size: 14px;
      padding: 8px;
      margin: 4px 0;
    }
    input, textarea, select {
      width: 100%;
      box-sizing: border-box;
    }
    button {
      cursor: pointer;
      background: #172033;
      color: white;
      border: 0;
      border-radius: 6px;
      padding: 9px 14px;
    }
    .btn-small {
      font-size: 12px;
      padding: 7px 9px;
      margin-right: 4px;
      margin-bottom: 4px;
    }
    .btn-muted {
      background: #555;
    }
    .btn-green {
      background: #1c7c37;
    }
    .btn-orange {
      background: #b65f00;
    }
    .btn-red {
      background: #b91c1c;
    }
    .btn-blue {
      background: #1d4ed8;
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
    .status {
      font-weight: bold;
      padding: 5px 9px;
      border-radius: 999px;
      background: #eee;
      display: inline-block;
      font-size: 13px;
    }
    .status-pending {
      background: #fff3cd;
    }
    .status-called_back {
      background: #dbeafe;
    }
    .status-fulfilled {
      background: #dcfce7;
    }
    .status-needs_follow_up {
      background: #ffedd5;
    }
    .status-out_of_stock {
      background: #fee2e2;
    }
    .muted {
      color: #666;
      font-size: 13px;
    }
    .note-box {
      background: #f8f8f8;
      padding: 8px;
      border-radius: 6px;
      margin-top: 6px;
      white-space: pre-wrap;
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }
    .success {
      background: #dcfce7;
      border: 1px solid #86efac;
      padding: 12px;
      border-radius: 8px;
      margin-bottom: 12px;
    }
    .warning {
      background: #fff7ed;
      border: 1px solid #fed7aa;
      padding: 12px;
      border-radius: 8px;
      margin-bottom: 12px;
    }
    @media (max-width: 900px) {
      .grid {
        grid-template-columns: 1fr;
      }
    }
  </style>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <header>
    <h2>Vodia Pharmacy Portal</h2>
    <div class="topnav">
      <a href="/portal/orders">Agent Orders</a><a href="/portal/chat">Chat</a>
      ${isAdmin ? '<a href="/admin/users">Admin Users</a><a href="/admin/patients">Patients</a><a href="/admin/medications">Medications</a><a href="/admin/history">History</a>' : ''}
      <a href="/portal/voice-agent">Voice Agent</a><a href="/portal/logout">Logout</a>
    </div>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>
`;
}

function loginPage(errorMessage) {
  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
  <title>Agent Login</title>
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
    .login {
      background: rgba(255, 255, 255, 0.94);
      padding: 34px;
      border-radius: 18px;
      width: 380px;
      box-shadow: 0 14px 40px rgba(23, 32, 51, 0.20);
      backdrop-filter: blur(8px);
      border: 1px solid rgba(255, 255, 255, 0.7);
    }
    .badge {
      width: 54px;
      height: 54px;
      border-radius: 16px;
      background: #0f766e;
      color: white;
      display: flex;
      align-items: center;
      justify-content: center;
      font-size: 30px;
      font-weight: bold;
      margin-bottom: 18px;
      box-shadow: 0 8px 20px rgba(15, 118, 110, 0.25);
    }
    .login h2 {
      margin: 0;
      color: #172033;
      font-size: 27px;
      letter-spacing: -0.4px;
    }
    .subtitle {
      color: #5f6b7a;
      font-size: 14px;
      margin-top: 8px;
      margin-bottom: 22px;
      line-height: 1.45;
    }
    label {
      display: block;
      color: #344054;
      font-size: 13px;
      font-weight: bold;
      margin-top: 12px;
      margin-bottom: 5px;
    }
    input, button {
      width: 100%;
      box-sizing: border-box;
      padding: 12px;
      font-size: 15px;
    }
    input {
      border: 1px solid #d7dce2;
      border-radius: 9px;
      outline: none;
      background: #ffffff;
    }
    input:focus {
      border-color: #0d9488;
      box-shadow: 0 0 0 3px rgba(13, 148, 136, 0.13);
    }
    button {
      background: #0f766e;
      color: white;
      border: 0;
      border-radius: 9px;
      cursor: pointer;
      font-weight: bold;
      margin-top: 20px;
    }
    button:hover {
      background: #115e59;
    }
    .error {
      color: #b00020;
      background: #fee2e2;
      border: 1px solid #fecaca;
      padding: 10px;
      border-radius: 8px;
      margin-top: 14px;
      font-size: 14px;
    }
    .footer {
      margin-top: 20px;
      color: #7b8794;
      font-size: 12px;
      text-align: center;
    }
    @media (max-width: 900px) {
      body {
        justify-content: center;
        padding: 20px;
      }
      .login {
        width: 100%;
        max-width: 390px;
      }
    }
  </style>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <form class="login" method="post" action="/portal/login">
    <div class="badge">+</div>
    <h2>Portal Login</h2>
    <div class="subtitle">
      Sign in to manage pharmacy refill requests, callbacks, and user accounts.
    </div>

    <label>Username</label>
    <input name="username" placeholder="Enter username" autocomplete="username" required>

    <label>Password</label>
    <input name="password" type="password" placeholder="Enter password" autocomplete="current-password" required>

    <button type="submit">Login</button>

    ${errorMessage ? `<div class="error">${escapeHtml(errorMessage)}</div>` : ''}

    <p style="text-align:center; margin-top:14px;"><a href="/portal/forgot-password">Forgot password?</a></p><div class="footer">Vodia Pharmacy AI</div>
  </form>
</body>
</html>
`;
}

function buildFilterLink(label, value, currentFilter) {
  const href = value === 'all'
    ? '/portal/orders?status=all'
    : `/portal/orders?status=${encodeURIComponent(value)}`;

  const active = currentFilter === value;

  return `<a class="filter ${active ? 'active' : ''}" href="${href}">${escapeHtml(label)}</a>`;
}

function installPortalRoutes(app, openDb) {
  app.get('/portal', function (req, res) {
    res.redirect('/portal/orders');
  });

  app.get('/portal/login', function (req, res) {
    res.send(loginPage(''));
  });

  app.post('/portal/login', function (req, res) {
    const username = String(req.body.username || '').trim();
    const password = String(req.body.password || '').trim();

    const db = openDb();

    db.get(
      `
        SELECT id, name, email, username, password_hash, role, extension, active
        FROM portal_users
        WHERE username = ?
        LIMIT 1
      `,
      [username],
      function (err, user) {
        if (err) {
          db.close();
          console.error('Login error:', err.message);
          return res.status(500).send(loginPage('Login system error.'));
        }

        if (!user || user.active !== 1) {
          db.close();
          return res.status(401).send(loginPage('Invalid username or password'));
        }

        bcrypt.compare(password, user.password_hash, function (compareErr, match) {
          if (compareErr || !match) {
            db.close();
            return res.status(401).send(loginPage('Invalid username or password'));
          }

          db.run(
            `UPDATE portal_users SET last_login_at = CURRENT_TIMESTAMP WHERE id = ?`,
            [user.id],
            function () {
              db.close();

              req.session.portalUser = {
                id: user.id,
                name: user.name,
                username: user.username,
                email: user.email,
                role: user.role,
                extension: user.extension
              };

              if (user.role === 'admin') {
                return res.redirect('/admin/users');
              }

              return res.redirect('/portal/orders');
            }
          );
        });
      }
    );
  });

  app.get('/portal/logout', function (req, res) {
    req.session.destroy(function () {
      res.redirect('/portal/login');
    });
  });

  app.get('/portal/orders', requirePortalLogin, function (req, res) {
    const statusFilter = String(req.query.status || 'active').trim();
    const q = String(req.query.q || '').trim();

    const allowedFilters = [
      'active',
      'all',
      'pending',
      'called_back',
      'fulfilled',
      'needs_follow_up',
      'out_of_stock'
    ];

    const safeFilter = allowedFilters.includes(statusFilter) ? statusFilter : 'active';

    const whereParts = [];
    const params = [];

    if (safeFilter === 'active') {
      whereParts.push(`rr.status IN ('pending', 'called_back', 'needs_follow_up', 'out_of_stock')`);
    } else if (safeFilter !== 'all') {
      whereParts.push(`rr.status = ?`);
      params.push(safeFilter);
    }

    if (q) {
      whereParts.push(`
        lower(
          ifnull(p.first_name, '') || ' ' ||
          ifnull(p.last_name, '') || ' ' ||
          ifnull(p.date_of_birth, '') || ' ' ||
          ifnull(p.address, '') || ' ' ||
          ifnull(p.phone, '') || ' ' ||
          ifnull(rr.requested_medication, '') || ' ' ||
          ifnull(m.generic_name, '') || ' ' ||
          ifnull(m.brand_name, '')
        ) LIKE lower(?)
      `);
      params.push('%' + q + '%');
    }

    const whereSql = whereParts.length ? 'WHERE ' + whereParts.join(' AND ') : '';

    const db = openDb();

    db.all(
      `
        SELECT
          rr.id,
          rr.requested_medication,
          rr.request_type,
          rr.customer_name,
          rr.callback_phone,
          rr.quantity_requested,
          rr.customer_question,
          rr.stock_status,
          rr.stock_snapshot,
          rr.status,
          rr.notes,
          rr.agent_notes,
          rr.created_at,
          rr.updated_at,
          rr.fulfilled_at,

          -- ORDER_FULFILLMENT_DISPLAY_PATCH_V1
          rr.date_of_birth AS request_date_of_birth,
          rr.address AS request_address,

          rr.customer_profile_id,
          rr.known_customer,
          rr.preferred_title,
          rr.last_name AS request_last_name,

          rr.rx_number,
          rr.medication_strength,
          rr.directions_sig,
          rr.quantity_display,
          rr.refills_display,
          rr.prescriber_name,
          rr.pharmacy_name,

          rr.insurance_provider,
          rr.insurance_plan_type,
          rr.insurance_member_id,
          rr.insurance_group_number,
          rr.insurance_bin,
          rr.insurance_pcn,
          rr.insurance_copay,
          rr.insurance_status,
          rr.prior_auth_required,
          rr.insurance_notes,

          rr.fulfillment_method,
          rr.pickup_requested,
          rr.delivery_requested,
          rr.pickup_store_id,
          rr.pickup_store_code,
          rr.pickup_store_name,
          rr.pickup_store_address,
          rr.delivery_address,
          rr.delivery_address_confirmed,
          rr.delivery_instructions,
          rr.fulfillment_confirmed,
          rr.fulfillment_notes,

          p.first_name,
          p.last_name,
          p.date_of_birth,
          p.address,
          p.phone,
          m.generic_name,
          m.brand_name
        FROM refill_requests rr
        LEFT JOIN patients p ON rr.patient_id = p.id
        LEFT JOIN medications m ON rr.medication_id = m.id
        ${whereSql}
        ORDER BY
          CASE rr.status
            WHEN 'pending' THEN 1
            WHEN 'needs_follow_up' THEN 2
            WHEN 'out_of_stock' THEN 3
            WHEN 'called_back' THEN 4
            WHEN 'fulfilled' THEN 5
            ELSE 6
          END,
          rr.created_at DESC
      `,
      params,
      function (err, rows) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
            </div>
          `, req.session.portalUser));
        }

        const filters = `
          <div class="filters">
            ${buildFilterLink('Active', 'active', safeFilter)}
            ${buildFilterLink('All', 'all', safeFilter)}
            ${buildFilterLink('Pending', 'pending', safeFilter)}
            ${buildFilterLink('Called Back', 'called_back', safeFilter)}
            ${buildFilterLink('Needs Follow-Up', 'needs_follow_up', safeFilter)}
            ${buildFilterLink('Out of Stock', 'out_of_stock', safeFilter)}
            ${buildFilterLink('Fulfilled', 'fulfilled', safeFilter)}
          </div>
        `;

        const tableRows = rows.map(function (row) {
          const patientNameFromPatient = `${row.first_name || ''} ${row.last_name || ''}`.trim();
          const patientName = patientNameFromPatient || row.customer_name || 'Unknown';

          const patientDob = row.date_of_birth || row.request_date_of_birth || '';
          const patientAddress = row.address || row.request_address || '';

          const isKnownCustomer = Number(row.known_customer || 0) === 1 || !!row.customer_profile_id;
          const knownCustomerName = `${row.preferred_title || ''} ${row.request_last_name || ''}`.trim();

          const knownCustomerBlock = isKnownCustomer
            ? `<div class="note-box"><strong>Known Customer:</strong> ${escapeHtml(knownCustomerName || 'Yes')}</div>`
            : '';

          const rxLines = [];

          if (row.rx_number) rxLines.push(`<strong>Rx #:</strong> ${escapeHtml(row.rx_number)}`);
          if (row.medication_strength) rxLines.push(`<strong>Strength:</strong> ${escapeHtml(row.medication_strength)}`);
          if (row.directions_sig) rxLines.push(`<strong>Directions:</strong> ${escapeHtml(row.directions_sig)}`);
          if (row.quantity_display) rxLines.push(`<strong>Qty:</strong> ${escapeHtml(row.quantity_display)}`);
          if (row.refills_display) rxLines.push(`<strong>Refills:</strong> ${escapeHtml(row.refills_display)}`);
          if (row.prescriber_name) rxLines.push(`<strong>Prescriber:</strong> ${escapeHtml(row.prescriber_name)}`);
          if (row.pharmacy_name) rxLines.push(`<strong>Pharmacy:</strong> ${escapeHtml(row.pharmacy_name)}`);

          if (row.insurance_provider) rxLines.push(`<strong>Insurance:</strong> ${escapeHtml(row.insurance_provider)}`);
          if (row.insurance_plan_type) rxLines.push(`<strong>Plan:</strong> ${escapeHtml(row.insurance_plan_type)}`);
          if (row.insurance_member_id) rxLines.push(`<strong>Member ID:</strong> ${escapeHtml(row.insurance_member_id)}`);
          if (row.insurance_group_number) rxLines.push(`<strong>Group:</strong> ${escapeHtml(row.insurance_group_number)}`);
          if (row.insurance_bin || row.insurance_pcn) {
            rxLines.push(`<strong>BIN/PCN:</strong> ${escapeHtml(row.insurance_bin || '')}${row.insurance_pcn ? ' / ' + escapeHtml(row.insurance_pcn) : ''}`);
          }
          if (row.insurance_status) rxLines.push(`<strong>Insurance Status:</strong> ${escapeHtml(row.insurance_status)}`);
          if (row.prior_auth_required) rxLines.push(`<strong>Prior Auth:</strong> ${escapeHtml(row.prior_auth_required)}`);
          if (row.insurance_copay) rxLines.push(`<strong>Copay:</strong> ${escapeHtml(row.insurance_copay)}`);
          if (row.insurance_notes) rxLines.push(`<strong>Insurance Notes:</strong> ${escapeHtml(row.insurance_notes)}`);

          const rxInsuranceBlock = rxLines.length
            ? `<div class="note-box"><strong>Rx / Insurance:</strong><br>${rxLines.join('<br>')}</div>`
            : '';

          const fulfillmentMethodRaw = String(row.fulfillment_method || 'undecided').toLowerCase();
          const pickupRequested = Number(row.pickup_requested || 0) === 1;
          const deliveryRequested = Number(row.delivery_requested || 0) === 1;
          const deliveryConfirmed = Number(row.delivery_address_confirmed || 0) === 1;
          const fulfillmentConfirmed = Number(row.fulfillment_confirmed || 0) === 1;

          let fulfillmentLabel = 'Undecided';
          if (fulfillmentMethodRaw === 'pickup') fulfillmentLabel = 'Pickup';
          if (fulfillmentMethodRaw === 'delivery') fulfillmentLabel = 'Delivery';

          const fulfillmentLines = [];

          if (
            fulfillmentMethodRaw !== 'undecided' ||
            pickupRequested ||
            deliveryRequested ||
            row.pickup_store_name ||
            row.delivery_address ||
            row.delivery_instructions ||
            row.fulfillment_notes
          ) {
            fulfillmentLines.push(`<strong>Method:</strong> ${escapeHtml(fulfillmentLabel)}`);
            fulfillmentLines.push(`<strong>Confirmed:</strong> ${fulfillmentConfirmed ? 'Yes' : 'No'}`);

            if (pickupRequested || fulfillmentMethodRaw === 'pickup') {
              fulfillmentLines.push(`<strong>Pickup Requested:</strong> Yes`);
            }

            if (row.pickup_store_name) {
              fulfillmentLines.push(`<strong>Pickup Store:</strong> ${escapeHtml(row.pickup_store_name)}`);
            }

            if (row.pickup_store_address) {
              fulfillmentLines.push(`<strong>Store Address:</strong> ${escapeHtml(row.pickup_store_address)}`);
            }

            if (deliveryRequested || fulfillmentMethodRaw === 'delivery') {
              fulfillmentLines.push(`<strong>Delivery Requested:</strong> Yes`);
            }

            if (row.delivery_address) {
              fulfillmentLines.push(`<strong>Delivery Address:</strong> ${escapeHtml(row.delivery_address)}`);
              fulfillmentLines.push(`<strong>Delivery Address Confirmed:</strong> ${deliveryConfirmed ? 'Yes' : 'No'}`);
            }

            if (row.delivery_instructions) {
              fulfillmentLines.push(`<strong>Delivery Instructions:</strong> ${escapeHtml(row.delivery_instructions)}`);
            }

            if (row.fulfillment_notes) {
              fulfillmentLines.push(`<strong>Fulfillment Notes:</strong> ${escapeHtml(row.fulfillment_notes)}`);
            }
          }

          const fulfillmentBlock = fulfillmentLines.length
            ? `<div class="note-box"><strong>Pickup / Delivery:</strong><br>${fulfillmentLines.join('<br>')}</div>`
            : '';

          return `
            <tr>
              <td>#${row.id}</td>
              <td>
                <strong>${escapeHtml(patientName || 'Unknown')}</strong><br>
                ${knownCustomerBlock}
                <span class="muted">DOB: ${escapeHtml(patientDob || '')}</span><br>
                <span class="muted">Phone: ${renderPhone(row.callback_phone || row.phone)}</span><br>
                <span class="muted">Address: ${escapeHtml(patientAddress || '')}</span>
              </td>
              <td>
                <strong>${escapeHtml(row.requested_medication)}</strong><br>
                <span class="muted">Type: ${escapeHtml(row.request_type || 'refill')}</span><br>
                <span class="muted">Qty: ${escapeHtml(row.quantity_requested || 1)}</span><br>
                <span class="muted">Stock: ${escapeHtml(row.stock_status || 'not checked')} ${row.stock_snapshot !== null && row.stock_snapshot !== undefined ? '(' + escapeHtml(row.stock_snapshot) + ')' : ''}</span><br>
                ${row.pickup_requested || row.pickup_store_name || row.pickup_store_address ? `
                  <div class="note-box" style="border-left:4px solid #2563eb; margin-top:8px;">
                    <strong>Pickup Location</strong><br>
                    ${row.pickup_store_name ? `<span>${escapeHtml(row.pickup_store_name)}</span><br>` : ''}
                    ${row.pickup_store_address ? `<span class="muted">${escapeHtml(row.pickup_store_address)}</span><br>` : ''}
                    ${row.pickup_store_code ? `<span class="muted">Store Code: ${escapeHtml(row.pickup_store_code)}</span>` : ''}
                  </div>
                ` : ''}
                <span class="muted">${escapeHtml(row.brand_name || row.generic_name || '')}</span>
                ${row.customer_question ? `<div class="note-box">Question: ${escapeHtml(row.customer_question)}</div>` : ''}
                ${rxInsuranceBlock}
                ${fulfillmentBlock}
              </td>
              <td>
                <span class="status status-${escapeHtml(row.status)}">${escapeHtml(statusLabel(row.status))}</span>
              </td>
              <td>
                <span class="muted">Created: ${escapeHtml(row.created_at || '')}</span><br>
                <span class="muted">Updated: ${escapeHtml(row.updated_at || '')}</span><br>
                <span class="muted">Fulfilled: ${escapeHtml(row.fulfilled_at || '')}</span>
                ${row.agent_notes ? `<div class="note-box">${escapeHtml(row.agent_notes)}</div>` : ''}
              </td>
              <td class="order-actions">
                <form class="quick-actions" method="post" action="/portal/orders/${row.id}/quick" style="margin-bottom:8px;">
                  <button class="btn-small btn-muted" name="status" value="called_back" type="submit">Called Back</button>
                  <button class="btn-small btn-orange" name="status" value="needs_follow_up" type="submit">Follow-Up</button>
                  <button class="btn-small btn-green" name="status" value="fulfilled" type="submit">Fulfilled</button>
                  <a
                    class="btn-small"
                    style="background:#1d4ed8;color:white;text-decoration:none;border-radius:6px;padding:7px 9px;display:inline-block;"
                    href="/portal/orders/${row.id}/edit"
                  >Edit</a>
                  <a
                    class="btn-small"
                    style="background:#0f766e;color:white;text-decoration:none;border-radius:6px;padding:7px 9px;display:inline-block;"
                    href="/portal/orders/${row.id}/chat"
                  >Chat</a>
                </form>

                <form method="post" action="/portal/orders/${row.id}/update">
                  <select name="status">
                    <option value="pending" ${row.status === 'pending' ? 'selected' : ''}>Pending</option>
                    <option value="called_back" ${row.status === 'called_back' ? 'selected' : ''}>Called Back</option>
                    <option value="fulfilled" ${row.status === 'fulfilled' ? 'selected' : ''}>Fulfilled</option>
                    <option value="needs_follow_up" ${row.status === 'needs_follow_up' ? 'selected' : ''}>Needs Follow-Up</option>
                    <option value="out_of_stock" ${row.status === 'out_of_stock' ? 'selected' : ''}>Out of Stock</option>
                  </select>
                  <textarea name="agent_notes" rows="3" placeholder="Agent notes">${escapeHtml(row.agent_notes || '')}</textarea>
                  <button type="submit">Update Notes / Status</button>
                </form>
              </td>
            </tr>
          `;
        }).join('');

        const body = `

          <div class="pharma-orders-hero">
            <div class="pharma-hero-copy">
              <div class="pharma-hero-kicker">Pharmacy Operations</div>
              <h2>Refill Request Queue</h2>
              <p>Review refill requests, call patients, chat with agents, and update fulfillment status from one clean workspace.</p>
            </div>

            <div class="pharma-hero-art" aria-hidden="true">
              <svg viewBox="0 0 520 220" role="img">
                <defs>
                  <linearGradient id="heroGradA" x1="0" x2="1" y1="0" y2="1">
                    <stop offset="0%" stop-color="#5eead4"/>
                    <stop offset="100%" stop-color="#0f766e"/>
                  </linearGradient>
                  <linearGradient id="heroGradB" x1="0" x2="1" y1="0" y2="1">
                    <stop offset="0%" stop-color="#dbeafe"/>
                    <stop offset="100%" stop-color="#93c5fd"/>
                  </linearGradient>
                </defs>

                <rect x="18" y="28" width="238" height="150" rx="24" fill="url(#heroGradA)" opacity="0.95"/>
                <rect x="44" y="54" width="186" height="98" rx="18" fill="rgba(255,255,255,0.22)"/>

                <rect x="116" y="70" width="42" height="66" rx="10" fill="#ffffff"/>
                <rect x="104" y="82" width="66" height="42" rx="10" fill="#ffffff"/>

                <circle cx="310" cy="88" r="42" fill="url(#heroGradB)"/>
                <rect x="286" y="118" width="126" height="44" rx="22" fill="#ffffff" opacity="0.95"/>
                <rect x="301" y="131" width="37" height="18" rx="9" fill="#0f766e"/>
                <rect x="348" y="131" width="49" height="18" rx="9" fill="#60a5fa"/>

                <path d="M414 63c22 0 40 18 40 40s-18 40-40 40-40-18-40-40 18-40 40-40z" fill="#ccfbf1"/>
                <path d="M400 103l10 10 22-26" fill="none" stroke="#0f766e" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>

                <rect x="276" y="35" width="198" height="34" rx="17" fill="#ffffff" opacity="0.9"/>
                <circle cx="296" cy="52" r="8" fill="#14b8a6"/>
                <rect x="314" y="45" width="122" height="8" rx="4" fill="#94a3b8" opacity="0.65"/>
                <rect x="314" y="58" width="82" height="6" rx="3" fill="#cbd5e1"/>

                <circle cx="84" cy="178" r="18" fill="#ccfbf1"/>
                <circle cx="454" cy="174" r="12" fill="#5eead4"/>
                <circle cx="248" cy="30" r="10" fill="#93c5fd"/>
              </svg>
            </div>
          </div>

          <div class="card">
            <h3>Refill Request Queue</h3>
            <p class="muted">Agent: ${escapeHtml(req.session.portalUser.name || req.session.portalUser.username)} | Showing: ${escapeHtml(statusLabel(safeFilter))}</p>

            <form method="get" action="/portal/orders" style="margin: 12px 0;">
              <input type="hidden" name="status" value="${escapeHtml(safeFilter)}">
              <input name="q" value="${escapeHtml(q)}" placeholder="Search patient, DOB, phone, address, or medication" style="max-width: 520px;">
              <button type="submit">Search</button>
              <a class="filter" href="/portal/orders?status=${escapeHtml(safeFilter)}">Clear Search</a>
            </form>

            ${filters}
          </div>

          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Patient</th>
                <th>Medication</th>
                <th>Status</th>
                <th>Dates / Notes</th>
                <th>Action</th>
              </tr>
            </thead>
            <tbody>
              ${tableRows || '<tr><td colspan="6">No refill requests found.</td></tr>'}
            </tbody>
          </table>
        `;

        res.send(layout('Pharmacy Orders', body, req.session.portalUser));
      }
    );
  });

  app.post('/portal/orders/:id/quick', requirePortalLogin, function (req, res) {
    const orderId = req.params.id;
    const status = String(req.body.status || '').trim();

    const allowedStatuses = [
      'called_back',
      'fulfilled',
      'needs_follow_up'
    ];

    if (!allowedStatuses.includes(status)) {
      return res.redirect('/portal/orders');
    }

    const fulfilledAtSql = status === 'fulfilled'
      ? `fulfilled_at = COALESCE(fulfilled_at, CURRENT_TIMESTAMP),`
      : `fulfilled_at = fulfilled_at,`;

    const noteText = status === 'called_back'
      ? 'Quick action: marked as called back.'
      : status === 'fulfilled'
        ? 'Quick action: marked as fulfilled.'
        : 'Quick action: marked as needs follow-up.';

    const db = openDb();

    db.run(
      `
        UPDATE refill_requests
        SET
          status = ?,
          agent_notes = CASE
            WHEN agent_notes IS NULL OR agent_notes = ''
            THEN ?
            ELSE agent_notes || CHAR(10) || ?
          END,
          ${fulfilledAtSql}
          updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [status, noteText, noteText, orderId],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Update Error', `
            <div class="card">
              <h3>Could not update order</h3>
              <p>${escapeHtml(err.message)}</p>
              <a href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        res.redirect('/portal/orders');
      }
    );
  });

  app.post('/portal/orders/:id/update', requirePortalLogin, function (req, res) {
    const orderId = req.params.id;
    const status = String(req.body.status || 'pending').trim();
    const agentNotes = String(req.body.agent_notes || '').trim();

    const allowedStatuses = [
      'pending',
      'called_back',
      'fulfilled',
      'needs_follow_up',
      'out_of_stock'
    ];

    if (!allowedStatuses.includes(status)) {
      return res.status(400).send(layout('Invalid Status', `
        <div class="card">
          <h3>Invalid status</h3>
          <p>The selected status is not allowed.</p>
          <a href="/portal/orders">Back to orders</a>
        </div>
      `, req.session.portalUser));
    }

    const fulfilledAtSql = status === 'fulfilled'
      ? `fulfilled_at = COALESCE(fulfilled_at, CURRENT_TIMESTAMP),`
      : `fulfilled_at = fulfilled_at,`;

    const db = openDb();

    db.run(
      `
        UPDATE refill_requests
        SET
          status = ?,
          agent_notes = ?,
          ${fulfilledAtSql}
          updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [status, agentNotes, orderId],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Update Error', `
            <div class="card">
              <h3>Could not update order</h3>
              <p>${escapeHtml(err.message)}</p>
              <a href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        res.redirect('/portal/orders');
      }
    );
  });

  app.get('/admin', requirePortalLogin, requireAdmin, function (req, res) {
    res.redirect('/admin/users');
  });

  app.get('/admin/users', requirePortalLogin, requireAdmin, function (req, res) {
    const db = openDb();

    db.all(
      `
        SELECT id, name, email, username, role, extension, active, created_at, updated_at, last_login_at, revoked_at
        FROM portal_users
        ORDER BY role ASC, active DESC, name ASC
      `,
      [],
      function (err, users) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Admin Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
            </div>
          `, req.session.portalUser));
        }

        const userRows = users.map(function (user) {
          const activeText = user.active === 1 ? 'Active' : 'Disabled';

          return `
            <tr>
              <td>#${user.id}</td>
              <td>
                <strong>${escapeHtml(user.name)}</strong><br>
                <span class="muted">${escapeHtml(user.email || '')}</span>
              </td>
              <td>${escapeHtml(user.username)}</td>
              <td>${escapeHtml(user.role)}</td>
              <td>${escapeHtml(user.extension || '')}</td>
              <td>${escapeHtml(activeText)}</td>
              <td>
                <span class="muted">Created: ${escapeHtml(user.created_at || '')}</span><br>
                <span class="muted">Last login: ${escapeHtml(user.last_login_at || '')}</span><br>
                <span class="muted">Revoked: ${escapeHtml(user.revoked_at || '')}</span>
              </td>
              <td>
                <form method="post" action="/admin/users/${user.id}/reset-password" style="display:inline;">
                  <button class="btn-small btn-blue" type="submit">Reset Password</button>
                </form>

                ${
                  user.active === 1
                    ? `<form method="post" action="/admin/users/${user.id}/disable" style="display:inline;">
                        <button class="btn-small btn-red" type="submit">Disable</button>
                      </form>`
                    : `<form method="post" action="/admin/users/${user.id}/enable" style="display:inline;">
                        <button class="btn-small btn-green" type="submit">Enable</button>
                      </form>`
                }
              </td>
            </tr>
          `;
        }).join('');

        const body = `
          <div class="card">
            <h3>Admin Panel — Portal Users</h3>
            <p class="muted">Create agents, reset passwords, and revoke access.</p>
          </div>

          <div class="card">
            <h3>Create New User</h3>
            <form method="post" action="/admin/users">
              <div class="grid">
                <div>
                  <label>Name</label>
                  <input name="name" placeholder="Agent full name" required>
                </div>
                <div>
                  <label>Email</label>
                  <input name="email" type="email" placeholder="agent@example.com">
                </div>
                <div>
                  <label>Username</label>
                  <input name="username" placeholder="agent username" required>
                </div>
                <div>
                  <label>Extension</label>
                  <input name="extension" placeholder="PBX extension, e.g. 2003">
                </div>
                <div>
                  <label>Role</label>
                  <select name="role">
                    <option value="agent">Agent</option>
                    <option value="admin">Admin</option>
                  </select>
                </div>
              </div>
              <button type="submit">Create User & Email Login</button>
            </form>
          </div>

          <table>
            <thead>
              <tr>
                <th>ID</th>
                <th>Name / Email</th>
                <th>Username</th>
                <th>Role</th>
                <th>Extension</th>
                <th>Status</th>
                <th>Dates</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              ${userRows || '<tr><td colspan="8">No users found.</td></tr>'}
            </tbody>
          </table>
        `;

        res.send(layout('Admin Users', body, req.session.portalUser));
      }
    );
  });

  app.post('/admin/users', requirePortalLogin, requireAdmin, function (req, res) {
    const name = String(req.body.name || '').trim();
    const email = String(req.body.email || '').trim();
    const username = String(req.body.username || '').trim();
    const extension = String(req.body.extension || '').trim();
    const role = String(req.body.role || 'agent').trim();

    if (!name || !username) {
      return res.status(400).send(layout('Missing Fields', `
        <div class="card">
          <h3>Missing required fields</h3>
          <p>Name and username are required.</p>
          <a href="/admin/users">Back to users</a>
        </div>
      `, req.session.portalUser));
    }

    if (!['agent', 'admin'].includes(role)) {
      return res.status(400).send(layout('Invalid Role', `
        <div class="card">
          <h3>Invalid role</h3>
          <p>Role must be agent or admin.</p>
          <a href="/admin/users">Back to users</a>
        </div>
      `, req.session.portalUser));
    }

    const temporaryPassword = generatePassword();

    bcrypt.hash(temporaryPassword, 12, function (hashErr, passwordHash) {
      if (hashErr) {
        return res.status(500).send(layout('Password Error', `
          <div class="card">
            <h3>Could not create password</h3>
            <p>${escapeHtml(hashErr.message)}</p>
            <a href="/admin/users">Back to users</a>
          </div>
        `, req.session.portalUser));
      }

      const db = openDb();

      db.run(
        `
          INSERT INTO portal_users
          (name, email, username, password_hash, role, extension, active)
          VALUES (?, ?, ?, ?, ?, ?, 1)
        `,
        [name, email, username, passwordHash, role, extension],
        async function (err) {
          db.close();

          if (err) {
            return res.status(500).send(layout('Create User Error', `
              <div class="card">
                <h3>Could not create user</h3>
                <p>${escapeHtml(err.message)}</p>
                <a href="/admin/users">Back to users</a>
              </div>
            `, req.session.portalUser));
          }

          let emailMessage = 'No email sent.';

          try {
            const emailResult = await sendUserWelcomeEmail({ name, email, username }, temporaryPassword);
            emailMessage = emailResult.sent
              ? 'Login email sent successfully.'
              : 'Login email not sent: ' + emailResult.reason;
          } catch (emailErr) {
            emailMessage = 'User created, but email failed: ' + emailErr.message;
          }

          return res.send(layout('User Created', `
            <div class="card">
              <h3>User Created</h3>
              <p><strong>Name:</strong> ${escapeHtml(name)}</p>
              <p><strong>Username:</strong> ${escapeHtml(username)}</p>
              <p><strong>Temporary password:</strong> ${escapeHtml(temporaryPassword)}</p>
              <p class="muted">${escapeHtml(emailMessage)}</p>
              <a href="/admin/users">Back to users</a>
            </div>
          `, req.session.portalUser));
        }
      );
    });
  });

  app.post('/admin/users/:id/disable', requirePortalLogin, requireAdmin, function (req, res) {
    const userId = req.params.id;
    const db = openDb();

    db.run(
      `
        UPDATE portal_users
        SET active = 0, revoked_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [userId],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Disable Error', `
            <div class="card">
              <h3>Could not disable user</h3>
              <p>${escapeHtml(err.message)}</p>
              <a href="/admin/users">Back to users</a>
            </div>
          `, req.session.portalUser));
        }

        res.redirect('/admin/users');
      }
    );
  });

  app.post('/admin/users/:id/enable', requirePortalLogin, requireAdmin, function (req, res) {
    const userId = req.params.id;
    const db = openDb();

    db.run(
      `
        UPDATE portal_users
        SET active = 1, revoked_at = NULL, updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [userId],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).send(layout('Enable Error', `
            <div class="card">
              <h3>Could not enable user</h3>
              <p>${escapeHtml(err.message)}</p>
              <a href="/admin/users">Back to users</a>
            </div>
          `, req.session.portalUser));
        }

        res.redirect('/admin/users');
      }
    );
  });

  app.post('/admin/users/:id/reset-password', requirePortalLogin, requireAdmin, function (req, res) {
    const userId = req.params.id;
    const temporaryPassword = generatePassword();

    bcrypt.hash(temporaryPassword, 12, function (hashErr, passwordHash) {
      if (hashErr) {
        return res.status(500).send(layout('Password Error', `
          <div class="card">
            <h3>Could not create password</h3>
            <p>${escapeHtml(hashErr.message)}</p>
            <a href="/admin/users">Back to users</a>
          </div>
        `, req.session.portalUser));
      }

      const db = openDb();

      db.get(
        `SELECT id, name, email, username FROM portal_users WHERE id = ? LIMIT 1`,
        [userId],
        function (getErr, user) {
          if (getErr || !user) {
            db.close();

            return res.status(404).send(layout('User Not Found', `
              <div class="card">
                <h3>User not found</h3>
                <a href="/admin/users">Back to users</a>
              </div>
            `, req.session.portalUser));
          }

          db.run(
            `
              UPDATE portal_users
              SET password_hash = ?, updated_at = CURRENT_TIMESTAMP
              WHERE id = ?
            `,
            [passwordHash, userId],
            async function (updateErr) {
              db.close();

              if (updateErr) {
                return res.status(500).send(layout('Reset Error', `
                  <div class="card">
                    <h3>Could not reset password</h3>
                    <p>${escapeHtml(updateErr.message)}</p>
                    <a href="/admin/users">Back to users</a>
                  </div>
                `, req.session.portalUser));
              }

              let emailMessage = 'No email sent.';

              try {
                const emailResult = await sendUserWelcomeEmail(user, temporaryPassword);
                emailMessage = emailResult.sent
                  ? 'Password reset email sent successfully.'
                  : 'Password reset email not sent: ' + emailResult.reason;
              } catch (emailErr) {
                emailMessage = 'Password reset, but email failed: ' + emailErr.message;
              }

              return res.send(layout('Password Reset', `
                <div class="card">
                  <h3>Password Reset</h3>
                  <p><strong>User:</strong> ${escapeHtml(user.username)}</p>
                  <p><strong>Temporary password:</strong> ${escapeHtml(temporaryPassword)}</p>
                  <p class="muted">${escapeHtml(emailMessage)}</p>
                  <a href="/admin/users">Back to users</a>
                </div>
              `, req.session.portalUser));
            }
          );
        }
      );
    });
  });
}

module.exports = {
  installPortalRoutes
};
