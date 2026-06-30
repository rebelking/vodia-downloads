(function () {
  'use strict';

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (m) {
      return ({
        '&': '&amp;',
        '<': '&lt;',
        '>': '&gt;',
        '"': '&quot;',
        "'": '&#39;'
      })[m];
    });
  }

  function valueOrDash(value) {
    const raw = String(value == null ? '' : value).trim();
    return raw || '—';
  }

  function getRequestIdFromPage() {
    const params = new URLSearchParams(window.location.search);
    const queryId = params.get('id') || params.get('request_id') || params.get('order_id');

    if (queryId && /^\d+$/.test(queryId)) {
      return queryId;
    }

    const selected =
      document.querySelector('[data-request-id].selected') ||
      document.querySelector('[data-id].selected') ||
      document.querySelector('.selected[data-request-id]') ||
      document.querySelector('.selected[data-id]');

    if (selected) {
      const selectedId = selected.getAttribute('data-request-id') || selected.getAttribute('data-id');
      if (selectedId && /^\d+$/.test(selectedId)) {
        return selectedId;
      }
    }

    const any =
      document.querySelector('[data-request-id]') ||
      document.querySelector('[data-id]');

    if (any) {
      const anyId = any.getAttribute('data-request-id') || any.getAttribute('data-id');
      if (anyId && /^\d+$/.test(anyId)) {
        return anyId;
      }
    }

    return '';
  }

  async function fetchRxInsurance() {
    const requestId = getRequestIdFromPage();
    const url = requestId
      ? '/api/v1/rx-insurance/' + encodeURIComponent(requestId)
      : '/api/v1/rx-insurance/latest';

    const res = await fetch(url);

    if (!res.ok) {
      throw new Error(await res.text());
    }

    const data = await res.json();

    if (!data.success) {
      throw new Error(data.error || 'Unable to load prescription and insurance detail');
    }

    return data.request;
  }

  function field(label, value) {
    return `
      <div class="rx-board-field">
        <label>${escapeHtml(label)}</label>
        <strong>${escapeHtml(valueOrDash(value))}</strong>
      </div>
    `;
  }

  function renderBoard(data) {
    let mount = document.getElementById('rx-insurance-board-v1');

    if (!mount) {
      mount = document.createElement('div');
      mount.id = 'rx-insurance-board-v1';
      document.body.appendChild(mount);
    }

    if (!data) {
      mount.innerHTML = `
        <div class="rx-insurance-board">
          <div class="rx-board-card">
            <div class="rx-board-title">💊 Prescription Detail</div>
            <div class="rx-board-muted">No request found yet.</div>
          </div>
          <div class="rx-board-card">
            <div class="rx-board-title">🛡 Insurance Board</div>
            <div class="rx-board-muted">No insurance data found yet.</div>
          </div>
        </div>
      `;
      return;
    }

    const rx = data.prescription || {};
    const ins = data.insurance || {};

    mount.innerHTML = `
      <div class="rx-insurance-board">
        <div class="rx-board-card">
          <div class="rx-board-title">💊 Prescription Detail</div>
          <div class="rx-board-grid">
            ${field('Patient name', rx.patient_name)}
            ${field('Medication name', rx.medication_name)}
            ${field('Strength', rx.strength)}
            ${field('Directions', rx.directions)}
            ${field('Quantity', rx.quantity)}
            ${field('Refills', rx.refills)}
            ${field('Prescriber', rx.prescriber)}
            ${field('Pharmacy', rx.pharmacy)}
            ${field('Rx number', rx.rx_number)}
          </div>
        </div>

        <div class="rx-board-card">
          <div class="rx-board-title">🛡 Insurance Board</div>
          <div class="rx-board-grid">
            ${field('Insurance', ins.provider)}
            ${field('Plan type', ins.plan_type)}
            ${field('Member ID', ins.member_id)}
            ${field('Group', ins.group_number)}
            ${field('BIN', ins.bin)}
            ${field('PCN', ins.pcn)}
            ${field('Copay', ins.copay)}
            ${field('Status', ins.status)}
            ${field('Prior authorization', ins.prior_auth_required)}
            ${field('Insurance notes', ins.notes)}
          </div>
          <div class="rx-board-actions">
            <button class="rx-board-btn" onclick="window.loadRxInsuranceBoardV1()">Refresh</button>
          </div>
        </div>
      </div>
    `;
  }

  async function loadBoard() {
    try {
      const data = await fetchRxInsurance();
      renderBoard(data);
    } catch (err) {
      console.error('Prescription/insurance board failed:', err);
      renderBoard(null);
    }
  }

  window.loadRxInsuranceBoardV1 = loadBoard;

  document.addEventListener('click', function () {
    setTimeout(loadBoard, 250);
  });

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', loadBoard);
  } else {
    loadBoard();
  }
})();
