'use strict';

const axios = require('axios');

function safeString(value) {
  return String(value || '').trim();
}

function truncateJson(value) {
  try {
    const raw = JSON.stringify(value || {});
    return raw.length > 20000 ? raw.slice(0, 20000) : raw;
  } catch (err) {
    return '{}';
  }
}

function parseUsAddress(address) {
  const raw = safeString(address);
  const parts = raw.split(',').map(function (part) {
    return part.trim();
  }).filter(Boolean);

  const parsed = {
    street: raw,
    city: '',
    state: '',
    zipcode: ''
  };

  if (parts.length >= 3) {
    parsed.street = parts[0];
    parsed.city = parts[1];

    const last = parts.slice(2).join(' ');
    const match = last.match(/\b([A-Z]{2})\b\s*(\d{5}(?:-\d{4})?)?/i);

    if (match) {
      parsed.state = match[1].toUpperCase();
      parsed.zipcode = match[2] || '';
    }
  }

  return parsed;
}

function skipped(reason, address) {
  return {
    attempted: false,
    valid: false,
    provider: process.env.ADDRESS_VALIDATION_PROVIDER || 'disabled',
    status: reason,
    original_address: safeString(address),
    standardized_address: '',
    raw_json: {}
  };
}

async function validateWithSmarty(address) {
  const authId = safeString(process.env.SMARTY_AUTH_ID);
  const authToken = safeString(process.env.SMARTY_AUTH_TOKEN);

  if (!authId || !authToken) {
    return skipped('smarty_missing_credentials', address);
  }

  const parsed = parseUsAddress(address);

  const response = await axios.get('https://us-street.api.smarty.com/street-address', {
    timeout: 7000,
    params: {
      'auth-id': authId,
      'auth-token': authToken,
      street: parsed.street,
      city: parsed.city,
      state: parsed.state,
      zipcode: parsed.zipcode,
      candidates: 1,
      match: 'enhanced'
    }
  });

  const candidates = Array.isArray(response.data) ? response.data : [];
  const first = candidates[0];

  if (!first) {
    return {
      attempted: true,
      valid: false,
      provider: 'smarty',
      status: 'not_found',
      original_address: safeString(address),
      standardized_address: '',
      raw_json: response.data
    };
  }

  const analysis = first.analysis || {};
  const dpv = safeString(analysis.dpv_match_code).toUpperCase();

  const valid = ['Y', 'S', 'D'].includes(dpv);
  const standardizedAddress = [
    first.delivery_line_1,
    first.last_line
  ].filter(Boolean).join(', ');

  return {
    attempted: true,
    valid: valid,
    provider: 'smarty',
    status: valid ? 'validated' : 'needs_review',
    original_address: safeString(address),
    standardized_address: standardizedAddress,
    raw_json: response.data
  };
}

async function validateAddress(address) {
  const raw = safeString(address);

  if (!raw || raw.toUpperCase() === 'UNKNOWN') {
    return skipped('address_missing', address);
  }

  const provider = safeString(process.env.ADDRESS_VALIDATION_PROVIDER || 'disabled').toLowerCase();

  if (provider === 'disabled' || provider === 'none') {
    return skipped('disabled', address);
  }

  try {
    if (provider === 'smarty') {
      return await validateWithSmarty(raw);
    }

    return skipped('unknown_provider_' + provider, address);
  } catch (err) {
    return {
      attempted: true,
      valid: false,
      provider: provider,
      status: 'provider_error',
      original_address: raw,
      standardized_address: '',
      error: err.message,
      raw_json: err.response && err.response.data ? err.response.data : {}
    };
  }
}

module.exports = {
  validateAddress,
  truncateJson
};
