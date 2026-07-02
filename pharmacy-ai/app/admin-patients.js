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

function requireAdmin(req, res, next) {
  if (req.session && req.session.portalUser && req.session.portalUser.role === 'admin') {
    return next();
  }

  return res.status(403).send(pageLayout('Access Denied', `
    <div class="card">
      <h3>Access denied</h3>
      <p>You do not have admin access.</p>
      <a href="/portal/orders">Back to orders</a>
    </div>
  `));
}

function normalizePhoneE164(phone) {
  const raw = String(phone || '').trim();

  if (!raw) return '';

  if (raw.startsWith('+')) {
    const digits = raw.replace(/\D/g, '');
    const e164 = '+' + digits;

    if (/^\+\d{8,15}$/.test(e164)) {
      return e164;
    }

    return '';
  }

  const digits = raw.replace(/\D/g, '');

  if (digits.length === 10) {
    return '+1' + digits;
  }

  if (digits.length === 11 && digits.startsWith('1')) {
    return '+' + digits;
  }

  if (digits.length >= 8 && digits.length <= 15) {
    return '+' + digits;
  }

  return '';
}

function renderPhone(phone) {
  const display = escapeHtml(phone || 'Not provided');
  const e164 = normalizePhoneE164(phone);

  if (!e164) return display;

  return `<a href="tel:${escapeHtml(e164)}">${display}</a><br><span class="muted">${escapeHtml(e164)}</span>`;
}

function csvEscape(value) {
  const str = String(value || '');
  return '"' + str.replace(/"/g, '""') + '"';
}

function sendCsv(res, filename, rows) {
  const header = [
    'id',
    'first_name',
    'last_name',
    'date_of_birth',
    'address',
    'phone',
    'phone_e164',
    'email',
    'customer_notes',
    'created_at',
    'updated_at'
  ];

  const lines = [header.join(',')];

  rows.forEach(function (row) {
    lines.push([
      csvEscape(row.id),
      csvEscape(row.first_name),
      csvEscape(row.last_name),
      csvEscape(row.date_of_birth),
      csvEscape(row.address),
      csvEscape(row.phone),
      csvEscape(normalizePhoneE164(row.phone)),
      csvEscape(row.email),
      csvEscape(row.customer_notes),
      csvEscape(row.created_at),
      csvEscape(row.updated_at)
    ].join(','));
  });

  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.send(lines.join('\n'));
}

function parseCsvLine(line) {
  const result = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    const next = line[i + 1];

    if (char === '"' && inQuotes && next === '"') {
      current += '"';
      i++;
      continue;
    }

    if (char === '"') {
      inQuotes = !inQuotes;
      continue;
    }

    if (char === ',' && !inQuotes) {
      result.push(current.trim());
      current = '';
      continue;
    }

    current += char;
  }

  result.push(current.trim());
  return result;
}

function normalizeHeader(header) {
  return String(header || '')
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '');
}

function mapCsvRow(headers, values) {
  const row = {};

  headers.forEach(function (header, index) {
    const key = normalizeHeader(header);
    const value = values[index] || '';

    if (['firstname', 'first', 'fname'].includes(key)) row.first_name = value;
    if (['lastname', 'last', 'lname'].includes(key)) row.last_name = value;
    if (['dateofbirth', 'dob', 'birthdate'].includes(key)) row.date_of_birth = value;
    if (['address', 'homeaddress', 'streetaddress'].includes(key)) row.address = value;
    if (['phone', 'phonenumber', 'mobile', 'cell', 'cellphone'].includes(key)) row.phone = value;
    if (['email', 'emailaddress'].includes(key)) row.email = value;
    if (['notes', 'customernotes', 'patientnotes'].includes(key)) row.customer_notes = value;
  });

  return row;
}

