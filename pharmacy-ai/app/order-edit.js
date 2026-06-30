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

function pageLayout(title, body, user) {
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
    .grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 14px;
    }
    label {
      display: block;
      font-size: 13px;
      font-weight: bold;
      margin-bottom: 4px;
      color: #344054;
    }
    input, textarea, select, button {
      font-size: 14px;
      padding: 9px;
      box-sizing: border-box;
    }
    input, textarea, select {
      width: 100%;
      border: 1px solid #d7dce2;
      border-radius: 8px;
    }
    button, .button {
      background: #172033;
      color: white;
      border: 0;
      border-radius: 6px;
      padding: 9px 14px;
      cursor: pointer;
      text-decoration: none;
      display: inline-block;
    }
    .button-muted {
      background: #555;
    }
    .muted {
      color: #666;
      font-size: 13px;
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
    <a href="/portal/orders">Agent Orders</a><a href="/portal/chat">Chat</a>
    ${isAdmin ? '<a href="/admin/users">Admin Users</a><a href="/admin/patients">Patients</a><a href="/admin/medications">Medications</a><a href="/admin/history">History</a>' : ''}
    <a href="/portal/logout">Logout</a>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>
`;
}

function findMedication(db, medication, callback) {
  const med = String(medication || '').trim();

  if (!med) {
    return callback(null, null);
  }

  db.get(
    `
      SELECT id, generic_name, brand_name
      FROM medications
      WHERE lower(generic_name) = lower(?)
      OR lower(brand_name) = lower(?)
      OR lower(ifnull(common_names, '')) LIKE lower(?)
      LIMIT 1
    `,
    [med, med, '%' + med + '%'],
    function (err, row) {
      if (err && String(err.message || '').includes('no such column: common_names')) {
        return db.get(
          `
            SELECT id, generic_name, brand_name
            FROM medications
            WHERE lower(generic_name) = lower(?)
            OR lower(brand_name) = lower(?)
            LIMIT 1
          `,
          [med, med],
          callback
        );
      }

      callback(err, row);
    }
  );
}

function installOrderEditRoutes(app, openDb) {
  app.get('/portal/orders/:id/edit', requirePortalLogin, function (req, res) {
    const orderId = req.params.id;
    const db = openDb();

    db.get(
      `
        SELECT
          rr.id,
          rr.patient_id,
          rr.medication_id,
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
        WHERE rr.id = ?
        LIMIT 1
      `,
      [orderId],
      function (err, row) {
        db.close();

        if (err) {
          return res.status(500).send(pageLayout('Edit Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
              <a class="button" href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        if (!row) {
          return res.status(404).send(pageLayout('Order Not Found', `
            <div class="card">
              <h3>Order not found</h3>
              <a class="button" href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        const body = `
          <div class="card">
            <h3>Edit Refill Request #${escapeHtml(row.id)}</h3>
            <p class="muted">Created: ${escapeHtml(row.created_at || '')}</p>
          </div>

          <form method="post" action="/portal/orders/${escapeHtml(row.id)}/edit">
            <div class="card">
              <h3>Patient Information</h3>

              <div class="grid">
                <div>
                  <label>First Name</label>
                  <input name="first_name" value="${escapeHtml(row.first_name || '')}" required>
                </div>

                <div>
                  <label>Last Name</label>
                  <input name="last_name" value="${escapeHtml(row.last_name || '')}" required>
                </div>

                <div>
                  <label>Date of Birth</label>
                  <input name="date_of_birth" value="${escapeHtml(row.date_of_birth || '')}" placeholder="MM/DD/YYYY" required>
                </div>

                <div>
                  <label>Phone</label>
                  <input name="phone" value="${escapeHtml(row.phone || '')}" placeholder="+19785551234">
                </div>

                <div>
                  <label>Address</label>
                  <input name="address" value="${escapeHtml(row.address || '')}" required>
                </div>
              </div>
            </div>

            <div class="card">
              <h3>Refill Request</h3>

              <div class="grid">
                <div>
                  <label>Medication Requested</label>
                  <input name="requested_medication" value="${escapeHtml(row.requested_medication || '')}" required>
                  <p class="muted">Current match: ${escapeHtml(row.brand_name || row.generic_name || 'No medication match')}</p>
                </div>

                <div>
                  <label>Status</label>
                  <select name="status">
                    <option value="pending" ${row.status === 'pending' ? 'selected' : ''}>Pending</option>
                    <option value="called_back" ${row.status === 'called_back' ? 'selected' : ''}>Called Back</option>
                    <option value="fulfilled" ${row.status === 'fulfilled' ? 'selected' : ''}>Fulfilled</option>
                    <option value="needs_follow_up" ${row.status === 'needs_follow_up' ? 'selected' : ''}>Needs Follow-Up</option>
                    <option value="out_of_stock" ${row.status === 'out_of_stock' ? 'selected' : ''}>Out of Stock</option>
                  </select>
                </div>
              </div>

              <label>Agent Notes</label>
              <textarea name="agent_notes" rows="5">${escapeHtml(row.agent_notes || '')}</textarea>

              <p class="warning">
                If you change the medication name, the system will try to match it against the medication inventory.
                If no match is found, it will keep the existing medication link but update the requested text.
              </p>

              <button type="submit">Save Changes</button>
              <a class="button button-muted" href="/portal/orders">Cancel</a>
            </div>
          </form>
        `;

        res.send(pageLayout('Edit Refill Request', body, req.session.portalUser));
      }
    );
  });

  app.post('/portal/orders/:id/edit', requirePortalLogin, function (req, res) {
    const orderId = req.params.id;

    const firstName = String(req.body.first_name || '').trim();
    const lastName = String(req.body.last_name || '').trim();
    const dateOfBirth = String(req.body.date_of_birth || '').trim();
    const phone = String(req.body.phone || '').trim();
    const address = String(req.body.address || '').trim();
    const requestedMedication = String(req.body.requested_medication || '').trim();
    const status = String(req.body.status || 'pending').trim();
    const agentNotes = String(req.body.agent_notes || '').trim();

    const allowedStatuses = [
      'pending',
      'called_back',
      'fulfilled',
      'needs_follow_up',
      'out_of_stock'
    ];

    if (!firstName || !lastName || !dateOfBirth || !address || !requestedMedication) {
      return res.status(400).send(pageLayout('Missing Fields', `
        <div class="card">
          <h3>Missing required fields</h3>
          <p>First name, last name, DOB, address, and medication are required.</p>
          <a class="button" href="/portal/orders/${escapeHtml(orderId)}/edit">Back</a>
        </div>
      `, req.session.portalUser));
    }

    if (!allowedStatuses.includes(status)) {
      return res.status(400).send(pageLayout('Invalid Status', `
        <div class="card">
          <h3>Invalid status</h3>
          <a class="button" href="/portal/orders/${escapeHtml(orderId)}/edit">Back</a>
        </div>
      `, req.session.portalUser));
    }

    const db = openDb();

    db.get(
      `
        SELECT id, patient_id, medication_id
        FROM refill_requests
        WHERE id = ?
        LIMIT 1
      `,
      [orderId],
      function (lookupErr, order) {
        if (lookupErr) {
          db.close();

          return res.status(500).send(pageLayout('Lookup Error', `
            <div class="card">
              <h3>Could not load order</h3>
              <p>${escapeHtml(lookupErr.message)}</p>
              <a class="button" href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        if (!order) {
          db.close();

          return res.status(404).send(pageLayout('Order Not Found', `
            <div class="card">
              <h3>Order not found</h3>
              <a class="button" href="/portal/orders">Back to orders</a>
            </div>
          `, req.session.portalUser));
        }

        findMedication(db, requestedMedication, function (medErr, med) {
          if (medErr) {
            db.close();

            return res.status(500).send(pageLayout('Medication Lookup Error', `
              <div class="card">
                <h3>Could not match medication</h3>
                <p>${escapeHtml(medErr.message)}</p>
                <a class="button" href="/portal/orders/${escapeHtml(orderId)}/edit">Back</a>
              </div>
            `, req.session.portalUser));
          }

          const medicationId = med && med.id ? med.id : order.medication_id;

          db.run(
            `
              UPDATE patients
              SET first_name = ?,
                  last_name = ?,
                  date_of_birth = ?,
                  address = ?,
                  phone = ?
              WHERE id = ?
            `,
            [firstName, lastName, dateOfBirth, address, phone, order.patient_id],
            function (patientErr) {
              if (patientErr) {
                db.close();

                return res.status(500).send(pageLayout('Patient Update Error', `
                  <div class="card">
                    <h3>Could not update patient</h3>
                    <p>${escapeHtml(patientErr.message)}</p>
                    <a class="button" href="/portal/orders/${escapeHtml(orderId)}/edit">Back</a>
                  </div>
                `, req.session.portalUser));
              }

              const fulfilledSql = status === 'fulfilled'
                ? `fulfilled_at = COALESCE(fulfilled_at, CURRENT_TIMESTAMP),`
                : `fulfilled_at = NULL,`;

              db.run(
                `
                  UPDATE refill_requests
                  SET requested_medication = ?,
                      medication_id = ?,
                      status = ?,
                      agent_notes = ?,
                      ${fulfilledSql}
                      updated_at = CURRENT_TIMESTAMP
                  WHERE id = ?
                `,
                [requestedMedication, medicationId, status, agentNotes, orderId],
                function (orderErr) {
                  db.close();

                  if (orderErr) {
                    return res.status(500).send(pageLayout('Order Update Error', `
                      <div class="card">
                        <h3>Could not update order</h3>
                        <p>${escapeHtml(orderErr.message)}</p>
                        <a class="button" href="/portal/orders/${escapeHtml(orderId)}/edit">Back</a>
                      </div>
                    `, req.session.portalUser));
                  }

                  res.redirect('/portal/orders');
                }
              );
            }
          );
        });
      }
    );
  });
}

module.exports = {
  installOrderEditRoutes
};
