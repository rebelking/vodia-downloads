'use strict';

const path = require('path');
const sqlite3 = require('sqlite3').verbose();

const dbPath = path.join(__dirname, 'pharmacy.db');
const db = new sqlite3.Database(dbPath);

const pharmacyApiSecret = process.env.PHARMACY_API_SECRET || '';

const ZIP_TO_CITY = {
  '01840': 'Lawrence',
  '01841': 'Lawrence',
  '01843': 'Lawrence',
  '01844': 'Methuen',
  '01803': 'Burlington'
};

const AREA_CODE_TO_CITIES = {
  '978': ['Lawrence', 'Methuen'],
  '351': ['Lawrence', 'Methuen'],
  '781': ['Burlington'],
  '339': ['Burlington']
};

function requireAiSecret(req, res, next) {
  const provided = req.get('X-Pharmacy-Secret') || '';

  if (provided !== pharmacyApiSecret) {
    return res.status(401).json({
      success: false,
      error: 'unauthorized'
    });
  }

  next();
}

function normalizeChain(value) {
  const raw = String(value || '').toLowerCase().trim();

  if (!raw || raw === 'any' || raw === 'either' || raw === 'no preference') {
    return '';
  }

  if (raw.includes('cvs')) return 'CVS';
  if (raw.includes('walgreen')) return 'Walgreens';
  if (raw.includes('walgreens')) return 'Walgreens';

  return '';
}

function normalizeCity(value) {
  const raw = String(value || '').trim().toLowerCase();

  if (!raw) return '';

  if (raw.includes('lawrence')) return 'Lawrence';
  if (raw.includes('methuen')) return 'Methuen';
  if (raw.includes('burlington')) return 'Burlington';

  return raw.replace(/\b\w/g, function(ch) {
    return ch.toUpperCase();
  });
}

function normalizeState(value) {
  const raw = String(value || 'MA').trim().toUpperCase();
  return raw || 'MA';
}

function extractZip(value) {
  const match = String(value || '').match(/\b(\d{5})\b/);
  return match ? match[1] : '';
}

function extractAreaCode(value) {
  const digits = String(value || '').replace(/\D/g, '');

  if (digits.length === 10) {
    return digits.slice(0, 3);
  }

  if (digits.length === 11 && digits.charAt(0) === '1') {
    return digits.slice(1, 4);
  }

  return '';
}

function all(sql, params) {
  return new Promise((resolve, reject) => {
    db.all(sql, params || [], function(err, rows) {
      if (err) return reject(err);
      resolve(rows || []);
    });
  });
}

function rowToOption(row, optionNumber) {
  const fullAddress = `${row.address1}, ${row.city}, ${row.state} ${row.zip}`;

  return {
    option_number: optionNumber,
    store_key: row.store_key,
    chain: row.chain,
    name: row.name,
    store_number: row.store_number || '',
    display_name: `${row.chain} - ${row.name}`,
    address: fullAddress,
    address1: row.address1,
    city: row.city,
    state: row.state,
    zip: row.zip,
    phone: row.phone || '',
    service_city: row.service_city || row.city,
    service_zip: row.service_zip || row.zip,
    source: row.source || 'static_database',
    source_url: row.source_url || '',
    notes: row.notes || ''
  };
}

function scoreLocation(row, search) {
  let score = 0;

  const chain = String(row.chain || '').toLowerCase();
  const city = String(row.city || '').toLowerCase();
  const serviceCity = String(row.service_city || '').toLowerCase();
  const zip = String(row.zip || '');
  const serviceZip = String(row.service_zip || '');

  if (search.chain && chain === search.chain.toLowerCase()) score += 100;
  if (search.zip && zip === search.zip) score += 80;
  if (search.zip && serviceZip === search.zip) score += 70;

  if (search.city) {
    const wantedCity = search.city.toLowerCase();

    if (city === wantedCity) score += 60;
    if (serviceCity === wantedCity) score += 55;
  }

  if (search.candidateCities.length) {
    const cityMatch = search.candidateCities.some(function(candidate) {
      const c = candidate.toLowerCase();
      return city === c || serviceCity === c;
    });

    if (cityMatch) score += 40;
  }

  if (String(row.state || '').toUpperCase() === search.state) score += 10;

  return score;
}

