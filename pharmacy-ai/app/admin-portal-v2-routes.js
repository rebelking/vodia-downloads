'use strict';

const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'pharmacy.db');

function openDb() {
  return new sqlite3.Database(DB_PATH);
}

function all(sql, params = []) {
  return new Promise((resolve, reject) => {
    const db = openDb();
    db.all(sql, params, (err, rows) => {
      db.close();
      if (err) return reject(err);
      resolve(rows || []);
    });
  });
}

function get(sql, params = []) {
  return new Promise((resolve, reject) => {
    const db = openDb();
    db.get(sql, params, (err, row) => {
      db.close();
      if (err) return reject(err);
      resolve(row || null);
    });
  });
}

function run(sql, params = []) {
  return new Promise((resolve, reject) => {
    const db = openDb();
    db.run(sql, params, function (err) {
      db.close();
      if (err) return reject(err);
      resolve(this);
    });
  });
}

async function tableExists(name) {
  const row = await get(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [name]
  );
  return !!row;
}

async function getColumns(tableName) {
  try {
    const rows = await all(`PRAGMA table_info(${tableName})`);
    return rows.map(r => r.name);
  } catch (err) {
    return [];
  }
}

function firstValue(row, names, fallback = '') {
  for (const name of names) {
    if (row && row[name] !== undefined && row[name] !== null && String(row[name]).trim() !== '') {
      return row[name];
    }
  }
  return fallback;
}

function initialsFromName(name) {
  return String(name || 'Unknown Patient')
    .split(/\s+/)
    .filter(Boolean)
    .slice(0, 2)
    .map(part => part[0].toUpperCase())
    .join('') || 'PT';
}

function normalizePhone(phone) {
  const raw = String(phone || '').trim();
  if (!raw) return '';
  const digits = raw.replace(/\D/g, '');
  if (digits.length === 10) {
    return `(${digits.slice(0, 3)}) ${digits.slice(3, 6)}-${digits.slice(6)}`;
  }
  if (digits.length === 11 && digits[0] === '1') {
    return `(${digits.slice(1, 4)}) ${digits.slice(4, 7)}-${digits.slice(7)}`;
  }
  return raw;
}

function statusToUi(status, stockStatus) {
  const s = String(status || '').toLowerCase();
  const stock = String(stockStatus || '').toLowerCase();

  if (s.includes('approved')) return 'approved';
  if (s.includes('reject')) return 'rejected';
  if (s.includes('hold')) return 'hold';
  if (s.includes('fulfilled') || s.includes('complete')) return 'approved';
  if (s.includes('called')) return 'hold';
  if (stock.includes('out')) return 'hold';
  return 'pending';
}

function requestTypeLabel(value) {
  const v = String(value || '').toLowerCase();

  if (v === 'refill') return 'Refill';
  if (v === 'stock_question') return 'Stock check';
  if (v === 'medication_order') return 'Medication request';
  if (v === 'new_rx') return 'New Rx';

  return value || 'Medication request';
}

function orderTypePill(value) {
  const label = requestTypeLabel(value);
  return label;
}

function buildTranscript(row) {
  const pieces = [];

  const summary = firstValue(row, ['ai_summary', 'summary', 'call_summary'], '');
  const notes = firstValue(row, ['agent_notes', 'notes', 'customer_question'], '');
  const stock = firstValue(row, ['stock_status'], '');

  if (summary) pieces.push(summary);
  if (notes) pieces.push(notes);
  if (stock) pieces.push('Stock status: ' + stock);

  if (!pieces.length) {
    pieces.push('AI collected the pharmacy request and submitted it for staff review.');
  }

  return pieces.join(' ');
}

