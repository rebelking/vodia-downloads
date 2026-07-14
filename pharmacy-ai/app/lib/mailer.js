'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

function settingsDirectory() {
  return process.env.PHARMACY_SETTINGS_DIR ||
    path.join(__dirname, '..', 'data');
}

function settingsFile() {
  return path.join(settingsDirectory(), 'admin-settings.json');
}

function getSecretKey() {
  const raw =
    process.env.PHARMACY_SETTINGS_KEY ||
    process.env.SETTINGS_ENCRYPTION_KEY ||
    process.env.PHARMACY_SECRET ||
    process.env.X_PHARMACY_SECRET ||
    process.env.SESSION_SECRET ||
    '';

  if (!raw) return null;

  return crypto
    .createHash('sha256')
    .update(String(raw))
    .digest();
}

function openSecret(value) {
  const raw = String(value || '');

  if (!raw) return '';

  if (raw.startsWith('plain:')) {
    return Buffer
      .from(raw.slice(6), 'base64')
      .toString('utf8');
  }

  if (!raw.startsWith('enc:')) return '';

  const key = getSecretKey();

  if (!key) return '';

  const parts = raw.split(':');

  if (parts.length !== 4) return '';

  try {
    const iv = Buffer.from(parts[1], 'base64');
    const tag = Buffer.from(parts[2], 'base64');
    const encrypted = Buffer.from(parts[3], 'base64');

    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      key,
      iv
    );

    decipher.setAuthTag(tag);

    return Buffer.concat([
      decipher.update(encrypted),
      decipher.final()
    ]).toString('utf8');
  } catch {
    return '';
  }
}

function readSavedSettings() {
  const file = settingsFile();

  try {
    if (!fs.existsSync(file)) {
      return {
        exists: false,
        settings: {}
      };
    }

    return {
      exists: true,
      settings: JSON.parse(fs.readFileSync(file, 'utf8'))
    };
  } catch (err) {
    return {
      exists: true,
      settings: {},
      error: err
    };
  }
}

function formatFrom(name, email) {
  const cleanEmail = String(email || '').trim();
  const cleanName = String(name || '')
    .replace(/"/g, '')
    .trim();

  if (!cleanName) return cleanEmail;

  return `"${cleanName}" <${cleanEmail}>`;
}

function savedSettingsConfig() {
  const result = readSavedSettings();

  if (!result.exists) return null;

  const smtp =
    result.settings &&
    result.settings.smtp &&
    typeof result.settings.smtp === 'object'
      ? result.settings.smtp
      : {};

  const host = String(smtp.host || '').trim();
  const username = String(smtp.username || '').trim();
  const fromEmail = String(smtp.fromEmail || '').trim();
  const passwordSecret = String(smtp.passwordSecret || '');
  const hasSavedFields =
    Boolean(host) ||
    Boolean(username) ||
    Boolean(fromEmail) ||
    Boolean(passwordSecret);

  if (!hasSavedFields) return null;

  if (smtp.enabled !== true) {
    return {
      configured: false,
      source: 'settings',
      reason: 'SMTP email is disabled in Settings.'
    };
  }

  if (!host) {
    return {
      configured: false,
      source: 'settings',
      reason: 'SMTP host is missing in Settings.'
    };
  }

  if (!fromEmail) {
    return {
      configured: false,
      source: 'settings',
      reason: 'SMTP From Email is missing in Settings.'
    };
  }

  const password = openSecret(passwordSecret);

  if (username && !password) {
    return {
      configured: false,
      source: 'settings',
      reason: 'SMTP password could not be loaded from Settings.'
    };
  }

  const transportOptions = {
    host,
    port: Number(smtp.port || 587),
    secure: Boolean(smtp.secure)
  };

  if (username) {
    transportOptions.auth = {
      user: username,
      pass: password
    };
  }

  return {
    configured: true,
    source: 'settings',
    transportOptions,
    from: formatFrom(
      smtp.fromName || 'Vodia Pharmacy AI',
      fromEmail
    )
  };
}

function environmentConfig() {
  const host = String(process.env.SMTP_HOST || '').trim();
  const username = String(process.env.SMTP_USER || '').trim();
  const password = String(process.env.SMTP_PASS || '');
  const fromEmail = String(
    process.env.EMAIL_FROM ||
    process.env.SMTP_FROM ||
    ''
  ).trim();

  if (!host || !fromEmail) {
    return {
      configured: false,
      source: 'environment',
      reason: 'SMTP settings are missing.'
    };
  }

  if (username && !password) {
    return {
      configured: false,
      source: 'environment',
      reason: 'SMTP password is missing.'
    };
  }

  const transportOptions = {
    host,
    port: Number(process.env.SMTP_PORT || 587),
    secure:
      String(process.env.SMTP_SECURE || 'false')
        .toLowerCase() === 'true'
  };

  if (username) {
    transportOptions.auth = {
      user: username,
      pass: password
    };
  }

  return {
    configured: true,
    source: 'environment',
    transportOptions,
    from: formatFrom(
      process.env.SMTP_FROM_NAME || 'Vodia Pharmacy AI',
      fromEmail
    )
  };
}

function getMailerConfig() {
  const saved = savedSettingsConfig();

  if (saved) return saved;

  return environmentConfig();
}

function createConfiguredMailer() {
  const config = getMailerConfig();

  if (!config.configured) {
    return config;
  }

  let nodemailer;

  try {
    nodemailer = require('nodemailer');
  } catch {
    return {
      configured: false,
      source: config.source,
      reason: 'Nodemailer is not installed.'
    };
  }

  return {
    ...config,
    transporter: nodemailer.createTransport(
      config.transportOptions
    )
  };
}

function getPortalLoginUrl() {
  const explicit = String(
    process.env.PORTAL_LOGIN_URL || ''
  ).trim();

  if (explicit) return explicit;

  const base = String(
    process.env.PUBLIC_BASE_URL ||
    process.env.PHARMACY_PUBLIC_BASE_URL ||
    ''
  )
    .trim()
    .replace(/\/+$/, '');

  if (base) return `${base}/portal/login`;

  return '/portal/login';
}

module.exports = {
  createConfiguredMailer,
  getMailerConfig,
  getPortalLoginUrl,
  openSecret
};
