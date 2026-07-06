'use strict';

const { validateAddress, truncateJson } = require('./address-validation');


require('dotenv').config();

const express = require('express');
const cors = require('cors');
const sqlite3 = require('sqlite3').verbose();
const nodemailer = require('nodemailer');
const session = require('express-session');
const { installPortalRoutes } = require('./portal');
const { installVoiceAgentPortalRoutes } = require('./voice-agent-portal-routes');
const { installChatUnreadRoutes } = require('./chat-unread');
const { installChatRoutes } = require('./chat');
const { installOrderEditRoutes } = require('./order-edit');
const { auditPostMiddleware, installPortalExtraRoutes } = require('./portal-extra');
const { installAdminMedicationRoutes } = require('./admin-medications');
const { installAdminPatientRoutes } = require('./admin-patients');

const app = express();
app.use(express.json({ limit: '10mb' }));
require('./fulfillment-routes')(app);
require('./customer-profile-routes')(app);
require('./rx-insurance-v1-routes')(app);
require('./admin-portal-v2-routes')(app);


const PORT = process.env.PORT || 3001;
const PROJECT_NAME = process.env.PROJECT_NAME || 'vodia-pharmacy-ai';
const DB_PATH = process.env.DB_PATH || './pharmacy.db';

app.set('trust proxy', 1);

app.use(cors());
app.use(express.json({ limit: '5mb' }));
app.use(express.urlencoded({ extended: true, limit: '5mb' }));
app.use('/assets', express.static('public'));
app.use(session({
  name: 'vodia_pharmacy_portal_sid',
  secret: process.env.PORTAL_SESSION_SECRET || 'change-this-session-secret',
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    sameSite: 'lax',
    secure: false
  }
}));

function requirePharmacySecret(req, res, next) {
  const configuredSecret = process.env.PHARMACY_API_SECRET;
  const providedSecret = req.get('X-Pharmacy-Secret');

  if (!configuredSecret) {
    return res.status(500).json({
      success: false,
      error: 'PHARMACY_API_SECRET is not configured'
    });
  }

  if (!providedSecret || providedSecret !== configuredSecret) {
    return res.status(401).json({
      success: false,
      error: 'Unauthorized'
    });
  }

  next();
}

function openDb() {
  return new sqlite3.Database(DB_PATH);
}

function createEmailTransporter() {
  return nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: String(process.env.SMTP_SECURE || 'false') === 'true',
    auth: {
      user: process.env.SMTP_USER,
      pass: process.env.SMTP_PASS
    }
  });
}

async function sendRefillNotificationEmail(data) {
  const notifyTo = process.env.ORDER_NOTIFY_EMAIL || process.env.EMAIL_TO;
  const emailFrom = process.env.EMAIL_FROM;
  const portalUrl = process.env.PORTAL_URL || 'https://pharmacy.audiomercy.com/portal/orders';

  if (!process.env.SMTP_HOST || !process.env.SMTP_USER || !process.env.SMTP_PASS) {
    console.log('Email notification skipped: SMTP settings are missing.');
    return;
  }

  if (!notifyTo || !emailFrom) {
    console.log('Email notification skipped: EMAIL_FROM or ORDER_NOTIFY_EMAIL/EMAIL_TO missing.');
    return;
  }

  const transporter = createEmailTransporter();

  const subject = `New Pharmacy Refill Request #${data.refill_request_id}`;

  const text = `
New Pharmacy Refill Request

Request ID: ${data.refill_request_id}
Patient: ${data.patient_name}
Callback Phone: ${data.phone || 'Not provided'}
Medication: ${data.medication}
Status: ${data.status}
Availability: ${data.available ? 'Available' : 'Out of stock or needs review'}

Portal:
${portalUrl}

Please review this request and call the customer back if needed.
`;

  const html = `
    <h2>New Pharmacy Refill Request</h2>
    <p><strong>Request ID:</strong> ${data.refill_request_id}</p>
    <p><strong>Patient:</strong> ${escapeHtml(data.patient_name)}</p>
    <p><strong>Callback Phone:</strong> ${escapeHtml(data.phone || 'Not provided')}</p>
    <p><strong>Medication:</strong> ${escapeHtml(data.medication)}</p>
    <p><strong>Status:</strong> ${escapeHtml(data.status)}</p>
    <p><strong>Availability:</strong> ${data.available ? 'Available' : 'Out of stock or needs review'}</p>
    <p><a href="${escapeHtml(portalUrl)}">Open Pharmacy Portal</a></p>
    <p>Please review this request and call the customer back if needed.</p>
  `;

  const info = await transporter.sendMail({
    from: emailFrom,
    to: notifyTo,
    subject: subject,
    text: text,
    html: html
  });

  console.log('Refill notification email sent:', {
    accepted: info.accepted,
    rejected: info.rejected,
    messageId: info.messageId
  });
}

function queueRefillNotificationEmail(data) {
  sendRefillNotificationEmail(data).catch(function (emailErr) {
    console.error('Refill notification email failed:', emailErr.message);
  });
}

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

app.get('/', function (req, res) {
  res.json({
    success: true,
    project: PROJECT_NAME,
    message: 'Vodia Pharmacy AI server is running',
    port: PORT
  });
});

app.get('/health', function (req, res) {
  res.json({
    success: true,
    status: 'healthy',
    project: PROJECT_NAME,
    database: DB_PATH,
    timestamp: new Date().toISOString()
  });
});

app.post('/api/patient/lookup', function (req, res) {
  const dateOfBirth = String(req.body.date_of_birth || '').trim();
  const address = String(req.body.address || '').trim();

  if (!dateOfBirth || !address) {
    return res.status(400).json({
      success: false,
      error: 'date_of_birth and address are required'
    });
  }

  const db = openDb();

  db.get(
    `
      SELECT id, first_name, last_name, date_of_birth, address, phone
      FROM patients
      WHERE date_of_birth = ?
      AND lower(address) = lower(?)
      LIMIT 1
    `,
    [dateOfBirth, address],
    function (err, patient) {
      db.close();

      if (err) {
        console.error('Patient lookup error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error'
        });
      }

      if (!patient) {
        return res.status(404).json({
          success: false,
          found: false,
          message: 'Patient not found'
        });
      }

      return res.json({
        success: true,
        found: true,
        patient: patient
      });
    }
  );
});

app.post('/api/medication/check', function (req, res) {
  const medication = String(req.body.medication || '').trim().toLowerCase();

  if (!medication) {
    return res.status(400).json({
      success: false,
      error: 'medication is required'
    });
  }

  const db = openDb();

  db.get(
    `
      SELECT id, generic_name, brand_name, common_names, available, quantity_on_hand, notes
      FROM medications
      WHERE lower(generic_name) = lower(?)
      OR lower(brand_name) = lower(?)
      OR lower(ifnull(common_names, '')) LIKE lower(?)
      LIMIT 1
    `,
    [medication, medication, '%' + medication + '%'],
    function (err, med) {
      db.close();

      if (err) {
        console.error('Medication check error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error'
        });
      }

      if (!med) {
        return res.status(404).json({
          success: false,
          found: false,
          message: 'Medication not found in database'
        });
      }

      return res.json({
        success: true,
        found: true,
        medication: {
          id: med.id,
          generic_name: med.generic_name,
          brand_name: med.brand_name,
          available: med.available === 1,
          quantity_on_hand: med.quantity_on_hand,
          notes: med.notes
        }
      });
    }
  );
});