function mapOrderRow(row) {
  const id = firstValue(row, ['id'], '');
  const requestId = 'ORD-' + String(id).padStart(5, '0');

  const name = firstValue(row, [
    'customer_name',
    'caller_name',
    'patient_name',
    'name'
  ], 'Unknown Patient');

  const med = firstValue(row, [
    'requested_medication',
    'medication',
    'drug_name',
    'drug'
  ], 'Unknown medication');

  const dob = firstValue(row, [
    'date_of_birth',
    'dob'
  ], 'UNKNOWN');

  const phone = firstValue(row, [
    'callback_phone',
    'phone',
    'caller_phone'
  ], '');

  const address = firstValue(row, [
    'validated_address',
    'address',
    'original_address'
  ], '');

  const requestType = firstValue(row, [
    'request_type',
    'type'
  ], 'medication_order');

  const status = firstValue(row, [
    'pharmacist_status',
    'review_status',
    'status'
  ], 'pending');

  const createdAt = firstValue(row, [
    'created_at',
    'created',
    'timestamp'
  ], '');

  const updatedAt = firstValue(row, [
    'updated_at',
    'updated'
  ], '');

  const stockStatus = firstValue(row, [
    'stock_status'
  ], '');

  const quantity = firstValue(row, [
    'quantity_requested',
    'quantity',
    'qty'
  ], '1');

  const callDuration = firstValue(row, [
    'call_duration',
    'duration'
  ], '');

  return {
    raw_id: id,
    id: requestId,
    name: name,
    initials: initialsFromName(name),
    dob: dob,
    mrn: firstValue(row, ['mrn', 'patient_id'], String(firstValue(row, ['patient_id'], id)).padStart(5, '0')),
    phone: normalizePhone(phone),
    phone_raw: phone,
    address: address,
    type: orderTypePill(requestType),
    request_type: requestType,
    drug: med,
    qty: quantity === '1' ? 'Not specified' : quantity,
    sig: firstValue(row, ['sig', 'instructions'], 'Pending pharmacy review'),
    prescriber: firstValue(row, ['prescriber'], 'Pending review'),
    written: firstValue(row, ['rx_written', 'written'], 'Pending review'),
    controlled: firstValue(row, ['controlled_substance'], 'Unknown'),
    refillsLeft: firstValue(row, ['refills_left', 'refills_remaining'], '—'),
    refillsTotal: firstValue(row, ['refills_total'], '—'),
    lastFilled: firstValue(row, ['last_filled'], '—'),
    insurance: firstValue(row, ['insurance_plan'], 'Not verified'),
    memberId: firstValue(row, ['member_id'], '—'),
    group: firstValue(row, ['insurance_group'], '—'),
    copay: firstValue(row, ['copay'], '—'),
    insStatus: firstValue(row, ['insurance_status'], 'pending'),
    flags: buildFlags(row),
    transcript: buildTranscript(row),
    callTime: createdAt ? String(createdAt).replace('T', ' ').slice(0, 16) : '—',
    callDur: callDuration || '—',
    status: statusToUi(status, stockStatus),
    created_at: createdAt,
    updated_at: updatedAt
  };
}

function buildFlags(row) {
  const flags = [];

  const stockStatus = String(firstValue(row, ['stock_status'], '')).toLowerCase();
  const addressValid = firstValue(row, ['address_valid'], '');
  const addressStatus = firstValue(row, ['address_validation_status'], '');
  const blocked = firstValue(row, ['blocked'], '');

  if (blocked === 1 || blocked === '1' || blocked === true) {
    flags.push({ type: 'danger', msg: 'Blocked medication request' });
  }

  if (stockStatus.includes('out')) {
    flags.push({ type: 'warn', msg: 'Out of stock or needs review' });
  } else if (stockStatus.includes('not_found')) {
    flags.push({ type: 'warn', msg: 'Medication not found in inventory' });
  } else if (stockStatus.includes('stock')) {
    flags.push({ type: 'success', msg: 'Inventory checked' });
  }

  if (addressValid === 1 || addressValid === '1' || addressValid === true) {
    flags.push({ type: 'success', msg: 'Address validation: ' + (addressStatus || 'validated') });
  } else if (addressStatus) {
    flags.push({ type: 'warn', msg: 'Address validation: ' + addressStatus });
  }

  if (!flags.length) {
    flags.push({ type: 'gray', msg: 'Awaiting pharmacy review' });
  }

  return flags;
}

