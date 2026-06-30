#!/bin/bash

set -e

APP_DIR="/home/ubuntu/vodia-pharmacy-ai"
PORTAL_FILE="$APP_DIR/portal.js"
BACKUP_FILE="$APP_DIR/portal.backup.$(date +%F-%H%M%S).js"

echo "Going to app folder..."
cd "$APP_DIR"

echo "Backing up current portal.js..."
if [ -f "$PORTAL_FILE" ]; then
  cp "$PORTAL_FILE" "$BACKUP_FILE"
  echo "Backup created: $BACKUP_FILE"
fi

echo "Writing new portal.js..."

cat > "$PORTAL_FILE" <<'PORTALJS'
'use strict';

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function requirePortalLogin(req, res, next) {
  if (req.session && req.session.portalUser) {
    return next();
  }

  return res.redirect('/portal/login');
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

function layout(title, body) {
  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
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
    textarea, select {
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
  </style>
</head>
<body>
  <header>
    <h2>Vodia Pharmacy Agent Portal</h2>
    <div class="topnav">
      <a href="/portal/orders">Orders</a>
      <a href="/portal/logout">Logout</a>
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
      transition: background 0.15s ease, transform 0.15s ease;
    }

    button:hover {
      background: #115e59;
      transform: translateY(-1px);
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
</head>
<body>
  <form class="login" method="post" action="/portal/login">
    <div class="badge">+</div>

    <h2>Agent Portal</h2>
    <div class="subtitle">
      Sign in to manage pharmacy refill requests, callbacks, and fulfillment notes.
    </div>

    <label>Username</label>
    <input name="username" placeholder="Enter username" autocomplete="username" required>

    <label>Password</label>
    <input name="password" type="password" placeholder="Enter password" autocomplete="current-password" required>

    <button type="submit">Login</button>

    ${errorMessage ? `<div class="error">${escapeHtml(errorMessage)}</div>` : ''}

    <div class="footer">Vodia Pharmacy AI</div>
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

    const expectedUsername = process.env.PORTAL_USERNAME || 'agent';
    const expectedPassword = process.env.PORTAL_PASSWORD || 'change-this-portal-password';

    if (username === expectedUsername && password === expectedPassword) {
      req.session.portalUser = username;
      return res.redirect('/portal/orders');
    }

    return res.status(401).send(loginPage('Invalid username or password'));
  });

  app.get('/portal/logout', function (req, res) {
    req.session.destroy(function () {
      res.redirect('/portal/login');
    });
  });

  app.get('/portal/orders', requirePortalLogin, function (req, res) {
    const statusFilter = String(req.query.status || 'active').trim();

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

    let whereSql = '';

    if (safeFilter === 'active') {
      whereSql = `
        WHERE rr.status IN ('pending', 'called_back', 'needs_follow_up', 'out_of_stock')
      `;
    } else if (safeFilter !== 'all') {
      whereSql = `
        WHERE rr.status = ?
      `;
    }

    const params = safeFilter !== 'active' && safeFilter !== 'all'
      ? [safeFilter]
      : [];

    const db = openDb();

    db.all(
      `
        SELECT
          rr.id,
          rr.requested_medication,
          rr.status,
          rr.notes,
          rr.agent_notes,
          rr.created_at,
          rr.updated_at,
          rr.fulfilled_at,
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
          `));
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
          const patientName = `${row.first_name || ''} ${row.last_name || ''}`.trim();

          return `
            <tr>
              <td>#${row.id}</td>
              <td>
                <strong>${escapeHtml(patientName || 'Unknown')}</strong><br>
                <span class="muted">DOB: ${escapeHtml(row.date_of_birth || '')}</span><br>
                <span class="muted">Phone: ${escapeHtml(row.phone || 'Not provided')}</span><br>
                <span class="muted">Address: ${escapeHtml(row.address || '')}</span>
              </td>
              <td>
                <strong>${escapeHtml(row.requested_medication)}</strong><br>
                <span class="muted">${escapeHtml(row.brand_name || row.generic_name || '')}</span>
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
              <td>
                <form method="post" action="/portal/orders/${row.id}/quick" style="margin-bottom:8px;">
                  <button class="btn-small btn-muted" name="status" value="called_back" type="submit">Called Back</button>
                  <button class="btn-small btn-orange" name="status" value="needs_follow_up" type="submit">Follow-Up</button>
                  <button class="btn-small btn-green" name="status" value="fulfilled" type="submit">Fulfilled</button>
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
          <div class="card">
            <h3>Refill Request Queue</h3>
            <p class="muted">Agent: ${escapeHtml(req.session.portalUser)} | Showing: ${escapeHtml(statusLabel(safeFilter))}</p>
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

        res.send(layout('Pharmacy Orders', body));
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
          `));
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
      `));
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
          `));
        }

        res.redirect('/portal/orders');
      }
    );
  });
}

module.exports = {
  installPortalRoutes
};
PORTALJS

echo "Checking portal.js syntax..."
node -c "$PORTAL_FILE"

echo "Checking server.js syntax..."
node -c "$APP_DIR/server.js"

echo "Restarting PM2 app..."
pm2 restart vodia-pharmacy-ai --update-env

echo "Done. Portal updated successfully."
echo "Test it here: https://pharmacy.audiomercy.com/portal/login"