app.post('/webhook/pharmacy-order', function (req, res) {
  const callerName = String(req.body.caller_name || '').trim();
  const dateOfBirth = String(req.body.date_of_birth || '').trim();
  const address = String(req.body.address || '').trim();
  const requestType = String(req.body.request_type || 'refill').trim();
  const requestedMedication = String(req.body.medication || '').trim();

  if (!dateOfBirth || !address || !requestedMedication) {
    return res.status(400).json({
      success: false,
      error: 'date_of_birth, address, and medication are required'
    });
  }

  const db = openDb();

  db.get(
    `
      SELECT id, first_name, last_name, phone
      FROM patients
      WHERE date_of_birth = ?
      AND lower(address) = lower(?)
      LIMIT 1
    `,
    [dateOfBirth, address],
    function (patientErr, patient) {
      if (patientErr) {
        db.close();
        console.error('Patient lookup error:', patientErr.message);
        return res.status(500).json({
          success: false,
          error: 'Database error during patient lookup'
        });
      }

      if (!patient) {
        db.close();
        return res.status(404).json({
          success: false,
          step: 'patient_lookup',
          patient_found: false,
          message: 'Patient not found. Transfer caller to pharmacy staff.',
          ai_response: 'I was not able to verify your account with the information provided. I will transfer you to the pharmacy staff for help.'
        });
      }

      db.get(
        `
          SELECT id, generic_name, brand_name, common_names, available, quantity_on_hand
          FROM medications
          WHERE lower(generic_name) = lower(?)
          OR lower(brand_name) = lower(?)
          OR lower(ifnull(common_names, '')) LIKE lower(?)
          LIMIT 1
        `,
        [requestedMedication, requestedMedication, '%' + requestedMedication + '%'],
        function (medErr, med) {
          if (medErr) {
            db.close();
            console.error('Medication lookup error:', medErr.message);
            return res.status(500).json({
              success: false,
              error: 'Database error during medication lookup'
            });
          }

          if (!med) {
            db.close();
            return res.status(404).json({
              success: false,
              step: 'medication_lookup',
              patient_found: true,
              medication_found: false,
              message: 'Medication not found. Transfer caller to pharmacy staff.',
              ai_response: 'I found your account, but I could not verify that medication. I will transfer you to the pharmacy staff for help.'
            });
          }

          const available = med.available === 1 && Number(med.quantity_on_hand || 0) > 0;
          const requestStatus = available ? 'pending' : 'out_of_stock';

          db.run(
            `
              INSERT INTO refill_requests
              (patient_id, medication_id, requested_medication, status, notes,
              pickup_requested,
              pickup_store_id,
              pickup_store_code,
              pickup_store_name,
              pickup_store_address)
              VALUES (?, ?, ?, ?, ?,
              ?,
              ?,
              ?,
              ?,
              ?)
            `,
            [
              patient.id,
              med.id,
              requestedMedication,
              requestStatus,
              available
                ? 'Medication found and appears available.'
                : 'Medication found but currently out of stock.'
            ,
            pickupRequested ? 1 : 0,
            Number.isFinite(pickupStoreId) ? pickupStoreId : null,
            pickupStoreCode || null,
            pickupStoreName || null,
            pickupStoreAddress || null],
            function (insertErr) {
              db.close();

              if (insertErr) {
                console.error('Refill insert error:', insertErr.message);
                return res.status(500).json({
                  success: false,
                  error: 'Database error during refill request creation'
                });
              }

              const refillRequestId = this.lastID;

              queueRefillNotificationEmail({
                refill_request_id: refillRequestId,
                patient_name: patient.first_name + ' ' + patient.last_name,
                phone: patient.phone,
                medication: requestedMedication,
                status: requestStatus,
                available: available
              });

              return res.json({
                success: true,
                message: 'Refill request created',
                refill_request_id: refillRequestId,
                email_notification_queued: true,
                caller: {
                  caller_name: callerName || null,
                  request_type: requestType
                },
                patient: {
                  id: patient.id,
                  name: patient.first_name + ' ' + patient.last_name
                },
                medication: {
                  id: med.id,
                  generic_name: med.generic_name,
                  brand_name: med.brand_name,
                  available: available,
                  quantity_on_hand: med.quantity_on_hand
                },
                next_action: available
                  ? 'Tell caller the refill request has been received and pharmacy staff will review it.'
                  : 'Tell caller the medication may be out of stock and pharmacy staff will follow up.',
                ai_response: available
                  ? 'Thank you. I found your account and received your refill request. Pharmacy staff will review it and follow up if needed.'
                  : 'Thank you. I found your account, but this medication may currently be out of stock. Pharmacy staff will review it and follow up with you.'
              });
            }
          );
        }
      );
    }
  );
});

app.post('/api/patients', function (req, res) {
  const firstName = String(req.body.first_name || '').trim();
  const lastName = String(req.body.last_name || '').trim();
  const dateOfBirth = String(req.body.date_of_birth || '').trim();
  const address = String(req.body.address || '').trim();
  const phone = String(req.body.phone || '').trim();

  if (!firstName || !lastName || !dateOfBirth || !address) {
    return res.status(400).json({
      success: false,
      error: 'first_name, last_name, date_of_birth, and address are required'
    });
  }

  const db = openDb();

  db.run(
    `
      INSERT INTO patients
      (first_name, last_name, date_of_birth, address, phone)
      VALUES (?, ?, ?, ?, ?)
    `,
    [firstName, lastName, dateOfBirth, address, phone],
    function (err) {
      db.close();

      if (err) {
        console.error('Create patient error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error creating patient'
        });
      }

      return res.json({
        success: true,
        message: 'Patient created',
        patient_id: this.lastID
      });
    }
  );
});

app.get('/api/patients', function (req, res) {
  const db = openDb();

  db.all(
    `
      SELECT id, first_name, last_name, date_of_birth, address, phone, created_at
      FROM patients
      ORDER BY created_at DESC
    `,
    [],
    function (err, rows) {
      db.close();

      if (err) {
        console.error('List patients error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error listing patients'
        });
      }

      return res.json({
        success: true,
        count: rows.length,
        patients: rows
      });
    }
  );
});

