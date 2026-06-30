'use strict';

const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'pharmacy.db');

function openDb() {
  return new sqlite3.Database(DB_PATH);
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

function firstValue(row, names, fallback = '') {
  for (const name of names) {
    if (row && row[name] !== undefined && row[name] !== null && String(row[name]).trim() !== '') {
      return row[name];
    }
  }
  return fallback;
}

function mapRxInsurance(row) {
  if (!row) return null;

  const medicationName = firstValue(row, [
    'requested_medication',
    'medication',
    'drug',
    'drug_name'
  ], '');

  const patientName = firstValue(row, [
    'customer_name',
    'patient_name',
    'caller_name',
    'name'
  ], '');

  return {
    id: row.id,

    prescription: {
      patient_name: patientName,
      medication_name: medicationName,
      strength: firstValue(row, ['medication_strength'], ''),
      directions: firstValue(row, ['directions_sig', 'sig', 'instructions'], ''),
      quantity: firstValue(row, ['quantity_display', 'quantity_requested', 'quantity'], ''),
      refills: firstValue(row, ['refills_display', 'refills_left', 'refills_remaining'], ''),
      prescriber: firstValue(row, ['prescriber_name', 'prescriber'], ''),
      pharmacy: firstValue(row, ['pharmacy_name'], ''),
      rx_number: firstValue(row, ['rx_number'], '')
    },

    insurance: {
      provider: firstValue(row, ['insurance_provider', 'insurance_plan'], ''),
      plan_type: firstValue(row, ['insurance_plan_type'], ''),
      member_id: firstValue(row, ['insurance_member_id', 'member_id'], ''),
      group_number: firstValue(row, ['insurance_group_number', 'insurance_group'], ''),
      bin: firstValue(row, ['insurance_bin'], ''),
      pcn: firstValue(row, ['insurance_pcn'], ''),
      copay: firstValue(row, ['insurance_copay', 'copay'], ''),
      status: firstValue(row, ['insurance_status'], 'not_checked'),
      prior_auth_required: firstValue(row, ['prior_auth_required'], 'unknown'),
      notes: firstValue(row, ['insurance_notes'], '')
    }
  };
}

module.exports = function registerRxInsuranceV1Routes(app) {
  app.get('/api/v1/rx-insurance/latest', async function (req, res) {
    try {
      const row = await get(`
        SELECT *
        FROM refill_requests
        ORDER BY id DESC
        LIMIT 1
      `);

      res.json({
        success: true,
        request: mapRxInsurance(row)
      });
    } catch (err) {
      console.error('rx-insurance latest failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.get('/api/v1/rx-insurance/:id', async function (req, res) {
    try {
      const id = Number(req.params.id);

      if (!id) {
        return res.status(400).json({ success: false, error: 'Missing request id' });
      }

      const row = await get(`
        SELECT *
        FROM refill_requests
        WHERE id = ?
      `, [id]);

      if (!row) {
        return res.status(404).json({ success: false, error: 'Request not found' });
      }

      res.json({
        success: true,
        request: mapRxInsurance(row)
      });
    } catch (err) {
      console.error('rx-insurance get failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });

  app.post('/api/v1/rx-insurance/:id', async function (req, res) {
    try {
      const id = Number(req.params.id);
      const body = req.body || {};

      if (!id) {
        return res.status(400).json({ success: false, error: 'Missing request id' });
      }

      await run(`
        UPDATE refill_requests
        SET
          rx_number = ?,
          medication_strength = ?,
          directions_sig = ?,
          quantity_display = ?,
          refills_display = ?,
          prescriber_name = ?,
          pharmacy_name = ?,
          insurance_provider = ?,
          insurance_plan_type = ?,
          insurance_member_id = ?,
          insurance_group_number = ?,
          insurance_bin = ?,
          insurance_pcn = ?,
          insurance_copay = ?,
          insurance_status = ?,
          prior_auth_required = ?,
          insurance_notes = ?
        WHERE id = ?
      `, [
        body.rx_number || '',
        body.medication_strength || '',
        body.directions_sig || '',
        body.quantity_display || '',
        body.refills_display || '',
        body.prescriber_name || '',
        body.pharmacy_name || '',
        body.insurance_provider || '',
        body.insurance_plan_type || '',
        body.insurance_member_id || '',
        body.insurance_group_number || '',
        body.insurance_bin || '',
        body.insurance_pcn || '',
        body.insurance_copay || '',
        body.insurance_status || 'not_checked',
        body.prior_auth_required || 'unknown',
        body.insurance_notes || '',
        id
      ]);

      const row = await get(`
        SELECT *
        FROM refill_requests
        WHERE id = ?
      `, [id]);

      res.json({
        success: true,
        request: mapRxInsurance(row)
      });
    } catch (err) {
      console.error('rx-insurance update failed:', err);
      res.status(500).json({ success: false, error: err.message });
    }
  });
};