async function searchLocations(input) {
  const chain = normalizeChain(
    input.chain ||
    input.chain_preference ||
    input.preferred_chain ||
    input.pharmacy_chain
  );

  let zip = extractZip(input.zip || input.postal_code || input.address || '');
  let city = normalizeCity(input.city || '');
  const state = normalizeState(input.state || 'MA');

  if (!city && zip && ZIP_TO_CITY[zip]) {
    city = ZIP_TO_CITY[zip];
  }

  const areaCode = extractAreaCode(input.callback_phone || input.caller_phone || input.phone || '');
  const candidateCities = [];

  if (!city && !zip && areaCode && AREA_CODE_TO_CITIES[areaCode]) {
    AREA_CODE_TO_CITIES[areaCode].forEach(function(candidate) {
      candidateCities.push(candidate);
    });
  }

  const rows = await all(`
    SELECT
      id,
      store_key,
      chain,
      name,
      store_number,
      address1,
      city,
      state,
      zip,
      phone,
      service_city,
      service_zip,
      source,
      source_url,
      notes,
      active
    FROM pharmacy_pickup_locations
    WHERE active = 1
  `);

  let filtered = rows.filter(function(row) {
    if (chain && row.chain !== chain) return false;
    if (state && String(row.state || '').toUpperCase() !== state) return false;

    return true;
  });

  const search = {
    chain,
    zip,
    city,
    state,
    areaCode,
    candidateCities
  };

  filtered = filtered
    .map(function(row) {
      return {
        row: row,
        score: scoreLocation(row, search)
      };
    })
    .filter(function(item) {
      if (!zip && !city && !candidateCities.length) {
        return true;
      }

      return item.score > 0;
    })
    .sort(function(a, b) {
      if (b.score !== a.score) return b.score - a.score;

      const ac = `${a.row.service_city || a.row.city} ${a.row.chain} ${a.row.address1}`;
      const bc = `${b.row.service_city || b.row.city} ${b.row.chain} ${b.row.address1}`;
      return ac.localeCompare(bc);
    })
    .slice(0, Number(input.limit || 6))
    .map(function(item, index) {
      return rowToOption(item.row, index + 1);
    });

  return {
    success: true,
    search: {
      chain: chain || 'any',
      zip: zip || '',
      city: city || '',
      state: state,
      area_code: areaCode || '',
      fallback_used: !zip && !city && candidateCities.length > 0,
      candidate_cities: candidateCities
    },
    options: filtered
  };
}

async function handleSearch(req, res) {
  try {
    const input = req.method === 'GET' ? req.query : req.body;
    const result = await searchLocations(input || {});

    res.json(result);
  } catch (err) {
    console.error('pharmacy-location-search failed:', err);

    res.status(500).json({
      success: false,
      error: 'pharmacy_location_search_failed',
      message: err.message
    });
  }
}

module.exports = function registerPharmacyLocationRoutes(app) {
  app.get('/api/ai/pharmacy-location-search', requireAiSecret, handleSearch);
  app.post('/api/ai/pharmacy-location-search', requireAiSecret, handleSearch);

  app.get('/api/v1/pharmacy-pickup-locations', async function(req, res) {
    try {
      const rows = await all(`
        SELECT *
        FROM pharmacy_pickup_locations
        WHERE active = 1
        ORDER BY service_city, chain, city, address1
      `);

      res.json({
        success: true,
        count: rows.length,
        locations: rows.map(function(row, index) {
          return rowToOption(row, index + 1);
        })
      });
    } catch (err) {
      res.status(500).json({
        success: false,
        error: 'pickup_locations_failed',
        message: err.message
      });
    }
  });

  console.log('Pharmacy location routes loaded.');
};
