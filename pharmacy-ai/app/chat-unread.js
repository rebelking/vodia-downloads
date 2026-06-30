'use strict';

function requirePortalLogin(req, res, next) {
  if (req.session && req.session.portalUser) {
    return next();
  }

  return res.status(401).json({
    success: false,
    error: 'Not logged in'
  });
}

function insertReadRows(db, userId, rows, callback) {
  if (!rows || rows.length === 0) {
    return callback(null);
  }

  let remaining = rows.length;
  let failed = null;

  rows.forEach(function (row) {
    db.run(
      `
        INSERT OR IGNORE INTO portal_chat_message_reads
        (message_id, user_id)
        VALUES (?, ?)
      `,
      [row.id, userId],
      function (err) {
        if (err && !failed) failed = err;
        remaining--;

        if (remaining === 0) {
          callback(failed);
        }
      }
    );
  });
}

function installChatUnreadRoutes(app, openDb) {
  app.get('/portal/chat/api/unread', requirePortalLogin, function (req, res) {
    const currentUserId = Number(req.session.portalUser.id);
    const db = openDb();

    db.all(
      `
        SELECT
          m.id,
          m.order_id
        FROM portal_chat_messages m
        LEFT JOIN portal_chat_message_reads r
          ON r.message_id = m.id
          AND r.user_id = ?
        WHERE m.sender_user_id != ?
        AND (
          m.recipient_user_id IS NULL
          OR m.recipient_user_id = ?
        )
        AND r.message_id IS NULL
        ORDER BY m.id ASC
      `,
      [currentUserId, currentUserId, currentUserId],
      function (err, rows) {
        db.close();

        if (err) {
          return res.status(500).json({
            success: false,
            error: err.message
          });
        }

        const byOrder = {};
        let general = 0;

        rows.forEach(function (row) {
          if (row.order_id) {
            const key = String(row.order_id);
            byOrder[key] = (byOrder[key] || 0) + 1;
          } else {
            general++;
          }
        });

        res.json({
          success: true,
          total: rows.length,
          general: general,
          by_order: byOrder
        });
      }
    );
  });

  app.post('/portal/chat/api/mark-read', requirePortalLogin, function (req, res) {
    const currentUserId = Number(req.session.portalUser.id);
    const recipientIdRaw = String(req.body.recipient_user_id || '').trim();
    const orderIdRaw = String(req.body.order_id || '').trim();

    const whereParts = [];
    const params = [];

    whereParts.push('m.sender_user_id != ?');
    params.push(currentUserId);

    if (orderIdRaw && /^\d+$/.test(orderIdRaw)) {
      whereParts.push('m.order_id = ?');
      params.push(Number(orderIdRaw));
    } else {
      whereParts.push('m.order_id IS NULL');
    }

    if (recipientIdRaw && /^\d+$/.test(recipientIdRaw)) {
      whereParts.push('m.sender_user_id = ?');
      whereParts.push('m.recipient_user_id = ?');
      params.push(Number(recipientIdRaw), currentUserId);
    } else {
      whereParts.push('m.recipient_user_id IS NULL');
    }

    const db = openDb();

    db.all(
      `
        SELECT m.id
        FROM portal_chat_messages m
        LEFT JOIN portal_chat_message_reads r
          ON r.message_id = m.id
          AND r.user_id = ?
        WHERE ${whereParts.join(' AND ')}
        AND r.message_id IS NULL
      `,
      [currentUserId].concat(params),
      function (err, rows) {
        if (err) {
          db.close();

          return res.status(500).json({
            success: false,
            error: err.message
          });
        }

        insertReadRows(db, currentUserId, rows, function (insertErr) {
          db.close();

          if (insertErr) {
            return res.status(500).json({
              success: false,
              error: insertErr.message
            });
          }

          res.json({
            success: true,
            marked_read: rows.length
          });
        });
      }
    );
  });
}

module.exports = {
  installChatUnreadRoutes
};
