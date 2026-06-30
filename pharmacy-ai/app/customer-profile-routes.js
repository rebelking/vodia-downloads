'use strict';

const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'pharmacy.db');
const PHARMACY_SECRET =
  process.env.PHARMACY_SECRET ||
  process.env.PHARMACY_API_SECRET ||
  '';

function normalizePhone(phone) {
  const raw = String(phone || '').trim();
  if (!raw) return '';

  if (raw.startsWith('+')) {
    const digits = raw.replace(/\D/g, '');
    if (digits.length === 10) return '+1' + digits;
    if (digits.length === 11 && digits.startsWith('1')) return '+' + digits;
    return '+' + digits;
  }

  const digits = raw.replace(/\D/g, '');
  if (digits.length === 10) return '+1' + digits;
  if (digits.length === 11 && digits.startsWith('1')) return '+' + digits;

  return raw;
}

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

function cleanName(name) {
  return String(name || '').trim().replace(/\s+/g, ' ');
}

function lastNameFromName(name) {
  const parts = cleanName(name).split(' ').filter(Boolean);
  if (parts.length < 2) return '';
  return parts[parts.length - 1];
}

function buildGreeting(profile, language) {
  if (!profile) return '';

  const title = String(profile.preferred_title || '').trim();
  const last = String(profile.last_name || '').trim();
  const first = String(profile.first_name || '').trim();

  if (language === 'es') {
    if (title && last) return `Bienvenido de nuevo, ${title} ${last}.`;
    if (last) return `Bienvenido de nuevo, ${last}.`;
    if (first) return `Bienvenido de nuevo, ${first}.`;
    return 'Bienvenido de nuevo.';
  }

  if (title && last) return `Welcome back, ${title} ${last}.`;
  if (last) return `Welcome back, ${last}.`;
  if (first) return `Welcome back, ${first}.`;
  return 'Welcome back.';
}

function mapProfile(profile, language) {
  if (!profile) {
    return {
      known_customer: false,
      greeting: '',
      profile: null
    };
  }

  return {
    known_customer: true,
    greeting: buildGreeting(profile, language),
    profile: {
      id: profile.id,
      preferred_title: profile.preferred_title || '',
      first_name: profile.first_name || '',
      last_name: profile.last_name || '',
      full_name: profile.full_name || '',
      date_of_birth: profile.date_of_birth || '',
      callback_phone: profile.callback_phone || '',
      normalized_phone: profile.normalized_phone || '',
      address: profile.address || '',

      rx_number: profile.rx_number || '',
      prescriber_name: profile.prescriber_name || '',
      pharmacy_name: profile.pharmacy_name || '',

      insurance_provider: profile.insurance_provider || '',
      insurance_plan_type: profile.insurance_plan_type || '',
      insurance_member_id: profile.insurance_member_id || '',
      insurance_group_number: profile.insurance_group_number || '',
      insurance_bin: profile.insurance_bin || '',
      insurance_pcn: profile.insurance_pcn || '',
      insurance_copay: profile.insurance_copay || '',
      insurance_status: profile.insurance_status || '',
      prior_auth_required: profile.prior_auth_required || '',
      insurance_notes: profile.insurance_notes || ''
    }
  };
}

module.exports = function registerCustomerProfileRoutes(app) {
  app.post('/api/ai/customer-lookup', async function(req, res) {
    try {
      const providedSecret = req.get('X-Pharmacy-Secret') || '';

      if (providedSecret !== PHARMACY_SECRET) {
        return res.status(401).json({
          success: false,
          error: 'Unauthorized'
        });
      }

      const body = req.body || {};
      const language = String(body.language || 'en').toLowerCase() === 'es' ? 'es' : 'en';

      const normalizedPhone = normalizePhone(body.callback_phone || body.phone || body.caller_id || '');
      const customerName = cleanName(body.customer_name || body.name || '');
      const dateOfBirth = String(body.date_of_birth || '').trim();
      const lastName = lastNameFromName(customerName);

      let profile = null;

      if (normalizedPhone) {
        profile = await get(
          `SELECT * FROM customer_profiles WHERE normalized_phone = ? LIMIT 1`,
          [normalizedPhone]
        );
      }

      if (!profile && lastName && dateOfBirth) {
        profile = await get(
          `
          SELECT *
          FROM customer_profiles
          WHERE lower(last_name) = lower(?)
            AND date_of_birth = ?
          LIMIT 1
          `,
          [lastName, dateOfBirth]
        );
      }

      res.json({
        success: true,
        lookup: mapProfile(profile, language)
      });
    } catch (err) {
      console.error('customer lookup failed:', err);
      res.status(500).json({
        success: false,
        error: err.message
      });
    }
  });

  app.get('/api/v1/test/customer-profiles', async function(req, res) {
    try {
      const providedSecret = req.get('X-Pharmacy-Secret') || '';

      if (providedSecret !== PHARMACY_SECRET) {
        return res.status(401).json({
          success: false,
          error: 'Unauthorized'
        });
      }

      const rows = await all(`
        SELECT
          id,
          preferred_title,
          first_name,
          last_name,
          full_name,
          date_of_birth,
          callback_phone,
          normalized_phone,
          rx_number,
          prescriber_name,
          pharmacy_name,
          insurance_provider,
          insurance_member_id,
          insurance_status
        FROM customer_profiles
        ORDER BY id DESC
        LIMIT 50
      `);

      res.json({
        success: true,
        profiles: rows
      });
    } catch (err) {
      console.error('customer profiles list failed:', err);
      res.status(500).json({
        success: false,
        error: err.message
      });
    }
  });
};