function pageLayout(title, body) {
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
    input, textarea, button {
      font-size: 14px;
      padding: 9px;
      box-sizing: border-box;
    }
    input, textarea {
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
    .button-green {
      background: #1c7c37;
    }
    .button-blue {
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
    .muted {
      color: #666;
      font-size: 13px;
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
  <script>
    function exportSelectedPatients() {
      const checked = Array.from(document.querySelectorAll('input[name="patient_id"]:checked'))
        .map(function (box) { return box.value; });

      if (checked.length === 0) {
        alert('Select at least one patient to export.');
        return;
      }

      window.location.href = '/admin/patients/export.csv?ids=' + encodeURIComponent(checked.join(','));
    }

    function togglePatients(source) {
      document.querySelectorAll('input[name="patient_id"]').forEach(function (box) {
        box.checked = source.checked;
      });
    }
  </script>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <header>
    <h2>Vodia Pharmacy Admin</h2>
    <a href="/portal/orders">Agent Orders</a><a href="/portal/chat">Chat</a>
    <a href="/admin/users">Admin Users</a>
    <a href="/admin/patients">Patients</a><a href="/admin/medications">Medications</a>
    <a href="/admin/history">History</a><a href="/portal/voice-agent">Voice Agent</a><a href="/portal/logout">Logout</a>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>
`;
}

function getSql(db, sql, params = []) {
  return new Promise(function (resolve, reject) {
    db.get(sql, params, function (err, row) {
      if (err) return reject(err);
      resolve(row);
    });
  });
}

function runSql(db, sql, params = []) {
  return new Promise(function (resolve, reject) {
    db.run(sql, params, function (err) {
      if (err) return reject(err);
      resolve(this);
    });
  });
}

async function upsertPatient(db, patient) {
  const firstName = String(patient.first_name || '').trim();
  const lastName = String(patient.last_name || '').trim();
  const dateOfBirth = String(patient.date_of_birth || '').trim();
  const address = String(patient.address || '').trim();
  const phone = String(patient.phone || '').trim();
  const email = String(patient.email || '').trim();
  const notes = String(patient.customer_notes || '').trim();

  if (!firstName || !lastName || !dateOfBirth || !address) {
    return {
      success: false,
      action: 'skipped',
      error: 'Missing first_name, last_name, date_of_birth, or address.'
    };
  }

  const existing = await getSql(
    db,
    `
      SELECT id
      FROM patients
      WHERE date_of_birth = ?
      AND lower(address) = lower(?)
      LIMIT 1
    `,
    [dateOfBirth, address]
  );

  if (existing) {
    await runSql(
      db,
      `
        UPDATE patients
        SET first_name = ?,
            last_name = ?,
            phone = ?,
            email = ?,
            customer_notes = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [firstName, lastName, phone, email, notes, existing.id]
    );

    return {
      success: true,
      action: 'updated',
      id: existing.id
    };
  }

  const result = await runSql(
    db,
    `
      INSERT INTO patients
      (first_name, last_name, date_of_birth, address, phone, email, customer_notes)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `,
    [firstName, lastName, dateOfBirth, address, phone, email, notes]
  );

  return {
    success: true,
    action: 'inserted',
    id: result.lastID
  };
}

function installAdminPatientRoutes(app, openDb) {
  app.get('/admin/patients', requirePortalLogin, requireAdmin, function (req, res) {
    const search = String(req.query.search || '').trim();
    const db = openDb();

    let whereSql = '';
    let params = [];

    if (search) {
      whereSql = `
        WHERE lower(first_name || ' ' || last_name || ' ' || address || ' ' || phone || ' ' || ifnull(email, ''))
        LIKE lower(?)
      `;
      params = ['%' + search + '%'];
    }

    db.all(
      `
        SELECT id, first_name, last_name, date_of_birth, address, phone, email, customer_notes, created_at, updated_at
        FROM patients
        ${whereSql}
        ORDER BY created_at DESC
        LIMIT 500
      `,
      params,
      function (err, patients) {
        db.close();

        if (err) {
          return res.status(500).send(pageLayout('Patients Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
            </div>
          `));
        }

        const rows = patients.map(function (patient) {
          return `
            <tr>
              <td><input type="checkbox" name="patient_id" value="${patient.id}"></td>
              <td>#${patient.id}</td>
              <td>
                <strong>${escapeHtml(patient.first_name)} ${escapeHtml(patient.last_name)}</strong><br>
                <span class="muted">DOB: ${escapeHtml(patient.date_of_birth)}</span>
              </td>
              <td>${escapeHtml(patient.address)}</td>
              <td>${renderPhone(patient.phone)}</td>
              <td>${escapeHtml(patient.email || '')}</td>
              <td>
                ${escapeHtml(patient.customer_notes || '')}<br>
                <span class="muted">Created: ${escapeHtml(patient.created_at || '')}</span><br>
                <span class="muted">Updated: ${escapeHtml(patient.updated_at || '')}</span>
              </td>
            </tr>
          `;
        }).join('');

        const body = `
          <div class="card">
            <h3>Patient / Customer Management</h3>
            <p class="muted">Add patients manually, bulk paste CSV, and export patient records.</p>

            <form method="get" action="/admin/patients">
              <input name="search" value="${escapeHtml(search)}" placeholder="Search name, address, phone, or email">
              <button type="submit">Search</button>
              <a class="button" href="/admin/patients">Clear</a>
              <a class="button button-green" href="/admin/patients/export.csv">Export All CSV</a>
              <button type="button" class="button-blue" onclick="exportSelectedPatients()">Export Selected CSV</button>
            </form>
          </div>

          <div class="card">
            <h3>Add Single Patient</h3>
            <form method="post" action="/admin/patients">
              <div class="grid">
                <div>
                  <label>First Name</label>
                  <input name="first_name" required>
                </div>
                <div>
                  <label>Last Name</label>
                  <input name="last_name" required>
                </div>
                <div>
                  <label>Date of Birth</label>
                  <input name="date_of_birth" placeholder="MM/DD/YYYY" required>
                </div>
                <div>
                  <label>Phone</label>
                  <input name="phone" placeholder="978-555-1234">
                </div>
                <div>
                  <label>Email</label>
                  <input name="email" type="email">
                </div>
                <div>
                  <label>Address</label>
                  <input name="address" required>
                </div>
              </div>
              <label>Notes</label>
              <textarea name="customer_notes" rows="2"></textarea>
              <button type="submit">Save Patient</button>
            </form>
          </div>

          <div class="card">
            <h3>Bulk Paste CSV</h3>
            <p class="muted">
              Required headers: first_name,last_name,date_of_birth,address<br>
              Optional headers: phone,email,notes
            </p>
            <form method="post" action="/admin/patients/import-csv">
              <textarea name="csv_data" rows="9" placeholder="first_name,last_name,date_of_birth,address,phone,email,notes&#10;John,Doe,01/01/1980,123 Main Street,978-555-1234,john@example.com,VIP patient"></textarea>
              <button type="submit">Import CSV</button>
            </form>
          </div>

          <div class="card">
            <h3>Patients</h3>
            <p class="muted">Showing up to 500 records.</p>
          </div>

          <table>
            <thead>
              <tr>
                <th><input type="checkbox" onclick="togglePatients(this)"></th>
                <th>ID</th>
                <th>Name / DOB</th>
                <th>Address</th>
                <th>Phone</th>
                <th>Email</th>
                <th>Notes / Dates</th>
              </tr>
            </thead>
            <tbody>
              ${rows || '<tr><td colspan="7">No patients found.</td></tr>'}
            </tbody>
          </table>
        `;

        res.send(pageLayout('Admin Patients', body));
      }
    );
  });

  app.post('/admin/patients', requirePortalLogin, requireAdmin, async function (req, res) {
    const db = openDb();

    try {
      const result = await upsertPatient(db, req.body);
      db.close();

      if (!result.success) {
        return res.status(400).send(pageLayout('Patient Error', `
          <div class="card">
            <h3>Could not save patient</h3>
            <p>${escapeHtml(result.error)}</p>
            <a href="/admin/patients">Back to patients</a>
          </div>
        `));
      }

      res.redirect('/admin/patients');
    } catch (err) {
      db.close();

      res.status(500).send(pageLayout('Patient Save Error', `
        <div class="card">
          <h3>Database error</h3>
          <p>${escapeHtml(err.message)}</p>
          <a href="/admin/patients">Back to patients</a>
        </div>
      `));
    }
  });

  app.post('/admin/patients/import-csv', requirePortalLogin, requireAdmin, async function (req, res) {
    const csvData = String(req.body.csv_data || '').trim();

    if (!csvData) {
      return res.status(400).send(pageLayout('CSV Error', `
        <div class="card">
          <h3>No CSV data provided</h3>
          <a href="/admin/patients">Back to patients</a>
        </div>
      `));
    }

    const lines = csvData
      .split(/\r?\n/)
      .map(function (line) { return line.trim(); })
      .filter(Boolean);

    if (lines.length < 2) {
      return res.status(400).send(pageLayout('CSV Error', `
        <div class="card">
          <h3>CSV must include a header row and at least one patient row.</h3>
          <a href="/admin/patients">Back to patients</a>
        </div>
      `));
    }

    const headers = parseCsvLine(lines[0]);
    const db = openDb();

    let inserted = 0;
    let updated = 0;
    let skipped = 0;
    const errors = [];

    try {
      for (let i = 1; i < lines.length; i++) {
        const values = parseCsvLine(lines[i]);
        const patient = mapCsvRow(headers, values);
        const result = await upsertPatient(db, patient);

        if (result.action === 'inserted') inserted++;
        else if (result.action === 'updated') updated++;
        else {
          skipped++;
          errors.push(`Line ${i + 1}: ${result.error}`);
        }
      }

      db.close();

      res.send(pageLayout('CSV Import Complete', `
        <div class="card">
          <h3>CSV Import Complete</h3>
          <p><strong>Inserted:</strong> ${inserted}</p>
          <p><strong>Updated:</strong> ${updated}</p>
          <p><strong>Skipped:</strong> ${skipped}</p>
          ${
            errors.length
              ? `<div class="warning"><strong>Errors:</strong><br>${errors.map(escapeHtml).join('<br>')}</div>`
              : '<div class="success">No errors.</div>'
          }
          <a href="/admin/patients">Back to patients</a>
        </div>
      `));
    } catch (err) {
      db.close();

      res.status(500).send(pageLayout('CSV Import Error', `
        <div class="card">
          <h3>Import failed</h3>
          <p>${escapeHtml(err.message)}</p>
          <a href="/admin/patients">Back to patients</a>
        </div>
      `));
    }
  });

  app.get('/admin/patients/export.csv', requirePortalLogin, requireAdmin, function (req, res) {
    const ids = String(req.query.ids || '').trim();
    const db = openDb();

    let sql = `
      SELECT id, first_name, last_name, date_of_birth, address, phone, email, customer_notes, created_at, updated_at
      FROM patients
    `;

    let params = [];

    if (ids) {
      const idList = ids
        .split(',')
        .map(function (id) { return id.trim(); })
        .filter(function (id) { return /^\d+$/.test(id); });

      if (idList.length > 0) {
        sql += ` WHERE id IN (${idList.map(function () { return '?'; }).join(',')})`;
        params = idList;
      }
    }

    sql += ` ORDER BY created_at DESC`;

    db.all(sql, params, function (err, rows) {
      db.close();

      if (err) {
        return res.status(500).send('CSV export failed: ' + err.message);
      }

      const filename = ids ? 'selected-patients.csv' : 'all-patients.csv';
      sendCsv(res, filename, rows);
    });
  });
}

module.exports = {
  installAdminPatientRoutes
};