async function ensureReviewTables() {
  await run(`
    CREATE TABLE IF NOT EXISTS order_review_actions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      request_id INTEGER,
      action TEXT NOT NULL,
      note TEXT,
      created_by TEXT DEFAULT 'admin_portal',
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
    )
  `);

  const cols = await getColumns('refill_requests');

  if (cols.length && !cols.includes('pharmacist_status')) {
    await run(`ALTER TABLE refill_requests ADD COLUMN pharmacist_status TEXT DEFAULT 'pending'`);
  }

  if (cols.length && !cols.includes('pharmacist_reviewed_at')) {
    await run(`ALTER TABLE refill_requests ADD COLUMN pharmacist_reviewed_at TEXT`);
  }

  if (cols.length && !cols.includes('pharmacist_review_note')) {
    await run(`ALTER TABLE refill_requests ADD COLUMN pharmacist_review_note TEXT`);
  }
}

module.exports = function registerAdminPortalV2(app) {
  app.get('/admin-v2', function (req, res) {
    res.sendFile(path.join(__dirname, 'public', 'admin-v2.html'));
  });

  app.get('/api/admin-v2/orders', async function (req, res) {
    try {
      if (!(await tableExists('refill_requests'))) {
        return res.json({ success: true, orders: [] });
      }

      const rows = await all(`
        SELECT *
        FROM refill_requests
        ORDER BY id DESC
        LIMIT 100
      `);

      res.json({
        success: true,
        orders: rows.map(mapOrderRow)
      });
    } catch (err) {
      console.error('admin-v2 orders failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.get('/api/admin-v2/patients', async function (req, res) {
    try {
      let rows = [];

      if (await tableExists('patients')) {
        rows = await all(`
          SELECT *
          FROM patients
          ORDER BY id DESC
          LIMIT 200
        `);

        rows = rows.map(row => ({
          name: firstValue(row, ['name', 'patient_name', 'customer_name'], 'Unknown Patient'),
          dob: firstValue(row, ['date_of_birth', 'dob'], 'UNKNOWN'),
          phone: normalizePhone(firstValue(row, ['phone', 'callback_phone'], '')),
          rx: firstValue(row, ['active_rx', 'med_count'], '—'),
          lastOrder: firstValue(row, ['updated_at', 'created_at'], '—'),
          status: firstValue(row, ['status'], 'Active')
        }));
      } else if (await tableExists('refill_requests')) {
        rows = await all(`
          SELECT
            customer_name,
            date_of_birth,
            callback_phone,
            COUNT(*) AS request_count,
            MAX(created_at) AS last_order
          FROM refill_requests
          GROUP BY customer_name, date_of_birth, callback_phone
          ORDER BY MAX(created_at) DESC
          LIMIT 200
        `);

        rows = rows.map(row => ({
          name: firstValue(row, ['customer_name'], 'Unknown Patient'),
          dob: firstValue(row, ['date_of_birth'], 'UNKNOWN'),
          phone: normalizePhone(firstValue(row, ['callback_phone'], '')),
          rx: row.request_count || 0,
          lastOrder: row.last_order || '—',
          status: 'Active'
        }));
      }

      res.json({ success: true, patients: rows });
    } catch (err) {
      console.error('admin-v2 patients failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.get('/api/admin-v2/callbacks', async function (req, res) {
    try {
      if (!(await tableExists('refill_requests'))) {
        return res.json({ success: true, callbacks: [] });
      }

      const rows = await all(`
        SELECT *
        FROM refill_requests
        WHERE
          LOWER(COALESCE(status, '')) LIKE '%follow%'
          OR LOWER(COALESCE(status, '')) LIKE '%pending%'
          OR LOWER(COALESCE(stock_status, '')) LIKE '%out%'
          OR LOWER(COALESCE(stock_status, '')) LIKE '%not_found%'
        ORDER BY id DESC
        LIMIT 50
      `);

      const callbacks = rows.map(row => ({
        id: firstValue(row, ['id'], ''),
        name: firstValue(row, ['customer_name', 'patient_name'], 'Unknown Patient'),
        reason: firstValue(row, ['stock_status', 'status'], 'Follow-up needed'),
        note: buildTranscript(row),
        time: firstValue(row, ['created_at'], '—'),
        phone: normalizePhone(firstValue(row, ['callback_phone'], '')),
        phone_raw: firstValue(row, ['callback_phone'], '')
      }));

      res.json({ success: true, callbacks: callbacks });
    } catch (err) {
      console.error('admin-v2 callbacks failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.get('/api/admin-v2/dashboard', async function (req, res) {
    try {
      if (!(await tableExists('refill_requests'))) {
        return res.json({
          success: true,
          stats: { ordersToday: 0, approved: 0, pending: 0, callsHandled: 0 },
          activity: []
        });
      }

      const totalToday = await get(`
        SELECT COUNT(*) AS count
        FROM refill_requests
        WHERE DATE(created_at) = DATE('now')
      `);

      const pending = await get(`
        SELECT COUNT(*) AS count
        FROM refill_requests
        WHERE LOWER(COALESCE(pharmacist_status, status, 'pending')) LIKE '%pending%'
      `);

      const approved = await get(`
        SELECT COUNT(*) AS count
        FROM refill_requests
        WHERE LOWER(COALESCE(pharmacist_status, status, '')) LIKE '%approved%'
           OR LOWER(COALESCE(status, '')) LIKE '%fulfilled%'
           OR LOWER(COALESCE(status, '')) LIKE '%completed%'
      `);

      const recentRows = await all(`
        SELECT *
        FROM refill_requests
        ORDER BY id DESC
        LIMIT 10
      `);

      const activity = recentRows.map(row => ({
        time: firstValue(row, ['created_at'], '—'),
        event: 'Request created',
        patient: firstValue(row, ['customer_name', 'patient_name'], 'Unknown Patient'),
        drug: firstValue(row, ['requested_medication', 'medication'], 'Unknown medication')
      }));

      res.json({
        success: true,
        stats: {
          ordersToday: totalToday ? totalToday.count : 0,
          approved: approved ? approved.count : 0,
          pending: pending ? pending.count : 0,
          callsHandled: totalToday ? totalToday.count : 0
        },
        activity: activity
      });
    } catch (err) {
      console.error('admin-v2 dashboard failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.post('/api/admin-v2/orders/:id/action', async function (req, res) {
    try {
      await ensureReviewTables();

      const id = Number(req.params.id);
      const action = String((req.body && req.body.action) || '').toLowerCase();
      const note = String((req.body && req.body.note) || '').trim();

      if (!id) {
        return res.status(400).json({ success: false, error: 'Missing order id' });
      }

      if (!['approve', 'reject', 'hold'].includes(action)) {
        return res.status(400).json({ success: false, error: 'Invalid action' });
      }

      const statusMap = {
        approve: 'approved',
        reject: 'rejected',
        hold: 'hold'
      };

      await run(`
        UPDATE refill_requests
        SET
          pharmacist_status = ?,
          pharmacist_reviewed_at = CURRENT_TIMESTAMP,
          pharmacist_review_note = ?
        WHERE id = ?
      `, [statusMap[action], note, id]);

      await run(`
        INSERT INTO order_review_actions
        (request_id, action, note)
        VALUES (?, ?, ?)
      `, [id, action, note]);

      res.json({
        success: true,
        id: id,
        action: action,
        status: statusMap[action]
      });
    } catch (err) {
      console.error('admin-v2 action failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
};
