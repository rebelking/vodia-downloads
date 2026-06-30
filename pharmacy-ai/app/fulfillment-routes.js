'use strict';

const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'pharmacy.db');
const PHARMACY_SECRET =
  process.env.PHARMACY_SECRET ||
  process.env.PHARMACY_API_SECRET ||
  '';

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
    db.run(sql, params, function(err) {
      db.close();
      if (err) return reject(err);
      resolve(this);
    });
  });
}

async function columns(table) {
  const rows = await all(`PRAGMA table_info(${table})`);
  return rows.map(r => r.name);
}

function auth(req, res) {
  const providedSecret = req.get('X-Pharmacy-Secret') || '';

  if (providedSecret !== PHARMACY_SECRET) {
    res.status(401).json({
      success: false,
      error: 'Unauthorized'
    });
    return false;
  }

  return true;
}

function yesNoValue(value) {
  if (value === true || value === 1 || value === '1') return 1;
  const raw = String(value || '').toLowerCase().trim();
  if (raw === 'yes' || raw === 'true' || raw === 'y') return 1;
  return 0;
}

function normalizeMethod(method) {
  const raw = String(method || '').toLowerCase().trim();

  if (raw === 'pickup') return 'pickup';
  if (raw === 'delivery') return 'delivery';

  return 'undecided';
}

function mapStore(row) {
  if (!row) return null;

  return {
    id: row.id,
    store_code: row.store_code || '',
    store_name: row.store_name || '',
    address: row.address || '',
    city: row.city || '',
    state: row.state || '',
    zip: row.zip || '',
    full_address: `${row.address || ''}, ${row.city || ''}, ${row.state || ''} ${row.zip || ''}`.trim(),
    phone: row.phone || '',
    notes: row.notes || ''
  };
}

function mapFulfillment(row) {
  if (!row) return null;

  return {
    id: row.id,
    customer_name: row.customer_name || row.caller_name || row.patient_name || '',
    medication: row.requested_medication || row.medication || '',
    fulfillment_method: row.fulfillment_method || 'undecided',
    pickup_requested: !!row.pickup_requested,
    delivery_requested: !!row.delivery_requested,
    pickup_store_id: row.pickup_store_id || '',
    pickup_store_code: row.pickup_store_code || '',
    pickup_store_name: row.pickup_store_name || '',
    pickup_store_address: row.pickup_store_address || '',
    delivery_address: row.delivery_address || '',
    delivery_address_confirmed: !!row.delivery_address_confirmed,
    delivery_instructions: row.delivery_instructions || '',
    fulfillment_confirmed: !!row.fulfillment_confirmed,
    fulfillment_notes: row.fulfillment_notes || ''
  };
}

module.exports = function registerFulfillmentRoutes(app) {
  app.get('/api/ai/pharmacy-stores', async function(req, res) {
    try {
      if (!auth(req, res)) return;

      const rows = await all(`
        SELECT *
        FROM pharmacy_stores
        WHERE active = 1
        ORDER BY store_name
      `);

      res.json({
        success: true,
        stores: rows.map(mapStore)
      });
    } catch (err) {
      console.error('pharmacy stores failed:', err);
      res.status(500).json({
        success: false,
        error: err.message
      });
    }
  });

  app.post('/api/ai/request-fulfillment', async function(req, res) {
    try {
      if (!auth(req, res)) return;

      const body = req.body || {};
      const requestId = Number(body.request_id || body.refill_request_id || body.id || 0);

      if (!requestId) {
        return res.status(400).json({
          success: false,
          error: 'Missing request_id'
        });
      }

      const method = normalizeMethod(body.fulfillment_method);
      const pickupRequested = method === 'pickup' ? 1 : yesNoValue(body.pickup_requested);
      const deliveryRequested = method === 'delivery' ? 1 : yesNoValue(body.delivery_requested);

      const updatePayload = {
        fulfillment_method: method,
        pickup_requested: pickupRequested,
        delivery_requested: deliveryRequested,

        pickup_store_id: body.pickup_store_id || '',
        pickup_store_code: body.pickup_store_code || '',
        pickup_store_name: body.pickup_store_name || '',
        pickup_store_address: body.pickup_store_address || '',

        delivery_address: body.delivery_address || '',
        delivery_address_confirmed: yesNoValue(body.delivery_address_confirmed),
        delivery_instructions: body.delivery_instructions || '',

        fulfillment_confirmed: yesNoValue(body.fulfillment_confirmed),
        fulfillment_notes: body.fulfillment_notes || ''
      };

      const cols = await columns('refill_requests');
      const setParts = [];
      const values = [];

      Object.keys(updatePayload).forEach(key => {
        if (cols.includes(key)) {
          setParts.push(`${key} = ?`);
          values.push(updatePayload[key]);
        }
      });

      if (!setParts.length) {
        return res.json({
          success: true,
          request_id: requestId,
          updated: false,
          message: 'No matching fulfillment columns found'
        });
      }

      values.push(requestId);

      await run(
        `UPDATE refill_requests SET ${setParts.join(', ')} WHERE id = ?`,
        values
      );

      const row = await get(
        `SELECT * FROM refill_requests WHERE id = ?`,
        [requestId]
      );

      res.json({
        success: true,
        request_id: requestId,
        updated: true,
        fulfillment: mapFulfillment(row)
      });
    } catch (err) {
      console.error('request fulfillment update failed:', err);
      res.status(500).json({
        success: false,
        error: err.message
      });
    }
  });

  app.get('/api/v1/fulfillment/latest', async function(req, res) {
    try {
      const row = await get(`
        SELECT *
        FROM refill_requests
        ORDER BY id DESC
        LIMIT 1
      `);

      res.json({
        success: true,
        fulfillment: mapFulfillment(row)
      });
    } catch (err) {
      console.error('latest fulfillment failed:', err);
      res.status(500).json({
        success: false,
        error: err.message
      });
    }
  });
};
