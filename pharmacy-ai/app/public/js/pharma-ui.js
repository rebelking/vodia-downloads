(function () {
  var previousUnreadTotal = null;
  var dingEnabled = localStorage.getItem('vodia_global_ding_enabled') === '1';
  var audioContext = null;

  function pathIsLogin() {
    return window.location.pathname === '/portal/login';
  }

  function pathIsForgot() {
    return window.location.pathname === '/portal/forgot-password';
  }

  function applyPageClasses() {
    if (pathIsLogin()) document.body.classList.add('portal-login');
    if (pathIsForgot()) document.body.classList.add('portal-forgot');
  }

  function applyTheme() {
    var theme = localStorage.getItem('vodia_pharma_theme') || 'light';
    document.documentElement.setAttribute('data-theme', theme);
  }

  function toggleTheme() {
    var current = document.documentElement.getAttribute('data-theme') || 'light';
    var next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem('vodia_pharma_theme', next);
    document.documentElement.setAttribute('data-theme', next);
    updateThemeButton();
  }

  function updateThemeButton() {
    var btn = document.getElementById('pharmaThemeToggle');
    if (!btn) return;

    var theme = document.documentElement.getAttribute('data-theme') || 'light';
    btn.textContent = theme === 'dark' ? 'Light Mode' : 'Dark Mode';
  }

  function ensureAudioContext() {
    if (!audioContext) {
      audioContext = new (window.AudioContext || window.webkitAudioContext)();
    }
  }

  function playDing() {
    if (!dingEnabled) return;

    try {
      ensureAudioContext();

      var oscillator = audioContext.createOscillator();
      var gain = audioContext.createGain();

      oscillator.type = 'sine';
      oscillator.frequency.setValueAtTime(988, audioContext.currentTime);

      gain.gain.setValueAtTime(0.001, audioContext.currentTime);
      gain.gain.exponentialRampToValueAtTime(0.22, audioContext.currentTime + 0.02);
      gain.gain.exponentialRampToValueAtTime(0.001, audioContext.currentTime + 0.25);

      oscillator.connect(gain);
      gain.connect(audioContext.destination);

      oscillator.start();
      oscillator.stop(audioContext.currentTime + 0.28);
    } catch (e) {
      console.log('Ding failed:', e.message);
    }
  }

  function toggleDing() {
    try {
      ensureAudioContext();
      dingEnabled = !dingEnabled;
      localStorage.setItem('vodia_global_ding_enabled', dingEnabled ? '1' : '0');
      updateDingButton();

      if (dingEnabled) playDing();
    } catch (e) {
      alert('Could not enable sound: ' + e.message);
    }
  }

  function updateDingButton() {
    var btn = document.getElementById('pharmaDingToggle');
    if (!btn) return;

    btn.textContent = dingEnabled ? 'Ding On' : 'Ding Off';
  }

  function addHeaderControls() {
    var header = document.querySelector('header');
    if (!header || document.getElementById('pharmaThemeToggle')) return;

    var controls = document.createElement('span');
    controls.className = 'pharma-controls';

    var themeBtn = document.createElement('button');
    themeBtn.type = 'button';
    themeBtn.id = 'pharmaThemeToggle';
    themeBtn.className = 'pharma-small-button';
    themeBtn.addEventListener('click', toggleTheme);

    var dingBtn = document.createElement('button');
    dingBtn.type = 'button';
    dingBtn.id = 'pharmaDingToggle';
    dingBtn.className = 'pharma-small-button';
    dingBtn.addEventListener('click', toggleDing);

    controls.appendChild(themeBtn);
    controls.appendChild(dingBtn);

    header.appendChild(controls);

    updateThemeButton();
    updateDingButton();
  }

  function ensureChatNavBadge() {
    var chatLinks = document.querySelectorAll('a[href="/portal/chat"]');

    chatLinks.forEach(function (link) {
      if (link.querySelector('.chat-unread-badge')) return;

      var badge = document.createElement('span');
      badge.className = 'chat-unread-badge chat-nav-unread';
      badge.textContent = '0';
      link.appendChild(badge);
    });
  }

  function ensureOrderChatBadges() {
    var links = document.querySelectorAll('a[href^="/portal/orders/"][href$="/chat"]');

    links.forEach(function (link) {
      if (link.querySelector('.chat-unread-badge')) return;

      var badge = document.createElement('span');
      badge.className = 'chat-unread-badge order-chat-unread';
      badge.textContent = '0';
      link.appendChild(badge);
    });
  }

  function getOrderIdFromChatLink(href) {
    var match = String(href || '').match(/\/portal\/orders\/(\d+)\/chat/);
    return match ? match[1] : '';
  }

  function updateBadge(el, count) {
    if (!el) return;

    count = Number(count || 0);
    el.textContent = String(count);

    if (count > 0) el.classList.add('show');
    else el.classList.remove('show');
  }

  async function fetchUnread() {
    try {
      var response = await fetch('/portal/chat/api/unread', {
        credentials: 'same-origin'
      });

      if (!response.ok) return;

      var data = await response.json();

      if (!data.success) return;

      ensureChatNavBadge();
      ensureOrderChatBadges();

      document.querySelectorAll('.chat-nav-unread').forEach(function (badge) {
        updateBadge(badge, data.total || 0);
      });

      document.querySelectorAll('a[href^="/portal/orders/"][href$="/chat"]').forEach(function (link) {
        var orderId = getOrderIdFromChatLink(link.getAttribute('href'));
        var badge = link.querySelector('.order-chat-unread');
        var count = data.by_order && data.by_order[orderId] ? data.by_order[orderId] : 0;
        updateBadge(badge, count);
      });

      if (
        previousUnreadTotal !== null &&
        Number(data.total || 0) > Number(previousUnreadTotal || 0)
      ) {
        playDing();
      }

      previousUnreadTotal = Number(data.total || 0);
    } catch (e) {
      // User may not be logged in on public pages. No need to scream.
    }
  }

  async function markChatRead() {
    if (window.location.pathname !== '/portal/chat') return;

    var orderEl = document.getElementById('orderId');
    var recipientEl = document.getElementById('recipientId');

    var orderId = orderEl ? orderEl.value || '' : '';
    var recipientId = recipientEl ? recipientEl.value || '' : '';

    try {
      await fetch('/portal/chat/api/mark-read', {
        method: 'POST',
        credentials: 'same-origin',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          order_id: orderId,
          recipient_user_id: recipientId
        })
      });

      fetchUnread();
    } catch (e) {
      console.log('mark-read failed:', e.message);
    }
  }

  function init() {
    applyTheme();
    applyPageClasses();
    addHeaderControls();
    ensureChatNavBadge();
    ensureOrderChatBadges();

    fetchUnread();

    if (window.location.pathname === '/portal/chat') {
      setTimeout(markChatRead, 800);
      setInterval(markChatRead, 5000);
    }

    setInterval(fetchUnread, 10000);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