app.post('/api/medications', function (req, res) {
  const genericName = String(req.body.generic_name || '').trim().toLowerCase();
  const brandName = String(req.body.brand_name || '').trim();
  const available = req.body.available === false ? 0 : 1;
  const quantityOnHand = Number(req.body.quantity_on_hand || 0);
  const notes = String(req.body.notes || '').trim();

  if (!genericName) {
    return res.status(400).json({
      success: false,
      error: 'generic_name is required'
    });
  }

  const db = openDb();

  db.run(
    `
      INSERT INTO medications
      (generic_name, brand_name, available, quantity_on_hand, notes)
      VALUES (?, ?, ?, ?, ?)
    `,
    [genericName, brandName, available, quantityOnHand, notes],
    function (err) {
      db.close();

      if (err) {
        console.error('Create medication error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error creating medication'
        });
      }

      return res.json({
        success: true,
        message: 'Medication created',
        medication_id: this.lastID
      });
    }
  );
});

app.get('/api/medications', function (req, res) {
  const db = openDb();

  db.all(
    `
      SELECT id, generic_name, brand_name, available, quantity_on_hand, notes, created_at
      FROM medications
      ORDER BY generic_name ASC
    `,
    [],
    function (err, rows) {
      db.close();

      if (err) {
        console.error('List medications error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error listing medications'
        });
      }

      return res.json({
        success: true,
        count: rows.length,
        medications: rows.map(function (med) {
          return {
            id: med.id,
            generic_name: med.generic_name,
            brand_name: med.brand_name,
            available: med.available === 1,
            quantity_on_hand: med.quantity_on_hand,
            notes: med.notes,
            created_at: med.created_at
          };
        })
      });
    }
  );
});

app.patch('/api/medications/:id/stock', function (req, res) {
  const medicationId = req.params.id;
  const available = req.body.available === false ? 0 : 1;
  const quantityOnHand = Number(req.body.quantity_on_hand || 0);
  const notes = String(req.body.notes || '').trim();

  const db = openDb();

  db.run(
    `
      UPDATE medications
      SET available = ?, quantity_on_hand = ?, notes = ?
      WHERE id = ?
    `,
    [available, quantityOnHand, notes, medicationId],
    function (err) {
      db.close();

      if (err) {
        console.error('Update medication stock error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error updating medication stock'
        });
      }

      if (this.changes === 0) {
        return res.status(404).json({
          success: false,
          error: 'Medication not found'
        });
      }

      return res.json({
        success: true,
        message: 'Medication stock updated',
        medication_id: medicationId
      });
    }
  );
});

