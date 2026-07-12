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
  if (req.session && req.session.portalUser) return next();
  return res.redirect('/portal/login');
}

function requireAdmin(req, res, next) {
  if (req.session && req.session.portalUser && req.session.portalUser.role === 'admin') return next();

  return res.status(403).send(pageLayout('Access Denied', `
    <div class="card">
      <h3>Access denied</h3>
      <p>You do not have admin access.</p>
      <a href="/portal/orders">Back to orders</a>
    </div>
  `));
}

function csvEscape(value) {
  const str = String(value || '');
  return '"' + str.replace(/"/g, '""') + '"';
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
  return String(header || '').toLowerCase().replace(/[^a-z0-9]/g, '');
}

function mapCsvRow(headers, values) {
  const row = {};

  headers.forEach(function (header, index) {
    const key = normalizeHeader(header);
    const value = values[index] || '';

    if (['genericname', 'generic', 'medication', 'drug'].includes(key)) row.generic_name = value;
    if (['brandname', 'brand'].includes(key)) row.brand_name = value;
    if (['commonnames', 'knownnames', 'aliases', 'alias'].includes(key)) row.common_names = value;
    if (['available', 'active', 'instock'].includes(key)) row.available = value;
    if (['quantityonhand', 'quantity', 'qty', 'stock'].includes(key)) row.quantity_on_hand = value;
    if (['notes', 'note'].includes(key)) row.notes = value;
  });

  return row;
}

function boolToInt(value) {
  const text = String(value).trim().toLowerCase();

  if (['false', '0', 'no', 'n', 'out', 'out_of_stock'].includes(text)) return 0;
  return 1;
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
    .button-green {
      background: #1c7c37;
    }
    .button-blue {
      background: #1d4ed8;
    }
    .button-orange {
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
    .muted {
      color: #666;
      font-size: 13px;
    }
    .pill {
      padding: 5px 9px;
      border-radius: 999px;
      font-weight: bold;
      display: inline-block;
      font-size: 13px;
    }
    .pill-green {
      background: #dcfce7;
    }
    .pill-red {
      background: #fee2e2;
    }
    @media (max-width: 900px) {
      .grid {
        grid-template-columns: 1fr;
      }
    }
  </style>
  <script>
    function exportSelectedMedications() {
      const checked = Array.from(document.querySelectorAll('input[name="medication_id"]:checked'))
        .map(function (box) { return box.value; });

      if (checked.length === 0) {
        alert('Select at least one medication to export.');
        return;
      }

      window.location.href = '/admin/medications/export.csv?ids=' + encodeURIComponent(checked.join(','));
    }

    function toggleMedications(source) {
      document.querySelectorAll('input[name="medication_id"]').forEach(function (box) {
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
    <a href="/admin/patients">Patients</a>
    <a href="/admin/medications">Medications</a>
    <a href="/admin/history">History</a><a href="/portal/settings">Settings</a><a href="/portal/voice-agent">Voice Agent</a><a href="/portal/logout">Logout</a>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>
`;
}

function sendMedicationCsv(res, filename, rows) {
  const header = [
    'id',
    'generic_name',
    'brand_name',
    'common_names',
    'available',
    'quantity_on_hand',
    'notes',
    'created_at',
    'updated_at'
  ];

  const lines = [header.join(',')];

  rows.forEach(function (row) {
    lines.push([
      csvEscape(row.id),
      csvEscape(row.generic_name),
      csvEscape(row.brand_name),
      csvEscape(row.common_names),
      csvEscape(row.available === 1 ? 'yes' : 'no'),
      csvEscape(row.quantity_on_hand),
      csvEscape(row.notes),
      csvEscape(row.created_at),
      csvEscape(row.updated_at)
    ].join(','));
  });

  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
  res.send(lines.join('\n'));
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

async function upsertMedication(db, med) {
  const genericName = String(med.generic_name || '').trim().toLowerCase();
  const brandName = String(med.brand_name || '').trim();
  const commonNames = String(med.common_names || '').trim();
  const available = med.available === undefined ? 1 : boolToInt(med.available);
  const quantityOnHand = Number(med.quantity_on_hand || 0);
  const notes = String(med.notes || '').trim();

  if (!genericName) {
    return {
      success: false,
      action: 'skipped',
      error: 'Missing generic_name.'
    };
  }

  const existing = await getSql(
    db,
    `
      SELECT id
      FROM medications
      WHERE lower(generic_name) = lower(?)
      AND lower(ifnull(brand_name, '')) = lower(?)
      LIMIT 1
    `,
    [genericName, brandName]
  );

  if (existing) {
    await runSql(
      db,
      `
        UPDATE medications
        SET brand_name = ?,
            common_names = ?,
            available = ?,
            quantity_on_hand = ?,
            notes = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [brandName, commonNames, available, quantityOnHand, notes, existing.id]
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
      INSERT INTO medications
      (generic_name, brand_name, common_names, available, quantity_on_hand, notes)
      VALUES (?, ?, ?, ?, ?, ?)
    `,
    [genericName, brandName, commonNames, available, quantityOnHand, notes]
  );

  return {
    success: true,
    action: 'inserted',
    id: result.lastID
  };
}

function installAdminMedicationRoutes(app, openDb) {
  app.get('/admin/medications', requirePortalLogin, requireAdmin, function (req, res) {
    const search = String(req.query.search || '').trim();
    const db = openDb();

    let whereSql = '';
    let params = [];

    if (search) {
      whereSql = `
        WHERE lower(generic_name || ' ' || ifnull(brand_name, '') || ' ' || ifnull(common_names, '') || ' ' || ifnull(notes, ''))
        LIKE lower(?)
      `;
      params = ['%' + search + '%'];
    }

    db.all(
      `
        SELECT id, generic_name, brand_name, common_names, available, quantity_on_hand, notes, created_at, updated_at
        FROM medications
        ${whereSql}
        ORDER BY generic_name ASC
        LIMIT 500
      `,
      params,
      function (err, medications) {
        db.close();

        if (err) {
          return res.status(500).send(pageLayout('Medications Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
            </div>
          `));
        }

        const rows = medications.map(function (med) {
          const status = med.available === 1 && Number(med.quantity_on_hand || 0) > 0
            ? '<span class="pill pill-green">Available</span>'
            : '<span class="pill pill-red">Out / Review</span>';

          return `
            <tr>
              <td><input type="checkbox" name="medication_id" value="${med.id}"></td>
              <td>#${med.id}</td>
              <td>
                <strong>${escapeHtml(med.generic_name)}</strong><br>
                <span class="muted">Brand: ${escapeHtml(med.brand_name || '')}</span><br>
                <span class="muted">Known as: ${escapeHtml(med.common_names || '')}</span>
              </td>
              <td>${status}</td>
              <td><strong>${escapeHtml(med.quantity_on_hand || 0)}</strong></td>
              <td>
                <form method="post" action="/admin/medications/${med.id}/update">
                  <div class="grid">
                    <div>
                      <label>Brand Name</label>
                      <input name="brand_name" value="${escapeHtml(med.brand_name || '')}">
                    </div>
                    <div>
                      <label>Known Names / Aliases</label>
                      <input name="common_names" value="${escapeHtml(med.common_names || '')}">
                    </div>
                    <div>
                      <label>Quantity On Hand</label>
                      <input name="quantity_on_hand" type="number" min="0" value="${escapeHtml(med.quantity_on_hand || 0)}">
                    </div>
                    <div>
                      <label>Available</label>
                      <select name="available">
                        <option value="1" ${med.available === 1 ? 'selected' : ''}>Yes</option>
                        <option value="0" ${med.available !== 1 ? 'selected' : ''}>No</option>
                      </select>
                    </div>
                  </div>
                  <label>Notes</label>
                  <textarea name="notes" rows="2">${escapeHtml(med.notes || '')}</textarea>
                  <button type="submit">Update Medication</button>
                </form>
              </td>
            </tr>
          `;
        }).join('');

        const body = `
          <div class="card">
            <h3>Medication Inventory</h3>
            <p class="muted">Manage generic names, brand names, known aliases, availability, and quantity on hand.</p>

            <form method="get" action="/admin/medications">
              <input name="search" value="${escapeHtml(search)}" placeholder="Search generic, brand, known name, or notes">
              <button type="submit">Search</button>
              <a class="button" href="/admin/medications">Clear</a>
              <a class="button button-green" href="/admin/medications/export.csv">Export All CSV</a>
              <button type="button" class="button-blue" onclick="exportSelectedMedications()">Export Selected CSV</button>
            </form>
          </div>

          <div class="card">
            <h3>Add Medication</h3>
            <form method="post" action="/admin/medications">
              <div class="grid">
                <div>
                  <label>Generic Name</label>
                  <input name="generic_name" placeholder="metformin" required>
                </div>
                <div>
                  <label>Brand Name</label>
                  <input name="brand_name" placeholder="Glucophage">
                </div>
                <div>
                  <label>Known Names / Aliases</label>
                  <input name="common_names" placeholder="metformin hcl, sugar pill">
                </div>
                <div>
                  <label>Quantity On Hand</label>
                  <input name="quantity_on_hand" type="number" min="0" value="0">
                </div>
                <div>
                  <label>Available</label>
                  <select name="available">
                    <option value="1">Yes</option>
                    <option value="0">No</option>
                  </select>
                </div>
              </div>
              <label>Notes</label>
              <textarea name="notes" rows="2"></textarea>
              <button type="submit">Save Medication</button>
            </form>
          </div>

          <div class="card">
            <h3>Bulk Paste Medication CSV</h3>
            <p class="muted">
              Required header: generic_name<br>
              Optional headers: brand_name,common_names,available,quantity_on_hand,notes
            </p>
            <form method="post" action="/admin/medications/import-csv">
              <textarea name="csv_data" rows="8" placeholder="generic_name,brand_name,common_names,available,quantity_on_hand,notes&#10;metformin,Glucophage,metformin hcl,yes,25,Common diabetes medication"></textarea>
              <button type="submit">Import Medication CSV</button>
            </form>
          </div>

          <table>
            <thead>
              <tr>
                <th><input type="checkbox" onclick="toggleMedications(this)"></th>
                <th>ID</th>
                <th>Medication</th>
                <th>Status</th>
                <th>Stock</th>
                <th>Edit</th>
              </tr>
            </thead>
            <tbody>
              ${rows || '<tr><td colspan="6">No medications found.</td></tr>'}
            </tbody>
          </table>
        `;

        res.send(pageLayout('Admin Medications', body));
      }
    );
  });

  app.post('/admin/medications', requirePortalLogin, requireAdmin, async function (req, res) {
    const db = openDb();

    try {
      await upsertMedication(db, req.body);
      db.close();
      res.redirect('/admin/medications');
    } catch (err) {
      db.close();
      res.status(500).send(pageLayout('Medication Save Error', `
        <div class="card">
          <h3>Could not save medication</h3>
          <p>${escapeHtml(err.message)}</p>
          <a href="/admin/medications">Back to medications</a>
        </div>
      `));
    }
  });

  app.post('/admin/medications/:id/update', requirePortalLogin, requireAdmin, function (req, res) {
    const medId = req.params.id;
    const brandName = String(req.body.brand_name || '').trim();
    const commonNames = String(req.body.common_names || '').trim();
    const available = boolToInt(req.body.available);
    const quantityOnHand = Number(req.body.quantity_on_hand || 0);
    const notes = String(req.body.notes || '').trim();

    const db = openDb();

    db.run(
      `
        UPDATE medications
        SET brand_name = ?,
            common_names = ?,
            available = ?,
            quantity_on_hand = ?,
            notes = ?,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = ?
      `,
      [brandName, commonNames, available, quantityOnHand, notes, medId],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).send(pageLayout('Medication Update Error', `
            <div class="card">
              <h3>Could not update medication</h3>
              <p>${escapeHtml(err.message)}</p>
              <a href="/admin/medications">Back to medications</a>
            </div>
          `));
        }

        res.redirect('/admin/medications');
      }
    );
  });

  app.post('/admin/medications/import-csv', requirePortalLogin, requireAdmin, async function (req, res) {
    const csvData = String(req.body.csv_data || '').trim();

    if (!csvData) {
      return res.status(400).send(pageLayout('CSV Error', `
        <div class="card">
          <h3>No CSV data provided</h3>
          <a href="/admin/medications">Back to medications</a>
        </div>
      `));
    }

    const lines = csvData.split(/\r?\n/).map(line => line.trim()).filter(Boolean);

    if (lines.length < 2) {
      return res.status(400).send(pageLayout('CSV Error', `
        <div class="card">
          <h3>CSV must include a header row and at least one medication row.</h3>
          <a href="/admin/medications">Back to medications</a>
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
        const med = mapCsvRow(headers, values);
        const result = await upsertMedication(db, med);

        if (result.action === 'inserted') inserted++;
        else if (result.action === 'updated') updated++;
        else {
          skipped++;
          errors.push(`Line ${i + 1}: ${result.error}`);
        }
      }

      db.close();

      res.send(pageLayout('Medication CSV Import Complete', `
        <div class="card">
          <h3>Medication CSV Import Complete</h3>
          <p><strong>Inserted:</strong> ${inserted}</p>
          <p><strong>Updated:</strong> ${updated}</p>
          <p><strong>Skipped:</strong> ${skipped}</p>
          ${
            errors.length
              ? `<p>${errors.map(escapeHtml).join('<br>')}</p>`
              : '<p>No errors.</p>'
          }
          <a href="/admin/medications">Back to medications</a>
        </div>
      `));
    } catch (err) {
      db.close();

      res.status(500).send(pageLayout('Medication CSV Import Error', `
        <div class="card">
          <h3>Import failed</h3>
          <p>${escapeHtml(err.message)}</p>
          <a href="/admin/medications">Back to medications</a>
        </div>
      `));
    }
  });

  app.get('/admin/medications/export.csv', requirePortalLogin, requireAdmin, function (req, res) {
    const ids = String(req.query.ids || '').trim();
    const db = openDb();

    let sql = `
      SELECT id, generic_name, brand_name, common_names, available, quantity_on_hand, notes, created_at, updated_at
      FROM medications
    `;

    let params = [];

    if (ids) {
      const idList = ids.split(',').map(id => id.trim()).filter(id => /^\d+$/.test(id));

      if (idList.length > 0) {
        sql += ` WHERE id IN (${idList.map(() => '?').join(',')})`;
        params = idList;
      }
    }

    sql += ` ORDER BY generic_name ASC`;

    db.all(sql, params, function (err, rows) {
      db.close();

      if (err) {
        return res.status(500).send('CSV export failed: ' + err.message);
      }

      const filename = ids ? 'selected-medications.csv' : 'all-medications.csv';
      sendMedicationCsv(res, filename, rows);
    });
  });
}

module.exports = {
  installAdminMedicationRoutes
};
