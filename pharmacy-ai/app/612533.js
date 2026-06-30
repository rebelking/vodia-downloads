'use strict';

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const sqlite3 = require('sqlite3').verbose();
const nodemailer = require('nodemailer');

const app = express();

const PORT = process.env.PORT || 3001;
const PROJECT_NAME = process.env.PROJECT_NAME || 'vodia-pharmacy-ai';
const DB_PATH = process.env.DB_PATH || './pharmacy.db';

app.use(cors());
app.use(express.json());

/**
 * Simple shared-secret protection.
 * Requests to protected routes must include:
 * X-Pharmacy-Secret: your-secret-value
 */
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

/**
 * Email transporter for Amazon SES / SMTP.
 */
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

/**
 * Send refill notification email to pharmacy agent.
 * This should not block refill creation if email fails.
 */
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
    <p><a href="${portalUrl}">Open Pharmacy Portal</a></p>
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

/**
 * Home route
 */
app.get('/', function (req, res) {
  res.json({
    success: true,
    project: PROJECT_NAME,
    message: 'Vodia Pharmacy AI server is running',
    port: PORT
  });
});

/**
 * Health check
 */
app.get('/health', function (req, res) {
  res.json({
    success: true,
    status: 'healthy',
    project: PROJECT_NAME,
    database: DB_PATH,
    timestamp: new Date().toISOString()
  });
});

/**
 * Patient lookup
 * Used when caller provides DOB and address.
 */
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

/**
 * Medication check
 * Checks generic name or brand name.
 */
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
      SELECT id, generic_name, brand_name, available, quantity_on_hand, notes
      FROM medications
      WHERE lower(generic_name) = lower(?)
      OR lower(brand_name) = lower(?)
      LIMIT 1
    `,
    [medication, medication],
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

/**
 * General pharmacy refill webhook
 * This can be used for simple testing or non-AI webhook posts.
 */
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
          SELECT id, generic_name, brand_name, available, quantity_on_hand
          FROM medications
          WHERE lower(generic_name) = lower(?)
          OR lower(brand_name) = lower(?)
          LIMIT 1
        `,
        [requestedMedication, requestedMedication],
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

          const available = med.available === 1;
          const requestStatus = available ? 'pending' : 'out_of_stock';

          db.run(
            `
              INSERT INTO refill_requests
              (patient_id, medication_id, requested_medication, status, notes)
              VALUES (?, ?, ?, ?, ?)
            `,
            [
              patient.id,
              med.id,
              requestedMedication,
              requestStatus,
              available
                ? 'Medication found and appears available.'
                : 'Medication found but currently out of stock.'
            ],
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

/**
 * Create test patient
 */
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

/**
 * List patients
 */
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

/**
 * Create medication
 */
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

/**
 * List medications
 */
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

/**
 * Update medication stock
 */
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

/**
 * AI refill intake endpoint
 * Protected with X-Pharmacy-Secret.
 * This is the clean route OpenAI/Vodia should call.
 */
app.post('/api/ai/refill-intake', requirePharmacySecret, function (req, res) {
  const dateOfBirth = String(req.body.date_of_birth || '').trim();
  const address = String(req.body.address || '').trim();
  const requestedMedication = String(req.body.medication || '').trim();

  if (!dateOfBirth || !address || !requestedMedication) {
    return res.status(400).json({
      success: false,
      transfer_to_staff: true,
      reason: 'missing_required_fields',
      ai_say: 'I am missing some required information. I will transfer you to the pharmacy staff for help.'
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
        console.error('AI patient lookup error:', patientErr.message);

        return res.status(500).json({
          success: false,
          transfer_to_staff: true,
          reason: 'database_error_patient_lookup',
          ai_say: 'I am having trouble checking your account right now. I will transfer you to the pharmacy staff for help.'
        });
      }

      if (!patient) {
        db.close();

        return res.status(404).json({
          success: false,
          transfer_to_staff: true,
          reason: 'patient_not_found',
          patient_found: false,
          ai_say: 'I was not able to verify your account with the information provided. I will transfer you to the pharmacy staff for help.'
        });
      }

      db.get(
        `
          SELECT id, generic_name, brand_name, available, quantity_on_hand
          FROM medications
          WHERE lower(generic_name) = lower(?)
          OR lower(brand_name) = lower(?)
          LIMIT 1
        `,
        [requestedMedication, requestedMedication],
        function (medErr, med) {
          if (medErr) {
            db.close();
            console.error('AI medication lookup error:', medErr.message);

            return res.status(500).json({
              success: false,
              transfer_to_staff: true,
              reason: 'database_error_medication_lookup',
              patient_found: true,
              ai_say: 'I found your account, but I am having trouble checking the medication. I will transfer you to the pharmacy staff for help.'
            });
          }

          if (!med) {
            db.close();

            return res.status(404).json({
              success: false,
              transfer_to_staff: true,
              reason: 'medication_not_found',
              patient_found: true,
              medication_found: false,
              ai_say: 'I found your account, but I could not verify that medication. I will transfer you to the pharmacy staff for help.'
            });
          }

          const available = med.available === 1;
          const requestStatus = available ? 'pending' : 'out_of_stock';

          db.run(
            `
              INSERT INTO refill_requests
              (patient_id, medication_id, requested_medication, status, notes)
              VALUES (?, ?, ?, ?, ?)
            `,
            [
              patient.id,
              med.id,
              requestedMedication,
              requestStatus,
              available
                ? 'AI intake created refill request. Medication appears available.'
                : 'AI intake created refill request. Medication appears out of stock.'
            ],
            function (insertErr) {
              db.close();

              if (insertErr) {
                console.error('AI refill insert error:', insertErr.message);

                return res.status(500).json({
                  success: false,
                  transfer_to_staff: true,
                  reason: 'database_error_refill_insert',
                  patient_found: true,
                  medication_found: true,
                  ai_say: 'I found your account and medication, but I had trouble creating the refill request. I will transfer you to the pharmacy staff for help.'
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
                transfer_to_staff: false,
                reason: available ? 'refill_request_created' : 'refill_request_created_out_of_stock',
                refill_request_id: refillRequestId,
                email_notification_queued: true,
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
                ai_say: available
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

/**
 * List refill requests
 */
app.get('/api/refill-requests', function (req, res) {
  const db = openDb();

  db.all(
    `
      SELECT
        rr.id,
        rr.requested_medication,
        rr.status,
        rr.notes,
        rr.created_at,
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

app.listen(PORT, function () {
  console.log(`${PROJECT_NAME} running on port ${PORT}`);
});
