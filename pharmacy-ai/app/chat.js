'use strict';

function escapeHtml(value) {
  return String(value || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#039;');
}

function requirePortalLogin(req, res, next) {
  if (req.session && req.session.portalUser) {
    return next();
  }

  return res.redirect('/portal/login');
}

function pageLayout(title, body, user) {
  const isAdmin = user && user.role === 'admin';

  return `
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <link rel="icon" href="/assets/favicon.svg" type="image/svg+xml">
  <title>${escapeHtml(title)}</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      background: #f5f5f5;
      margin: 0;
      color: #222;
    }
    header {
      background: #172033;
      color: white;
      padding: 16px 24px;
    }
    header a {
      color: white;
      margin-right: 14px;
      text-decoration: none;
    }
    main {
      padding: 24px;
    }
    .card {
      background: white;
      border-radius: 10px;
      padding: 20px;
      box-shadow: 0 2px 8px rgba(0,0,0,0.08);
      margin-bottom: 20px;
    }
    .chat-layout {
      display: grid;
      grid-template-columns: 280px 1fr;
      gap: 18px;
    }
    .chat-box {
      height: 520px;
      overflow-y: auto;
      background: white;
      border-radius: 10px;
      border: 1px solid #ddd;
      padding: 14px;
    }
    .message {
      padding: 10px;
      border-radius: 10px;
      margin-bottom: 10px;
      background: #eef0f4;
      max-width: 75%;
    }
    .message.mine {
      background: #dcfce7;
      margin-left: auto;
    }
    .message.other {
      background: #e0f2fe;
      margin-right: auto;
    }
    .message .meta {
      font-size: 12px;
      color: #555;
      margin-bottom: 5px;
    }
    .message .text {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
    }
    input, textarea, select, button {
      font-size: 14px;
      padding: 9px;
      box-sizing: border-box;
    }
    input, textarea, select {
      width: 100%;
      border: 1px solid #d7dce2;
      border-radius: 8px;
      margin-bottom: 10px;
    }
    button, .button {
      background: #172033;
      color: white;
      border: 0;
      border-radius: 6px;
      padding: 9px 14px;
      cursor: pointer;
      text-decoration: none;
      display: inline-block;
    }
    .button-green {
      background: #1c7c37;
    }
    .button-orange {
      background: #b65f00;
    }
    .muted {
      color: #666;
      font-size: 13px;
    }
    .badge {
      display: inline-block;
      background: #dcfce7;
      padding: 4px 8px;
      border-radius: 999px;
      font-size: 12px;
      color: #166534;
      margin-left: 6px;
    }
    @media (max-width: 900px) {
      .chat-layout {
        grid-template-columns: 1fr;
      }
      .chat-box {
        height: 420px;
      }
    }
  </style>
  <link rel="stylesheet" href="/assets/css/pharma-theme.css">
  <script src="/assets/js/pharma-ui.js" defer></script>
</head>
<body>
  <header>
    <h2>Vodia Pharmacy Portal</h2>
    <a href="/portal/orders">Agent Orders</a>
    <a href="/portal/chat">Chat</a>
    ${isAdmin ? '<a href="/admin/users">Admin Users</a><a href="/admin/patients">Patients</a><a href="/admin/medications">Medications</a><a href="/admin/history">History</a>' : ''}
    <a href="/portal/logout">Logout</a>
  </header>
  <main>
    ${body}
  </main>
</body>
</html>
`;
}

function installChatRoutes(app, openDb) {
  app.get('/portal/orders/:id/chat', requirePortalLogin, function (req, res) {
    res.redirect('/portal/chat?order_id=' + encodeURIComponent(req.params.id));
  });

  app.get('/portal/chat', requirePortalLogin, function (req, res) {
    const currentUser = req.session.portalUser;
    const orderId = String(req.query.order_id || '').trim();

    const db = openDb();

    db.all(
      `
        SELECT id, name, username, role, extension, active
        FROM portal_users
        WHERE active = 1
        ORDER BY role ASC, name ASC
      `,
      [],
      function (err, users) {
        db.close();

        if (err) {
          return res.status(500).send(pageLayout('Chat Error', `
            <div class="card">
              <h3>Database error</h3>
              <p>${escapeHtml(err.message)}</p>
            </div>
          `, currentUser));
        }

        const userOptions = users.map(function (user) {
          if (Number(user.id) === Number(currentUser.id)) {
            return '';
          }

          return `<option value="${user.id}">${escapeHtml(user.name || user.username)} (${escapeHtml(user.role)})</option>`;
        }).join('');

        const orderNotice = orderId
          ? `<p class="muted">This chat is linked to order <strong>#${escapeHtml(orderId)}</strong>.</p>`
          : `<p class="muted">General chat. Leave recipient as “All Agents” for a group message.</p>`;

        const body = `
          <div class="card">
            <h3>Agent Chat <span id="newMessageBadge" class="badge" style="display:none;">New message</span></h3>
            ${orderNotice}
            <p class="muted">Logged in as: ${escapeHtml(currentUser.name || currentUser.username)}</p>
            <button type="button" class="button-orange" onclick="enableDing()">Enable Ding</button>
            <span id="dingStatus" class="muted">Ding is off until you enable it.</span>
          </div>

          <div class="chat-layout">
            <div class="card">
              <h3>Chat Settings</h3>

              <label>Recipient</label>
              <select id="recipientId" onchange="resetChatAndLoad()">
                <option value="">All Agents</option>
                ${userOptions}
              </select>

              <label>Order ID</label>
              <input id="orderId" value="${escapeHtml(orderId)}" placeholder="Optional order ID" onchange="resetChatAndLoad()">

              <p class="muted">
                Use order ID when discussing a refill request. Use general chat for normal questions.
              </p>

              <a class="button" href="/portal/orders">Back to Orders</a>
            </div>

            <div>
              <div id="chatBox" class="chat-box"></div>

              <div class="card">
                <label>Message</label>
                <textarea id="messageText" rows="3" placeholder="Type your message here..."></textarea>
                <button type="button" onclick="sendMessage()">Send Message</button>
              </div>
            </div>
          </div>

          <script>
            var currentUserId = ${Number(currentUser.id)};
            var lastId = 0;
            var firstLoad = true;
            var dingEnabled = false;
            var audioContext = null;

            function escapeText(value) {
              return String(value || '')
                .replace(/&/g, '&amp;')
                .replace(/</g, '&lt;')
                .replace(/>/g, '&gt;')
                .replace(/"/g, '&quot;')
                .replace(/'/g, '&#039;');
            }

            function enableDing() {
              try {
                audioContext = new (window.AudioContext || window.webkitAudioContext)();
                dingEnabled = true;
                localStorage.setItem('vodia_chat_ding_enabled', '1');
                document.getElementById('dingStatus').innerText = 'Ding enabled.';
                playDing();
              } catch (e) {
                alert('Could not enable sound: ' + e.message);
              }
            }

            function playDing() {
              if (!dingEnabled) return;

              try {
                if (!audioContext) {
                  audioContext = new (window.AudioContext || window.webkitAudioContext)();
                }

                var oscillator = audioContext.createOscillator();
                var gain = audioContext.createGain();

                oscillator.type = 'sine';
                oscillator.frequency.setValueAtTime(880, audioContext.currentTime);

                gain.gain.setValueAtTime(0.001, audioContext.currentTime);
                gain.gain.exponentialRampToValueAtTime(0.22, audioContext.currentTime + 0.02);
                gain.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 0.22);

                oscillator.connect(gain);
                gain.connect(audioContext.destination);

                oscillator.start();
                oscillator.stop(audioContext.currentTime + 0.24);
              } catch (e) {
                console.log('Ding failed:', e.message);
              }
            }

            function getRecipientId() {
              return document.getElementById('recipientId').value || '';
            }

            function getOrderId() {
              return document.getElementById('orderId').value || '';
            }

            function resetChatAndLoad() {
              lastId = 0;
              firstLoad = true;
              document.getElementById('chatBox').innerHTML = '';
              loadMessages();
            }

            function renderMessage(message) {
              var mine = Number(message.sender_user_id) === Number(currentUserId);
              var div = document.createElement('div');
              div.className = 'message ' + (mine ? 'mine' : 'other');

              var toText = message.recipient_name ? ' to ' + message.recipient_name : ' to All Agents';
              var orderText = message.order_id ? ' | Order #' + message.order_id : '';

              div.innerHTML =
                '<div class="meta"><strong>' + escapeText(message.sender_name || message.sender_username || 'Unknown') + '</strong>' +
                escapeText(toText) + escapeText(orderText) + '<br>' +
                escapeText(message.created_at || '') + '</div>' +
                '<div class="text">' + escapeText(message.message || '') + '</div>';

              return div;
            }

            async function loadMessages() {
              try {
                var url = '/portal/chat/api/messages?after_id=' + encodeURIComponent(lastId)
                  + '&recipient_id=' + encodeURIComponent(getRecipientId())
                  + '&order_id=' + encodeURIComponent(getOrderId());

                var response = await fetch(url);
                var data = await response.json();

                if (!data.success) {
                  console.log('Chat load failed:', data.error);
                  return;
                }

                var chatBox = document.getElementById('chatBox');
                var hasIncoming = false;

                data.messages.forEach(function (message) {
                  chatBox.appendChild(renderMessage(message));

                  if (Number(message.id) > Number(lastId)) {
                    lastId = Number(message.id);
                  }

                  if (!firstLoad && Number(message.sender_user_id) !== Number(currentUserId)) {
                    hasIncoming = true;
                  }
                });

                if (data.messages.length > 0) {
                  chatBox.scrollTop = chatBox.scrollHeight;
                }

                if (hasIncoming) {
                  document.getElementById('newMessageBadge').style.display = 'inline-block';
                  playDing();
                }

                firstLoad = false;
              } catch (e) {
                console.log('Chat polling error:', e.message);
              }
            }

            async function sendMessage() {
              var textarea = document.getElementById('messageText');
              var message = textarea.value.trim();

              if (!message) {
                alert('Type a message first.');
                return;
              }

              try {
                var response = await fetch('/portal/chat/api/messages', {
                  method: 'POST',
                  headers: {
                    'Content-Type': 'application/json'
                  },
                  body: JSON.stringify({
                    recipient_user_id: getRecipientId(),
                    order_id: getOrderId(),
                    message: message
                  })
                });

                var data = await response.json();

                if (!data.success) {
                  alert(data.error || 'Message failed.');
                  return;
                }

                textarea.value = '';
                loadMessages();
              } catch (e) {
                alert('Message failed: ' + e.message);
              }
            }

            document.getElementById('messageText').addEventListener('keydown', function (event) {
              if (event.key === 'Enter' && !event.shiftKey) {
                event.preventDefault();
                sendMessage();
              }
            });

            if (localStorage.getItem('vodia_chat_ding_enabled') === '1') {
              document.getElementById('dingStatus').innerText = 'Ding remembered, click Enable Ding if browser blocks sound.';
            }

            loadMessages();
            setInterval(loadMessages, 4000);
          </script>
        `;

        res.send(pageLayout('Agent Chat', body, currentUser));
      }
    );
  });

  app.get('/portal/chat/api/messages', requirePortalLogin, function (req, res) {
    const currentUserId = Number(req.session.portalUser.id);
    const afterId = Number(req.query.after_id || 0);
    const recipientId = String(req.query.recipient_id || '').trim();
    const orderId = String(req.query.order_id || '').trim();

    const params = [afterId];
    const whereParts = ['m.id > ?'];

    if (orderId && /^\\d+$/.test(orderId)) {
      whereParts.push('m.order_id = ?');
      params.push(orderId);
    } else {
      whereParts.push('m.order_id IS NULL');
    }

    if (recipientId && /^\\d+$/.test(recipientId)) {
      whereParts.push(`
        (
          (m.sender_user_id = ? AND m.recipient_user_id = ?)
          OR
          (m.sender_user_id = ? AND m.recipient_user_id = ?)
        )
      `);
      params.push(currentUserId, recipientId, recipientId, currentUserId);
    } else {
      whereParts.push('m.recipient_user_id IS NULL');
    }

    const db = openDb();

    db.all(
      `
        SELECT
          m.id,
          m.order_id,
          m.sender_user_id,
          m.recipient_user_id,
          m.message,
          m.created_at,
          sender.name AS sender_name,
          sender.username AS sender_username,
          recipient.name AS recipient_name,
          recipient.username AS recipient_username
        FROM portal_chat_messages m
        LEFT JOIN portal_users sender ON m.sender_user_id = sender.id
        LEFT JOIN portal_users recipient ON m.recipient_user_id = recipient.id
        WHERE ${whereParts.join(' AND ')}
        ORDER BY m.id ASC
        LIMIT 100
      `,
      params,
      function (err, rows) {
        db.close();

        if (err) {
          return res.status(500).json({
            success: false,
            error: err.message
          });
        }

        res.json({
          success: true,
          messages: rows
        });
      }
    );
  });

  app.post('/portal/chat/api/messages', requirePortalLogin, function (req, res) {
    const currentUserId = Number(req.session.portalUser.id);
    const recipientUserIdRaw = String(req.body.recipient_user_id || '').trim();
    const orderIdRaw = String(req.body.order_id || '').trim();
    const message = String(req.body.message || '').trim();

    if (!message) {
      return res.status(400).json({
        success: false,
        error: 'Message is required.'
      });
    }

    const recipientUserId = recipientUserIdRaw && /^\\d+$/.test(recipientUserIdRaw)
      ? Number(recipientUserIdRaw)
      : null;

    const orderId = orderIdRaw && /^\\d+$/.test(orderIdRaw)
      ? Number(orderIdRaw)
      : null;

    const db = openDb();

    db.run(
      `
        INSERT INTO portal_chat_messages
        (order_id, sender_user_id, recipient_user_id, message)
        VALUES (?, ?, ?, ?)
      `,
      [orderId, currentUserId, recipientUserId, message],
      function (err) {
        db.close();

        if (err) {
          return res.status(500).json({
            success: false,
            error: err.message
          });
        }

        res.json({
          success: true,
          message_id: this.lastID
        });
      }
    );
  });
}

module.exports = {
  installChatRoutes
};