app.post('/api/ai/refill-intake', requirePharmacySecret, async function (req, res) {
  const allowedRequestTypes = ['refill', 'medication_order', 'stock_question'];

  let requestType = String(req.body.request_type || 'medication_order').trim();

  if (!allowedRequestTypes.includes(requestType)) {
    requestType = 'medication_order';
  }

  const customerName = String(req.body.customer_name || req.body.caller_name || 'Unknown Caller').trim() || 'Unknown Caller';
  const callbackPhone = normalizePhoneE164Local(req.body.callback_phone || req.body.phone || req.body.caller || req.body.caller_id || '') || 'UNKNOWN';
  const dateOfBirth = String(req.body.date_of_birth || 'UNKNOWN').trim() || 'UNKNOWN';
  const originalAddress = String(req.body.address || 'UNKNOWN').trim() || 'UNKNOWN';
  const requestedMedication = String(req.body.medication || req.body.requested_medication || '').trim();
  const quantityRequestedRaw = Number(req.body.quantity_requested || 1);
  const quantityRequested = quantityRequestedRaw > 0 ? Math.floor(quantityRequestedRaw) : 1;
  const customerQuestion = String(req.body.customer_question || '').trim();
  const aiNotes = String(req.body.notes || '').trim();

    const pickupRequestedRaw = req.body.pickup_requested ?? req.body.pickupRequested ?? req.body.pickup ?? false;
    const pickupRequested = pickupRequestedRaw === true ||
      pickupRequestedRaw === 1 ||
      pickupRequestedRaw === '1' ||
      String(pickupRequestedRaw || '').toLowerCase() === 'true' ||
      String(pickupRequestedRaw || '').toLowerCase() === 'yes';

    const pickupStoreIdRaw = req.body.pickup_store_id ??
      req.body.pickupStoreId ??
      req.body.selected_pharmacy_location_id ??
      req.body.selectedPharmacyLocationId ??
      req.body.pharmacy_location_id ??
      null;

    const pickupStoreId = pickupStoreIdRaw === null || pickupStoreIdRaw === undefined || pickupStoreIdRaw === ''
      ? null
      : Number(pickupStoreIdRaw);

    const pickupStoreCode = String(
      req.body.pickup_store_code ??
      req.body.pickupStoreCode ??
      req.body.selected_pharmacy_code ??
      req.body.selectedPharmacyCode ??
      ''
    ).trim();

    const pickupStoreName = String(
      req.body.pickup_store_name ??
      req.body.pickupStoreName ??
      req.body.selected_pharmacy_name ??
      req.body.selectedPharmacyName ??
      req.body.pharmacy_name ??
      ''
    ).trim();

    const pickupStoreAddress = String(
      req.body.pickup_store_address ??
      req.body.pickupStoreAddress ??
      req.body.selected_pharmacy_address ??
      req.body.selectedPharmacyAddress ??
      ''
    ).trim();

  if (!requestedMedication) {
    return res.status(400).json({
      success: false,
      transfer_to_staff: false,
      reason: 'missing_minimum_required_fields',
      required_fields: ['medication'],
      ai_say: 'I need the medication name so I can enter the request for pharmacy staff.'
    });
  }

  const addressValidation = await validateAddress(originalAddress);
  const addressForDb = addressValidation.valid && addressValidation.standardized_address
    ? addressValidation.standardized_address
    : originalAddress;

  const db = openDb();

  function normalizePhoneE164Local(phone) {
    const raw = String(phone || '').trim();

    if (!raw || raw.toUpperCase() === 'UNKNOWN') return 'UNKNOWN';

    if (raw.startsWith('+')) {
      const digits = raw.replace(/\D/g, '');
      const e164 = '+' + digits;

      if (/^\+\d{8,15}$/.test(e164)) {
        return e164;
      }

      return raw;
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

    return raw;
  }

  function splitName(fullName) {
    const parts = String(fullName || '').trim().split(/\s+/).filter(Boolean);

    if (parts.length === 0) {
      return {
        firstName: 'Unknown',
        lastName: 'Caller'
      };
    }

    if (parts.length === 1) {
      return {
        firstName: parts[0],
        lastName: 'Caller'
      };
    }

    return {
      firstName: parts.slice(0, -1).join(' '),
      lastName: parts[parts.length - 1]
    };
  }

  function safeCloseDb() {
    try {
      db.close();
    } catch (closeErr) {}
  }

  function fail(reason, message, err) {
    if (err) {
      console.error(reason + ':', err.message);
    }

    safeCloseDb();

    return res.status(500).json({
      success: false,
      transfer_to_staff: true,
      reason: reason,
      ai_say: message || 'I am having trouble entering your request right now. I will transfer you to pharmacy staff for help.'
    });
  }

  function findOrCreatePatient(callback) {
    const nameParts = splitName(customerName);
    const fallbackDob = dateOfBirth || 'UNKNOWN';
    const fallbackAddress = addressForDb || originalAddress || 'UNKNOWN';

    function createPatient() {
      db.run(
        `
          INSERT INTO patients
          (first_name, last_name, date_of_birth, address, phone)
          VALUES (?, ?, ?, ?, ?)
        `,
        [nameParts.firstName, nameParts.lastName, fallbackDob, fallbackAddress, callbackPhone],
        function (insertErr) {
          if (insertErr) {
            return callback(insertErr);
          }

          return callback(null, {
            id: this.lastID,
            first_name: nameParts.firstName,
            last_name: nameParts.lastName,
            phone: callbackPhone
          }, false);
        }
      );
    }

    if (dateOfBirth !== 'UNKNOWN' && fallbackAddress !== 'UNKNOWN') {
      return db.get(
        `
          SELECT id, first_name, last_name, phone
          FROM patients
          WHERE date_of_birth = ?
          AND lower(address) = lower(?)
          LIMIT 1
        `,
        [dateOfBirth, fallbackAddress],
        function (patientErr, patient) {
          if (patientErr) {
            return callback(patientErr);
          }

          if (patient) {
            return db.run(
              `
                UPDATE patients
                SET first_name = ?,
                    last_name = ?,
                    phone = COALESCE(NULLIF(?, ''), phone),
                    address = ?
                WHERE id = ?
              `,
              [nameParts.firstName, nameParts.lastName, callbackPhone, fallbackAddress, patient.id],
              function (updateErr) {
                if (updateErr) return callback(updateErr);

                patient.first_name = nameParts.firstName;
                patient.last_name = nameParts.lastName;
                patient.phone = callbackPhone || patient.phone;

                return callback(null, patient, true);
              }
            );
          }

          return createPatient();
        }
      );
    }

    return db.get(
      `
        SELECT id, first_name, last_name, phone
        FROM patients
        WHERE phone = ?
        LIMIT 1
      `,
      [callbackPhone],
      function (phoneErr, patient) {
        if (phoneErr) {
          return callback(phoneErr);
        }

        if (patient) {
          return callback(null, patient, true);
        }

        return createPatient();
      }
    );
  }

  function findMedication(callback) {
    db.get(
      `
        SELECT id, generic_name, brand_name, common_names, available, quantity_on_hand
        FROM medications
        WHERE lower(generic_name) = lower(?)
        OR lower(brand_name) = lower(?)
        OR lower(ifnull(common_names, '')) LIKE lower(?)
        LIMIT 1
      `,
      [requestedMedication, requestedMedication, '%' + requestedMedication + '%'],
      function (medErr, med) {
        if (medErr && String(medErr.message || '').includes('no such column: common_names')) {
          return db.get(
            `
              SELECT id, generic_name, brand_name, available, quantity_on_hand
              FROM medications
              WHERE lower(generic_name) = lower(?)
              OR lower(brand_name) = lower(?)
              LIMIT 1
            `,
            [requestedMedication, requestedMedication],
            callback
          );
        }

        return callback(medErr, med);
      }
    );
  }

  findOrCreatePatient(function (patientErr, patient, patientVerified) {
    if (patientErr) {
      return fail(
        'database_error_patient_lookup',
        'I am having trouble entering your information right now. I will transfer you to pharmacy staff for help.',
        patientErr
      );
    }

    findMedication(function (medErr, med) {
      if (medErr) {
        return fail(
          'database_error_medication_lookup',
          'I entered your information, but I am having trouble checking the medication. I will transfer you to pharmacy staff for help.',
          medErr
        );
      }

      const medicationFound = !!med;
      const stockSnapshot = medicationFound ? Number(med.quantity_on_hand || 0) : null;
      const isMarkedAvailable = medicationFound ? med.available === 1 : false;
      const enoughStock = medicationFound && isMarkedAvailable && stockSnapshot >= quantityRequested;
      const hasSomeStock = medicationFound && isMarkedAvailable && stockSnapshot > 0;

      let stockStatus = 'medication_not_found_request_created';
      let requestStatus = 'needs_follow_up';

      if (medicationFound && enoughStock) {
        stockStatus = 'available_for_staff_review';
        requestStatus = 'pending';
      } else if (medicationFound && hasSomeStock) {
        stockStatus = 'low_stock_for_staff_review';
        requestStatus = 'needs_follow_up';
      } else if (medicationFound) {
        stockStatus = 'out_of_stock_request_created';
        requestStatus = 'out_of_stock';
      }

      if (!addressValidation.valid) {
        requestStatus = 'needs_follow_up';
      }

      const staffNoteParts = [
        'AI intake created request with address validation.',
        'Request type: ' + requestType + '.',
        'Customer name: ' + customerName + '.',
        'Callback phone: ' + callbackPhone + '.',
        'DOB: ' + dateOfBirth + '.',
        'Original address: ' + originalAddress + '.',
        'Validated address: ' + (addressValidation.standardized_address || '') + '.',
        'Address validation status: ' + addressValidation.status + '.',
        'Address validation provider: ' + addressValidation.provider + '.',
        'Medication requested: ' + requestedMedication + '.',
        'Quantity requested: ' + quantityRequested + '.',
        'Medication found in inventory: ' + (medicationFound ? 'yes' : 'no') + '.',
        'Stock status: ' + stockStatus + '.'
      ];

      if (!medicationFound) {
        staffNoteParts.push('Medication was not found in inventory. Staff should check alternatives or special order options if appropriate.');
      }

      if (!addressValidation.valid) {
        staffNoteParts.push('Address was not fully validated. Staff should review the address.');
      }

      if (customerQuestion) {
        staffNoteParts.push('Customer question: ' + customerQuestion);
      }

      if (aiNotes) {
        staffNoteParts.push('AI notes: ' + aiNotes);
      }

      const finalNotes = staffNoteParts.join('\n');

      const payloadJson = JSON.stringify({
        request_type: requestType,
        customer_name: customerName,
        callback_phone: callbackPhone,
        date_of_birth: dateOfBirth,
        original_address: originalAddress,
        address: addressForDb,
        medication: requestedMedication,
        quantity_requested: quantityRequested,
        customer_question: customerQuestion,
        notes: aiNotes,
          pickup_requested: pickupRequested,
          pickup_store_id: Number.isFinite(pickupStoreId) ? pickupStoreId : null,
          pickup_store_code: pickupStoreCode || null,
          pickup_store_name: pickupStoreName || null,
          pickup_store_address: pickupStoreAddress || null,
        address_validation: {
          provider: addressValidation.provider,
          status: addressValidation.status,
          valid: addressValidation.valid,
          standardized_address: addressValidation.standardized_address || ''
        }
      });

      db.run(
          `
            INSERT INTO refill_requests
            (
              patient_id,
              medication_id,
              requested_medication,
              status,
              notes,
              request_type,
              customer_name,
              callback_phone,
              quantity_requested,
              customer_question,
              stock_status,
              stock_snapshot,
              ai_payload_json,
              validated_address,
              address_valid,
              address_validation_provider,
              address_validation_status,
              address_validation_json,
              pickup_requested,
              pickup_store_id,
              pickup_store_code,
              pickup_store_name,
              pickup_store_address
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          `,
          [
            patient.id,
            medicationFound ? med.id : null,
            requestedMedication,
            requestStatus,
            finalNotes,
            requestType,
            customerName,
            callbackPhone,
            quantityRequested,
            customerQuestion,
            stockStatus,
            stockSnapshot,
            payloadJson,
            addressValidation.standardized_address || '',
            addressValidation.valid ? 1 : 0,
            addressValidation.provider || '',
            addressValidation.status || '',
            truncateJson(addressValidation.raw_json || addressValidation),
            pickupRequested ? 1 : 0,
            Number.isFinite(pickupStoreId) ? pickupStoreId : null,
            pickupStoreCode || null,
            pickupStoreName || null,
            pickupStoreAddress || null
          ],
          function (insertErr) {
          if (insertErr) {
            return fail(
              'database_error_request_insert',
              'I had trouble creating your request. I will transfer you to pharmacy staff for help.',
              insertErr
            );
          }

          const requestId = this.lastID;

          safeCloseDb();

          queueRefillNotificationEmail({
            refill_request_id: requestId,
            patient_name: customerName,
            phone: callbackPhone,
            medication: requestedMedication,
            status: requestStatus,
            available: enoughStock
          });

          let aiSay = 'Thank you. I entered your pharmacy request for staff to review. They will check it and follow up if needed.';

          if (!addressValidation.valid) {
            aiSay = 'Thank you. I entered your pharmacy request for staff to review. The address may need staff review, but your request has been entered.';
          }

          if (!medicationFound) {
            aiSay = 'Thank you. I entered your request for pharmacy staff to review. I do not show that medication in the current inventory list, so staff will check availability, possible options, or special ordering and follow up if needed.';
          } else if (!hasSomeStock) {
            aiSay = 'Thank you. I entered your request for pharmacy staff to review. This medication may not be available in current stock, so staff will check availability or special ordering and follow up if needed.';
          } else if (!enoughStock) {
            aiSay = 'Thank you. I entered your request for pharmacy staff to review. The medication appears to have limited stock, so staff will check it and follow up if needed.';
          } else if (requestType === 'refill') {
            aiSay = 'Thank you. I entered your refill request for pharmacy staff to review. They will check it and follow up if needed.';
          } else if (requestType === 'stock_question') {
            aiSay = 'Thank you. I entered your stock review question for pharmacy staff to check. They will follow up if needed.';
          }

          return res.json({
            success: true,
            transfer_to_staff: false,
            reason: 'pharmacy_request_created',
            request_id: requestId,
            refill_request_id: requestId,
            email_notification_queued: true,
            request: {
              request_type: requestType,
              customer_name: customerName,
              callback_phone: callbackPhone,
              date_of_birth: dateOfBirth,
              original_address: originalAddress,
              address: addressForDb,
              medication: requestedMedication,
              quantity_requested: quantityRequested,
              customer_question: customerQuestion,
              status: requestStatus,
              stock_status: stockStatus,
              stock_snapshot: stockSnapshot,
              medication_found: medicationFound,
              address_validation: {
                attempted: addressValidation.attempted,
                valid: addressValidation.valid,
                provider: addressValidation.provider,
                status: addressValidation.status,
                standardized_address: addressValidation.standardized_address || ''
              }
            },
            patient: {
              id: patient.id,
              name: patient.first_name + ' ' + patient.last_name,
              verified_existing_patient: patientVerified
            },
            medication: medicationFound ? {
              id: med.id,
              generic_name: med.generic_name,
              brand_name: med.brand_name,
              available: isMarkedAvailable,
              quantity_on_hand: stockSnapshot,
              enough_stock_for_requested_quantity: enoughStock
            } : null,
            ai_say: aiSay
          });
        }
      );
    });
  });
});


app.get('/api/refill-requests', function (req, res) {
  const db = openDb();

  db.all(
    `
      SELECT
        rr.id,
        rr.requested_medication,
        rr.request_type,
        rr.customer_name,
        rr.callback_phone,
        rr.quantity_requested,
        rr.customer_question,
          rr.pickup_requested,
          rr.pickup_store_id,
          rr.pickup_store_code,
          rr.pickup_store_name,
          rr.pickup_store_address,
        rr.stock_status,
        rr.stock_snapshot,
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
      ORDER BY rr.created_at DESC
    `,
    [],
    function (err, rows) {
      db.close();

      if (err) {
        console.error('Refill list error:', err.message);
        return res.status(500).json({
          success: false,
          error: 'Database error'
        });
      }

      res.json({
        success: true,
        count: rows.length,
        refill_requests: rows
      });
    }
  );
});

app.use(auditPostMiddleware(openDb));
installPortalRoutes(app, openDb);
installVoiceAgentPortalRoutes(app);
installChatUnreadRoutes(app, openDb);
installChatRoutes(app, openDb);
installOrderEditRoutes(app, openDb);
installPortalExtraRoutes(app, openDb);
installAdminMedicationRoutes(app, openDb);
installAdminPatientRoutes(app, openDb);
// PHARMACY_LOCATION_ROUTES_V1
require('./pharmacy-location-routes')(app);





// BEGIN PHARMACY_VOICE_AGENT_PORTAL_ROUTES
try {
  const pharmacyVoiceFs = require('fs');
  const pharmacyVoicePath = require('path');

  function pharmacyVoiceEscape(value) {
    return String(value ?? '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#39;');
  }

  function pharmacyVoiceLoggedIn(req) {
    const s = req.session || {};
    return Boolean(
      s.isAdmin ||
      s.admin ||
      s.adminId ||
      s.adminUser ||
      s.user ||
      s.userId ||
      s.portalUser ||
      s.portalUserId ||
      s.username ||
      s.authenticated ||
      s.loggedIn ||
      s.role === 'admin' ||
      s.user?.role === 'admin' ||
      s.user?.isAdmin
    );
  }

  function pharmacyVoiceRequireLogin(req, res, next) {
    if (pharmacyVoiceLoggedIn(req)) return next();
    return res.redirect('/portal/login');
  }

  function pharmacyVoicePaths() {
    const base = pharmacyVoicePath.join(__dirname, 'voice-agent');
    return {
      dir: base,
      local: pharmacyVoicePath.join(base, 'vodia-pharmacy-ai-voice-agent.local.js'),
      template: pharmacyVoicePath.join(base, 'vodia-pharmacy-ai-voice-agent.template.js')
    };
  }

  app.get('/portal/voice-agent', pharmacyVoiceRequireLogin, (req, res) => {
    const paths = pharmacyVoicePaths();
    let script = '';
    let fileStatus = '';

    try {
      script = pharmacyVoiceFs.readFileSync(paths.local, 'utf8');
      fileStatus = 'Ready-to-copy local script loaded.';
    } catch (err) {
      fileStatus = 'Local script not found yet: ' + err.message;
    }

    res.send(`<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Voice Agent Script</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body {
      margin:0;
      font-family: Arial, Helvetica, sans-serif;
      background:#f5f7fb;
      color:#172033;
    }
    header {
      background:linear-gradient(90deg,#102a43,#087f73);
      color:white;
      padding:20px 28px;
    }
    header h1 { margin:0; font-size:24px; }
    nav {
      display:flex;
      flex-wrap:wrap;
      gap:18px;
      margin-top:14px;
    }
    nav a {
      color:white;
      font-weight:700;
      text-decoration:none;
    }
    main {
      max-width:1180px;
      margin:24px auto;
      padding:0 18px 50px;
    }
    .card {
      background:white;
      border:1px solid #e5e7eb;
      border-radius:18px;
      padding:22px;
      box-shadow:0 10px 30px rgba(0,0,0,.06);
      margin-bottom:18px;
    }
    textarea {
      width:100%;
      min-height:520px;
      font-family: Consolas, Monaco, monospace;
      font-size:13px;
      border:1px solid #d0d5dd;
      border-radius:12px;
      padding:14px;
      background:#101828;
      color:#e5e7eb;
      white-space:pre;
    }
    button, .button {
      display:inline-block;
      border:0;
      background:#087f73;
      color:white;
      border-radius:10px;
      padding:11px 16px;
      font-weight:800;
      cursor:pointer;
      text-decoration:none;
      margin-right:10px;
    }
    .warn {
      background:#fffaeb;
      border:1px solid #fdb022;
      border-radius:14px;
      padding:14px 16px;
      color:#93370d;
    }
    .muted { color:#667085; }
    code {
      background:#eef4ff;
      padding:2px 5px;
      border-radius:5px;
    }
  </style>
</head>
<body>
  <header>
    <h1>Vodia Pharmacy Voice Agent</h1>
    <nav>
      <a href="/portal/orders">Agent Orders</a>
      <a href="/portal/chat">Chat</a>
      <a href="/admin/users">Admin Users</a>
      <a href="/portal/patients">Patients</a>
      <a href="/portal/medications">Medications</a>
      <a href="/portal/history">History</a>
      <a href="/admin/settings">Settings</a>
      <a href="/logout">Logout</a>
    </nav>
  </header>

  <main>
    <section class="card">
      <h2>Ready-to-copy Voice Agent script</h2>
      <p class="muted">${pharmacyVoiceEscape(fileStatus)}</p>

      <div class="warn">
        <strong>Important:</strong>
        Paste this JavaScript into the Vodia Voice Agent JavaScript field.
        Add the OpenAI API key in the Vodia Voice Agent OpenAI key field.
        Do <strong>not</strong> paste the OpenAI key into this script.
      </div>

      <p>
        <button onclick="copyScript()">Copy Script</button>
        <a class="button" href="/portal/voice-agent/download/local">Download Local Script</a>
        <a class="button" href="/portal/voice-agent/download/template">Download Template</a>
      </p>

      <textarea id="voiceScript" spellcheck="false">${pharmacyVoiceEscape(script)}</textarea>
    </section>
  </main>

  <script>
    async function copyScript() {
      const el = document.getElementById('voiceScript');
      el.focus();
      el.select();
      try {
        await navigator.clipboard.writeText(el.value);
        alert('Voice Agent script copied.');
      } catch (err) {
        document.execCommand('copy');
        alert('Voice Agent script selected/copied.');
      }
    }
  </script>
</body>
</html>`);
  });

  app.get('/admin/voice-agent-script', pharmacyVoiceRequireLogin, (req, res) => {
    res.redirect('/portal/voice-agent');
  });

  app.get('/portal/voice-agent/download/local', pharmacyVoiceRequireLogin, (req, res) => {
    const paths = pharmacyVoicePaths();
    res.download(paths.local, 'vodia-pharmacy-ai-voice-agent.local.js');
  });

  app.get('/portal/voice-agent/download/template', pharmacyVoiceRequireLogin, (req, res) => {
    const paths = pharmacyVoicePaths();
    res.download(paths.template, 'vodia-pharmacy-ai-voice-agent.template.js');
  });

  console.log('Pharmacy AI Voice Agent portal mounted at /portal/voice-agent');
} catch (err) {
  console.error('Failed to mount Pharmacy AI Voice Agent portal:', err.message);
}
// END PHARMACY_VOICE_AGENT_PORTAL_ROUTES

// Pharmacy AI admin settings: SMTP, Security, Tenant Binding, CRM placeholders
try {
  const adminSettingsRouter = require('./routes/adminSettings');
  app.use('/admin/settings', adminSettingsRouter);
  app.get('/settings', (req, res) => res.redirect('/admin/settings'));
  console.log('Pharmacy AI admin settings mounted at /admin/settings');
} catch (err) {
  console.error('Failed to mount Pharmacy AI admin settings:', err.message);
}

app.listen(PORT, function () {
  console.log(`${PROJECT_NAME} running on port ${PORT}`);
});

// Vodia Phase 2 browser softphone route
app.use(require("./routes/vodia-softphone"));

// Make sure public files are available
app.use(express.static("public"));

// ─────────────────────────────────────────────────────────────────────────────
// AI Previous Pharmacy Request Lookup
// Route: POST /api/ai/previous-request-lookup
// Purpose: Finds a caller's previous pharmacy request using phone + DOB + address/ZIP.
// This is used when a client calls back and wants to check a prior request.
// ─────────────────────────────────────────────────────────────────────────────

function aiNormalizePhoneForLookup(phone) {
  const raw = String(phone || '').trim();
  const digits = raw.replace(/\D/g, '');

  if (!digits) return '';
  if (digits.length === 10) return '+1' + digits;
  if (digits.length === 11 && digits.charAt(0) === '1') return '+' + digits;
  if (raw.charAt(0) === '+') return '+' + digits;

  return digits;
}

function aiNormalizeTextForLookup(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function aiNormalizeDobForLookup(value) {
  return String(value || '').replace(/\D/g, '');
}

function aiDobVariantsForLookup(value) {
  const raw = String(value || '').toLowerCase().trim();
  const digits = raw.replace(/\D/g, '');
  const variants = new Set();

  if (digits) variants.add(digits);

  // 05/19/2000 -> 05192000, 5192000, 20000519
  if (/^\d{8}$/.test(digits)) {
    const mm = digits.slice(0, 2);
    const dd = digits.slice(2, 4);
    const yyyy = digits.slice(4, 8);

    variants.add(mm + dd + yyyy);
    variants.add(String(Number(mm)) + String(Number(dd)) + yyyy);
    variants.add(yyyy + mm + dd);
  }

  // 5-19-2000 -> 5192000, 05192000, 20000519
  if (/^\d{7}$/.test(digits)) {
    const m = digits.slice(0, 1);
    const dd = digits.slice(1, 3);
    const yyyy = digits.slice(3, 7);

    variants.add(m + dd + yyyy);
    variants.add('0' + m + dd + yyyy);
    variants.add(yyyy + '0' + m + dd);

    const mm = digits.slice(0, 2);
    const d = digits.slice(2, 3);
    const yyyy2 = digits.slice(3, 7);

    variants.add(mm + '0' + d + yyyy2);
    variants.add(yyyy2 + mm + '0' + d);
  }

  // 2000-05-19 -> 20000519, 05192000, 5192000
  if (/^\d{4}[-\/]\d{1,2}[-\/]\d{1,2}$/.test(raw)) {
    const parts = raw.split(/[-\/]/);
    const yyyy = parts[0];
    const mm = String(Number(parts[1])).padStart(2, '0');
    const dd = String(Number(parts[2])).padStart(2, '0');

    variants.add(yyyy + mm + dd);
    variants.add(mm + dd + yyyy);
    variants.add(String(Number(mm)) + String(Number(dd)) + yyyy);
  }

  // May 19 2000 / May 19, 2000
  const months = {
    january: '01', jan: '01',
    february: '02', feb: '02',
    march: '03', mar: '03',
    april: '04', apr: '04',
    may: '05',
    june: '06', jun: '06',
    july: '07', jul: '07',
    august: '08', aug: '08',
    september: '09', sep: '09', sept: '09',
    october: '10', oct: '10',
    november: '11', nov: '11',
    december: '12', dec: '12'
  };

  for (const name in months) {
    if (raw.indexOf(name) >= 0) {
      const dayYear = raw.match(/(\d{1,2}).*?(\d{4})/);
      if (dayYear) {
        const mm = months[name];
        const dd = String(Number(dayYear[1])).padStart(2, '0');
        const yyyy = dayYear[2];

        variants.add(mm + dd + yyyy);
        variants.add(String(Number(mm)) + String(Number(dd)) + yyyy);
        variants.add(yyyy + mm + dd);
      }
    }
  }

  return Array.from(variants);
}

function aiDobMatchesForLookup(inputDob, rowDob) {
  const a = aiDobVariantsForLookup(inputDob);
  const b = aiDobVariantsForLookup(rowDob);

  for (const x of a) {
    if (b.indexOf(x) >= 0) return true;
  }

  return false;
}

function aiExtractZipForLookup(value) {
  const match = String(value || '').match(/\b\d{5}\b/);
  return match ? match[0] : '';
}

function aiAddressScore(inputAddress, rowAddress) {
  const input = aiNormalizeTextForLookup(inputAddress);
  const row = aiNormalizeTextForLookup(rowAddress);

  if (!input || !row) return 0;
  if (input === row) return 25;
  if (row.indexOf(input) >= 0 || input.indexOf(row) >= 0) return 20;

  const inputParts = input.split(' ').filter(Boolean);
  if (!inputParts.length) return 0;

  let hits = 0;
  inputParts.forEach(part => {
    if (part.length >= 3 && row.indexOf(part) >= 0) hits++;
  });

  const ratio = hits / inputParts.length;

  if (ratio >= 0.75) return 18;
  if (ratio >= 0.50) return 12;
  if (ratio >= 0.30) return 6;

  return 0;
}

app.post('/api/ai/previous-request-lookup', (req, res) => {
  const expectedSecret =
    process.env.PHARMACY_API_SECRET ||
    process.env.PHARMACY_SECRET ||
    process.env.API_SECRET ||
    '';

  const providedSecret = req.get('X-Pharmacy-Secret') || '';

  if (providedSecret !== expectedSecret) {
    return res.status(401).json({
      success: false,
      found: false,
      error: 'unauthorized'
    });
  }

  const callbackPhone = aiNormalizePhoneForLookup(req.body.callback_phone || '');
  const customerName = String(req.body.customer_name || '').trim();
  const dateOfBirth = String(req.body.date_of_birth || '').trim();
  const address = String(req.body.address || '').trim();

  const lookupLogId = Date.now() + '-' + Math.random().toString(16).slice(2);
  aiPreviousLookupAudit(lookupLogId, 'request_received', {
    phone_last4: aiLast4(callbackPhone),
    dob_present: !!dateOfBirth,
    address_zip: aiExtractZipForLookup(address),
    customer_name_present: !!customerName
  });

  const dobDigits = aiNormalizeDobForLookup(dateOfBirth);
  const inputZip = aiExtractZipForLookup(address);

  if (!dobDigits || !address) {
    return res.status(400).json({
      success: false,
      found: false,
      error: 'missing_required_verification',
      message: 'date_of_birth and address are required'
    });
  }

  const sql = `
    SELECT
      rr.*,
      p.date_of_birth AS patient_date_of_birth,
      p.address AS patient_address,
      p.phone AS patient_phone,
      p.first_name AS patient_first_name,
      p.last_name AS patient_last_name
    FROM refill_requests rr
    LEFT JOIN patients p ON rr.patient_id = p.id
    ORDER BY rr.id DESC
    LIMIT 500
  `;

  const path = require('path');
  const sqlite3 = require('sqlite3').verbose();
  const lookupDb = new sqlite3.Database(path.join(__dirname, 'pharmacy.db'));

  lookupDb.all(sql, [], (err, rows) => {
    lookupDb.close(() => {});
    if (err) {
      console.error('previous-request-lookup database error:', err.message);
      return res.status(500).json({
        success: false,
        found: false,
        error: 'database_error'
      });
    }

    let best = null;
    let lookupScores = [];

    for (const row of rows || []) {
      let aiPayload = {};
      try {
        aiPayload = JSON.parse(row.ai_payload_json || '{}');
      } catch (e) {
        aiPayload = {};
      }

      const rowPhone = aiNormalizePhoneForLookup(
        row.callback_phone ||
        row.customer_phone ||
        row.phone ||
        row.patient_phone ||
        aiPayload.callback_phone ||
        aiPayload.customer_phone ||
        ''
      );

      const rowDobRaw =
        row.date_of_birth ||
        row.dob ||
        row.patient_date_of_birth ||
        aiPayload.date_of_birth ||
        aiPayload.dob ||
        '';

      const rowDob = aiNormalizeDobForLookup(rowDobRaw);

      const rowAddress =
        row.delivery_address ||
        row.validated_address ||
        row.address ||
        row.customer_address ||
        row.patient_address ||
        aiPayload.delivery_address ||
        aiPayload.address ||
        aiPayload.validated_address ||
        '';

      const rowZip = aiExtractZipForLookup(rowAddress);

      const rowName = aiNormalizeTextForLookup(
        row.customer_name ||
        row.caller_name ||
        ((row.patient_first_name || '') + ' ' + (row.patient_last_name || '')) ||
        ''
      );

      const inputName = aiNormalizeTextForLookup(customerName);

      let score = 0;
      let matchParts = [];

      if (callbackPhone && rowPhone && callbackPhone === rowPhone) {
        score += 35;
        matchParts.push('phone');
      }

      if (dateOfBirth && rowDobRaw && aiDobMatchesForLookup(dateOfBirth, rowDobRaw)) {
        score += 40;
        matchParts.push('dob');
      }

      if (inputZip && rowZip && inputZip === rowZip) {
        score += 20;
        matchParts.push('zip');
      }

      const addrScore = aiAddressScore(address, rowAddress);
      if (addrScore > 0) {
        score += addrScore;
        matchParts.push('address');
      }

      if (inputName && rowName && rowName.indexOf(inputName) >= 0) {
        score += 5;
        matchParts.push('name');
      }

      lookupScores.push({
        id: row.id,
        score: score,
        matchParts: matchParts,
        medication: row.requested_medication || row.medication || '',
        status: row.status || '',
        fulfillment_method: row.fulfillment_method || ''
      });

      if (!best || score > best.score) {
        best = { score, row, matchParts };
      }
    }

    const hasDobMatch = best && best.matchParts.indexOf('dob') >= 0;
    const hasPhoneMatch = best && best.matchParts.indexOf('phone') >= 0;
    const hasZipMatch = best && best.matchParts.indexOf('zip') >= 0;
    const hasAddressMatch = best && best.matchParts.indexOf('address') >= 0;

    // Normal secure match: DOB plus another identifier.
    const dobVerifiedMatch =
      best &&
      best.score >= 70 &&
      hasDobMatch &&
      (hasPhoneMatch || hasZipMatch || hasAddressMatch);

    // Practical callback-status fallback:
    // phone + ZIP/address is strong enough to locate a previous request
    // when DOB was spoken/transcribed in a different format.
    const strongPhoneAddressMatch =
      best &&
      best.score >= 75 &&
      hasPhoneMatch &&
      (hasZipMatch || hasAddressMatch);

    const found = dobVerifiedMatch || strongPhoneAddressMatch;

    if (!found) {
      lookupScores.sort((a, b) => b.score - a.score);
      aiPreviousLookupAudit(lookupLogId, 'not_found', {
        best_score: best ? best.score : 0,
        best_match_parts: best ? best.matchParts : [],
        top_scores: lookupScores.slice(0, 5)
      });

      return res.json({
        success: true,
        found: false,
        match_type: 'none',
        message: 'No previous request matched the verification details.'
      });
    }

    const row = best.row;

    const medication =
      row.medication ||
      row.requested_medication ||
      row.requested_item ||
      '';

    const fulfillmentMethod =
      row.fulfillment_method ||
      row.delivery_or_pickup ||
      'undecided';

    const deliveryAddress =
      row.delivery_address ||
      row.validated_address ||
      row.address ||
      '';

    const pharmacyName =
      row.pharmacy_name ||
      row.pickup_store_name ||
      '';

    aiPreviousLookupAudit(lookupLogId, 'found', {
      request_id: row.id,
      score: best.score,
      match_parts: best.matchParts,
      medication: medication,
      status: row.status || '',
      fulfillment_method: fulfillmentMethod
    });

    return res.json({
      success: true,
      found: true,
      match_type: best.matchParts.join('_'),
      score: best.score,
      last_request: {
        request_id: row.id,
        medication: medication,
        status: row.status || 'new',
        fulfillment_method: fulfillmentMethod,
        delivery_address: deliveryAddress,
        pharmacy_name: pharmacyName,
        pickup_store_name: row.pickup_store_name || '',
        pickup_store_address: row.pickup_store_address || '',
        created_at: row.created_at || row.created || ''
      }
    });
  });
});



// ─────────────────────────────────────────────────────────────────────────────
// AI Previous Request Lookup Audit Logging + Status Callback Notes
// ─────────────────────────────────────────────────────────────────────────────

function aiLast4(value) {
  const digits = String(value || '').replace(/\D/g, '');
  return digits.length >= 4 ? digits.slice(-4) : '';
}

function aiPreviousLookupAudit(lookupId, event, payload) {
  try {
    const fs = require('fs');
    const path = require('path');
    const dir = path.join(__dirname, 'logs');
    fs.mkdirSync(dir, { recursive: true });

    const entry = {
      ts: new Date().toISOString(),
      lookup_id: lookupId,
      event,
      payload
    };

    fs.appendFileSync(
      path.join(dir, 'previous-request-lookup.jsonl'),
      JSON.stringify(entry) + '\n'
    );
  } catch (e) {
    console.error('previous lookup audit log failed:', e.message);
  }
}

app.post('/api/ai/status-callback-note', (req, res) => {
  const expectedSecret =
    process.env.PHARMACY_API_SECRET ||
    process.env.PHARMACY_SECRET ||
    process.env.API_SECRET ||
    '';

  const providedSecret = req.get('X-Pharmacy-Secret') || '';

  if (providedSecret !== expectedSecret) {
    return res.status(401).json({
      success: false,
      error: 'unauthorized'
    });
  }

  const requestId = Number(req.body.request_id || req.body.refill_request_id || 0);
  const callerSummary = String(req.body.caller_summary || '').trim();
  const note = `[${new Date().toISOString()}] Caller called for status via AI.${callerSummary ? ' Summary: ' + callerSummary : ''}`;

  if (!requestId) {
    return res.status(400).json({
      success: false,
      error: 'missing_request_id'
    });
  }

  const path = require('path');
  const sqlite3 = require('sqlite3').verbose();
  const noteDb = new sqlite3.Database(path.join(__dirname, 'pharmacy.db'));

  const sql = `
    UPDATE refill_requests
    SET
      agent_notes = CASE
        WHEN agent_notes IS NULL OR agent_notes = '' THEN ?
        ELSE agent_notes || char(10) || ?
      END,
      updated_at = CURRENT_TIMESTAMP,
      status = CASE
        WHEN status IN ('fulfilled', 'completed') THEN status
        ELSE 'needs_follow_up'
      END
    WHERE id = ?
  `;

  noteDb.run(sql, [note, note, requestId], function(err) {
    noteDb.close(() => {});

    if (err) {
      console.error('status callback note error:', err.message);
      return res.status(500).json({
        success: false,
        error: 'database_error'
      });
    }

    if (!this.changes) {
      return res.status(404).json({
        success: false,
        error: 'request_not_found'
      });
    }

    return res.json({
      success: true,
      request_id: requestId,
      note_added: true
    });
  });
});

