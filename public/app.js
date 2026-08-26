// WatchPoint Master Admin Console
// State Store
const state = {
  adminToken: localStorage.getItem('watchpoint_admin_token') || '',
  currentAccountId: localStorage.getItem('watchpoint_active_account') || '',
  overview: null,
  activeTab: 'guards',
  logFilter: 'all',
  logSearch: '',
  pollTimer: null,
};

// DOM References
const el = {
  authModal: document.getElementById('authModal'),
  authForm: document.getElementById('authForm'),
  adminTokenInput: document.getElementById('adminTokenInput'),
  pinModal: document.getElementById('pinModal'),
  pinForm: document.getElementById('pinForm'),
  pinTargetName: document.getElementById('pinTargetName'),
  pinTargetId: document.getElementById('pinTargetId'),
  newPinInput: document.getElementById('newPinInput'),
  btnCancelPin: document.getElementById('btnCancelPin'),
  addGuardModal: document.getElementById('addGuardModal'),
  addGuardForm: document.getElementById('addGuardForm'),
  newGuardName: document.getElementById('newGuardName'),
  newGuardPin: document.getElementById('newGuardPin'),
  btnShowAddGuard: document.getElementById('btnShowAddGuard'),
  btnCancelAddGuard: document.getElementById('btnCancelAddGuard'),
  btnLockAdmin: document.getElementById('btnLockAdmin'),
  btnRefresh: document.getElementById('btnRefresh'),
  accountSelector: document.getElementById('accountSelector'),
  
  // Telemetry
  telemStatus: document.getElementById('telemStatus'),
  telemUptime: document.getElementById('telemUptime'),
  telemGuards: document.getElementById('telemGuards'),
  telemWhatsapp: document.getElementById('telemWhatsapp'),

  // Tab Panes & Buttons
  navTabs: document.querySelectorAll('.nav-tab'),
  tabPanes: document.querySelectorAll('.tab-pane'),
  guardsList: document.getElementById('guardsList'),

  // WhatsApp Tab
  qrPlaceholder: document.getElementById('qrPlaceholder'),
  qrStatusText: document.getElementById('qrStatusText'),
  qrImage: document.getElementById('qrImage'),
  qrHelpBlock: document.getElementById('qrHelpBlock'),
  qrCardTitle: document.getElementById('qrCardTitle'),
  waActiveAccount: document.getElementById('waActiveAccount'),
  waStatusPill: document.getElementById('waStatusPill'),
  waTargetGroup: document.getElementById('waTargetGroup'),
  waChatsCount: document.getElementById('waChatsCount'),
  chatPicker: document.getElementById('chatPicker'),
  btnApplyChat: document.getElementById('btnApplyChat'),
  btnRestartWhatsApp: document.getElementById('btnRestartWhatsApp'),
  btnLogoutWhatsApp: document.getElementById('btnLogoutWhatsApp'),

  // Schedules Tab
  schedEnabled: document.getElementById('schedEnabled'),
  schedGroupName: document.getElementById('schedGroupName'),
  schedStartHour: document.getElementById('schedStartHour'),
  schedEndHour: document.getElementById('schedEndHour'),
  schedMinInterval: document.getElementById('schedMinInterval'),
  schedMaxInterval: document.getElementById('schedMaxInterval'),
  schedTimezone: document.getElementById('schedTimezone'),
  schedMessage: document.getElementById('schedMessage'),
  btnSaveSchedule: document.getElementById('btnSaveSchedule'),
  btnCalcPreview: document.getElementById('btnCalcPreview'),
  schedPreviewBox: document.getElementById('schedPreviewBox'),

  // Patrol Tab
  patrolMessage: document.getElementById('patrolMessage'),
  patrolMinInterval: document.getElementById('patrolMinInterval'),
  patrolCooldown: document.getElementById('patrolCooldown'),
  checkpointCount: document.getElementById('checkpointCount'),
  checkpointsBody: document.getElementById('checkpointsBody'),
  btnAddCheckpoint: document.getElementById('btnAddCheckpoint'),
  btnSavePatrol: document.getElementById('btnSavePatrol'),
  btnTestPatrol: document.getElementById('btnTestPatrol'),

  // Logs Tab
  logsContainer: document.getElementById('logsContainer'),
  btnCopyLogs: document.getElementById('btnCopyLogs'),
  btnClearLogs: document.getElementById('btnClearLogs'),
  logFilterChips: document.querySelectorAll('.filter-chips .chip'),
  logSearch: document.getElementById('logSearch'),

  toastContainer: document.getElementById('toastContainer'),
};

// URL Query Param Check for token
const urlParams = new URLSearchParams(window.location.search);
if (urlParams.get('token') || urlParams.get('adminToken')) {
  state.adminToken = urlParams.get('token') || urlParams.get('adminToken');
  localStorage.setItem('watchpoint_admin_token', state.adminToken);
  window.history.replaceState({}, document.title, window.location.pathname);
}

// Toast Helper
function showToast(message, type = 'info') {
  const toast = document.createElement('div');
  toast.className = `toast ${type}`;
  toast.textContent = message;
  el.toastContainer.appendChild(toast);
  setTimeout(() => {
    toast.remove();
  }, 4000);
}

// API Helper
async function apiRequest(path, options = {}) {
  const headers = {
    'Content-Type': 'application/json',
    ...(options.headers || {}),
  };
  if (state.adminToken) {
    headers['X-Admin-Token'] = state.adminToken;
    headers['X-Patrol-Token'] = state.adminToken;
  }

  const response = await fetch(path, { ...options, headers });
  if (response.status === 401) {
    promptAdminLogin();
    throw new Error('Master admin authentication required.');
  }

  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

// Admin Auth Handling
function promptAdminLogin() {
  el.authModal.hidden = false;
  el.adminTokenInput.focus();
}

el.authForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const token = el.adminTokenInput.value.trim();
  if (!token) return;

  try {
    state.adminToken = token;
    await apiRequest('/api/admin/auth', { method: 'POST' });
    localStorage.setItem('watchpoint_admin_token', token);
    el.authModal.hidden = true;
    showToast('Admin access granted!', 'success');
    loadOverview();
  } catch (err) {
    showToast(err.message, 'error');
  }
});

el.btnLockAdmin.addEventListener('click', () => {
  localStorage.removeItem('watchpoint_admin_token');
  state.adminToken = '';
  promptAdminLogin();
});

// Formatters
function formatUptime(seconds) {
  if (!seconds) return '0s';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m ${seconds % 60}s`;
}

function formatDate(isoString) {
  if (!isoString) return '--';
  const d = new Date(isoString);
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

// Main Data Fetch
async function loadOverview() {
  try {
    const data = await apiRequest('/api/admin/overview');
    state.overview = data;
    renderTelemetry(data.health);
    renderAccounts(data.accounts);

    // Sync selected account
    if (!state.currentAccountId || !data.accounts.some(a => a.account.id === state.currentAccountId)) {
      state.currentAccountId = data.primaryAccountId || data.accounts[0]?.account.id || '';
      localStorage.setItem('watchpoint_active_account', state.currentAccountId);
    }
    el.accountSelector.value = state.currentAccountId;

    renderActiveAccountData();
  } catch (err) {
    if (err.message.includes('authentication required')) return;
    console.error('Failed to load overview:', err);
  }
}

// Render Top Telemetry
function renderTelemetry(health) {
  if (!health) return;
  el.telemStatus.className = `telem-val status-pill ${health.status === 'ok' ? 'ready' : 'error'}`;
  el.telemStatus.innerHTML = `<span class="dot"></span> ${health.status === 'ok' ? 'Online' : 'Degraded'}`;
  el.telemUptime.textContent = formatUptime(health.uptimeSeconds);
  el.telemGuards.textContent = `${health.totalAccounts} (${health.connectedAccounts} connected)`;
}

// Render Account Dropdown & Guards Tab
function renderAccounts(accounts = []) {
  // Dropdown
  el.accountSelector.innerHTML = accounts
    .map(a => `<option value="${a.account.id}">Guard: ${a.account.name}</option>`)
    .join('');

  // Guards Grid
  if (accounts.length === 0) {
    el.guardsList.innerHTML = '<div class="text-muted text-center" style="grid-column:1/-1;">No guard accounts registered. Click "Add Guard" to create one.</div>';
    return;
  }

  el.guardsList.innerHTML = accounts.map(a => {
    const status = a.status || 'stopped';
    let statusText = 'Disconnected';
    let statusClass = 'disconnected';
    if (status === 'ready') { statusText = 'WhatsApp Ready'; statusClass = 'ready'; }
    else if (status === 'qr') { statusText = 'QR Code Needed'; statusClass = 'qr'; }
    else if (status === 'starting') { statusText = 'Starting…'; statusClass = 'qr'; }

    return `
      <div class="guard-card">
        <div class="guard-card-header">
          <div>
            <div class="guard-phone font-mono">${a.account.name}</div>
            <div class="text-muted font-mono" style="font-size:11px;">ID: ${a.account.id}</div>
          </div>
          <span class="status-pill ${statusClass}"><span class="dot"></span> ${statusText}</span>
        </div>

        <div class="guard-meta">
          <div class="guard-meta-row">
            <span class="text-muted">Security PIN:</span>
            <span class="font-mono">•••• (Configured)</span>
          </div>
          <div class="guard-meta-row">
            <span class="text-muted">Target Group:</span>
            <span class="font-mono">${a.config?.groupName || 'None'}</span>
          </div>
          <div class="guard-meta-row">
            <span class="text-muted">Checkpoints:</span>
            <span>${a.patrolState?.checkpoints?.length || 0} active</span>
          </div>
        </div>

        <div class="guard-actions">
          <button class="btn btn-secondary btn-sm" onclick="openResetPinModal('${a.account.id}', '${a.account.name}')">
            🔑 Reset PIN
          </button>
          <button class="btn btn-secondary btn-sm" onclick="switchAccountAndTab('${a.account.id}', 'whatsapp')">
            📱 Pair WhatsApp
          </button>
          <button class="btn btn-danger btn-sm" onclick="deleteGuard('${a.account.id}', '${a.account.name}')">
            🗑️ Delete
          </button>
        </div>
      </div>
    `;
  }).join('');
}

// Render Data For Currently Selected Guard
function renderActiveAccountData() {
  if (!state.overview) return;
  const current = state.overview.accounts.find(a => a.account.id === state.currentAccountId);
  if (!current) return;

  // Header WhatsApp Pill
  const status = current.status || 'stopped';
  el.telemWhatsapp.className = `telem-val status-pill ${status === 'ready' ? 'ready' : status === 'qr' ? 'qr' : 'disconnected'}`;
  el.telemWhatsapp.innerHTML = `<span class="dot"></span> ${status.toUpperCase()}`;

  // WhatsApp Tab
  el.waActiveAccount.textContent = current.account.name;
  el.waStatusPill.className = `info-value status-pill ${status === 'ready' ? 'ready' : status === 'qr' ? 'qr' : 'disconnected'}`;
  el.waStatusPill.innerHTML = `<span class="dot"></span> ${status.toUpperCase()}`;
  el.waTargetGroup.textContent = current.config?.groupName || 'Not Set';
  el.waChatsCount.textContent = (current.chats || []).length;

  if (status === 'ready') {
    if (el.qrCardTitle) el.qrCardTitle.textContent = 'WhatsApp Session Status';
    el.qrImage.hidden = true;
    el.qrPlaceholder.style.display = 'flex';
    el.qrPlaceholder.innerHTML = `
      <div class="session-connected-box">
        <div class="connected-badge">✓ LINKED & ACTIVE</div>
        <div class="connected-text">WhatsApp is Connected</div>
        <p class="connected-sub">This phone number is actively linked to the multi-device server. All automated shift messages and patrol geofence arrivals will be dispatched automatically.</p>
        <button class="btn btn-danger btn-sm mt-3" onclick="unlinkAndNewQR()">Unlink Device / Generate New QR</button>
      </div>
    `;
    if (el.qrHelpBlock) el.qrHelpBlock.style.display = 'none';
  } else if (current.qrDataUrl) {
    if (el.qrCardTitle) el.qrCardTitle.textContent = 'Live Pairing QR Code';
    el.qrPlaceholder.style.display = 'none';
    el.qrImage.src = current.qrDataUrl;
    el.qrImage.hidden = false;
    if (el.qrHelpBlock) el.qrHelpBlock.style.display = 'block';
  } else {
    if (el.qrCardTitle) el.qrCardTitle.textContent = 'WhatsApp Connection';
    el.qrImage.hidden = true;
    el.qrPlaceholder.style.display = 'flex';
    el.qrPlaceholder.innerHTML = `
      <div class="session-connected-box">
        <div class="spinner"></div>
        <span style="font-weight:600;margin-top:10px;">${current.error ? 'Error: ' + current.error : 'Starting WhatsApp client…'}</span>
        <button class="btn btn-secondary btn-sm mt-3" onclick="forceNewQR()">Force Generate QR</button>
      </div>
    `;
    if (el.qrHelpBlock) el.qrHelpBlock.style.display = 'none';
  }

  // Populate Chat Picker
  el.chatPicker.innerHTML = '<option value="">-- Select from WhatsApp Chats --</option>' +
    (current.chats || []).map(c => `<option value="${c.name}">${c.name} ${c.isGroup ? '(Group)' : ''}</option>`).join('');

  // Schedules Tab
  const cfg = current.config || {};
  el.schedEnabled.checked = Boolean(cfg.schedule?.enabled);
  el.schedGroupName.value = cfg.groupName || '';
  el.schedStartHour.value = cfg.schedule?.startHour ?? 20;
  el.schedEndHour.value = cfg.schedule?.endHour ?? 8;
  el.schedMinInterval.value = cfg.schedule?.minIntervalMinutes ?? 80;
  el.schedMaxInterval.value = cfg.schedule?.maxIntervalMinutes ?? 90;
  el.schedTimezone.value = cfg.timezone || 'America/Toronto';
  el.schedMessage.value = cfg.message || '';

  // Patrol Tab
  const pState = current.patrolState || {};
  el.patrolMessage.value = pState.profile?.messageTemplate || cfg.message || '';
  el.patrolMinInterval.value = cfg.delivery?.minMessageIntervalMinutes ?? 0;
  el.patrolCooldown.value = pState.settings?.checkpointCooldownMinutes ?? 15;
  renderCheckpoints(pState.checkpoints || []);

  // Logs Tab
  renderLogs(current.logs || []);
}

// Checkpoints Table Rendering
let activeCheckpoints = [];
function renderCheckpoints(checkpoints) {
  activeCheckpoints = JSON.parse(JSON.stringify(checkpoints));
  el.checkpointCount.textContent = activeCheckpoints.length;

  if (activeCheckpoints.length === 0) {
    el.checkpointsBody.innerHTML = '<tr><td colspan="5" class="text-muted text-center">No checkpoints configured. Click "+ Add New" to add one.</td></tr>';
    return;
  }

  el.checkpointsBody.innerHTML = activeCheckpoints.map((cp, idx) => `
    <tr>
      <td><input type="text" value="${cp.name || ''}" onchange="updateCheckpoint(${idx}, 'name', this.value)" /></td>
      <td><input type="number" step="any" value="${cp.latitude || ''}" onchange="updateCheckpoint(${idx}, 'latitude', Number(this.value))" /></td>
      <td><input type="number" step="any" value="${cp.longitude || ''}" onchange="updateCheckpoint(${idx}, 'longitude', Number(this.value))" /></td>
      <td><input type="number" value="${cp.radiusMeters || 50}" onchange="updateCheckpoint(${idx}, 'radiusMeters', Number(this.value))" /></td>
      <td>
        <button class="btn btn-danger btn-sm" onclick="removeCheckpoint(${idx})">✕</button>
      </td>
    </tr>
  `).join('');
}

window.updateCheckpoint = (idx, field, val) => {
  if (activeCheckpoints[idx]) activeCheckpoints[idx][field] = val;
};

window.removeCheckpoint = (idx) => {
  activeCheckpoints.splice(idx, 1);
  renderCheckpoints(activeCheckpoints);
};

el.btnAddCheckpoint = document.getElementById('btnAddCheckpoint');
el.btnAddCheckpoint.addEventListener('click', () => {
  activeCheckpoints.push({
    id: `cp-${Date.now()}`,
    name: `Checkpoint ${activeCheckpoints.length + 1}`,
    latitude: 43.6532,
    longitude: -79.3832,
    radiusMeters: 50,
  });
  renderCheckpoints(activeCheckpoints);
});

// Logs Rendering
function renderLogs(logs) {
  let filtered = logs;
  if (state.logFilter !== 'all') {
    filtered = filtered.filter(l => (l.category || '').toLowerCase().includes(state.logFilter) || (l.level || '').toLowerCase().includes(state.logFilter));
  }
  if (state.logSearch) {
    const q = state.logSearch.toLowerCase();
    filtered = filtered.filter(l => (l.message || '').toLowerCase().includes(q));
  }

  if (filtered.length === 0) {
    el.logsContainer.innerHTML = '<div class="text-muted text-center" style="padding:20px;">No matching log entries found.</div>';
    return;
  }

  el.logsContainer.innerHTML = filtered.map(l => {
    const cat = l.category || 'system';
    return `
      <div class="log-entry">
        <span class="log-time font-mono">${formatDate(l.timestamp)}</span>
        <span class="log-badge ${cat}">${cat}</span>
        <span class="log-msg">${l.message}</span>
      </div>
    `;
  }).join('');
}

// Log Filters
el.logFilterChips.forEach(chip => {
  chip.addEventListener('click', () => {
    el.logFilterChips.forEach(c => c.classList.remove('active'));
    chip.classList.add('active');
    state.logFilter = chip.dataset.filter;
    renderActiveAccountData();
  });
});

el.logSearch.addEventListener('input', (e) => {
  state.logSearch = e.target.value;
  renderActiveAccountData();
});

// Save Schedule Action
el.btnSaveSchedule.addEventListener('click', async () => {
  try {
    const current = state.overview.accounts.find(a => a.account.id === state.currentAccountId);
    const cfg = current.config || {};

    const updatedConfig = {
      ...cfg,
      groupName: el.schedGroupName.value.trim(),
      message: el.schedMessage.value,
      timezone: el.schedTimezone.value.trim(),
      schedule: {
        ...(cfg.schedule || {}),
        enabled: el.schedEnabled.checked,
        startHour: Number(el.schedStartHour.value),
        endHour: Number(el.schedEndHour.value),
        minIntervalMinutes: Number(el.schedMinInterval.value),
        maxIntervalMinutes: Number(el.schedMaxInterval.value),
      },
    };

    await apiRequest('/api/admin/config', {
      method: 'PUT',
      body: JSON.stringify({ accountId: state.currentAccountId, config: updatedConfig }),
    });

    showToast('Schedule settings saved successfully!', 'success');
    loadOverview();
  } catch (err) {
    showToast(`Failed to save schedule: ${err.message}`, 'error');
  }
});

// Calculate Timing Preview
el.btnCalcPreview.addEventListener('click', async () => {
  try {
    const previewConfig = {
      schedule: {
        enabled: el.schedEnabled.checked,
        startHour: Number(el.schedStartHour.value),
        endHour: Number(el.schedEndHour.value),
        minIntervalMinutes: Number(el.schedMinInterval.value),
        maxIntervalMinutes: Number(el.schedMaxInterval.value),
      },
      timezone: el.schedTimezone.value.trim(),
    };

    const res = await apiRequest('/api/config/preview', {
      method: 'POST',
      body: JSON.stringify({ config: previewConfig }),
    });

    if (res.preview) {
      el.schedPreviewBox.innerHTML = `
        <strong>Status:</strong> ${res.preview.enabled ? 'Enabled' : 'Disabled'}<br>
        <strong>Next Calculated Run:</strong> ${res.preview.nextSendAt ? new Date(res.preview.nextSendAt).toLocaleString() : 'None'}<br>
        <strong>Interval Window:</strong> ${previewConfig.schedule.minIntervalMinutes} - ${previewConfig.schedule.maxIntervalMinutes} mins
      `;
    }
  } catch (err) {
    showToast(err.message, 'error');
  }
});

// Save Patrol Settings Action
el.btnSavePatrol.addEventListener('click', async () => {
  try {
    const current = state.overview.accounts.find(a => a.account.id === state.currentAccountId);
    const pState = current.patrolState || {};
    const cfg = current.config || {};

    const updatedPatrolState = {
      ...pState,
      checkpoints: activeCheckpoints,
      settings: {
        ...(pState.settings || {}),
        checkpointCooldownMinutes: Number(el.patrolCooldown.value),
      },
      profile: {
        ...(pState.profile || {}),
        messageTemplate: el.patrolMessage.value,
      },
    };

    const updatedConfig = {
      ...cfg,
      delivery: {
        ...(cfg.delivery || {}),
        minMessageIntervalMinutes: Number(el.patrolMinInterval.value),
      },
    };

    await apiRequest('/api/admin/patrol-state', {
      method: 'PUT',
      body: JSON.stringify({ accountId: state.currentAccountId, patrolState: updatedPatrolState }),
    });

    await apiRequest('/api/admin/config', {
      method: 'PUT',
      body: JSON.stringify({ accountId: state.currentAccountId, config: updatedConfig }),
    });

    showToast('Checkpoints and patrol controls saved!', 'success');
    loadOverview();
  } catch (err) {
    showToast(`Failed to save patrol state: ${err.message}`, 'error');
  }
});

// Test Patrol Send
el.btnTestPatrol.addEventListener('click', async () => {
  const confirmed = confirm('Trigger a test patrol arrival send now to WhatsApp?');
  if (!confirmed) return;
  try {
    await apiRequest(`/api/patrol/trigger?account=${state.currentAccountId}&dryRun=0`, {
      method: 'POST',
      body: JSON.stringify({ source: 'admin-web-console', checkpointName: 'Test Checkpoint' }),
    });
    showToast('Test patrol message dispatched!', 'success');
    loadOverview();
  } catch (err) {
    showToast(`Test send failed: ${err.message}`, 'error');
  }
});

// Reset PIN Modal Handlers
window.openResetPinModal = (accountId, accountName) => {
  el.pinTargetId.value = accountId;
  el.pinTargetName.textContent = accountName;
  el.newPinInput.value = '';
  el.pinModal.hidden = false;
  el.newPinInput.focus();
};

el.btnCancelPin.addEventListener('click', () => {
  el.pinModal.hidden = true;
});

el.pinForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const accountId = el.pinTargetId.value;
  const newPin = el.newPinInput.value.trim();
  if (newPin.length < 4) {
    showToast('PIN must be at least 4 digits.', 'error');
    return;
  }

  try {
    const res = await apiRequest('/api/admin/reset-pin', {
      method: 'POST',
      body: JSON.stringify({ accountId, newPin }),
    });
    el.pinModal.hidden = true;
    showToast(res.message || 'PIN updated successfully!', 'success');
    loadOverview();
  } catch (err) {
    showToast(`Could not reset PIN: ${err.message}`, 'error');
  }
});

// Add Guard Modal Handlers
el.btnShowAddGuard.addEventListener('click', () => {
  el.newGuardName.value = '';
  el.newGuardPin.value = '';
  el.addGuardModal.hidden = false;
  el.newGuardName.focus();
});

el.btnCancelAddGuard.addEventListener('click', () => {
  el.addGuardModal.hidden = true;
});

el.addGuardForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  const name = el.newGuardName.value.trim();
  const password = el.newGuardPin.value.trim();

  try {
    await apiRequest('/api/accounts', {
      method: 'POST',
      body: JSON.stringify({ name, password }),
    });
    el.addGuardModal.hidden = true;
    showToast(`Guard "${name}" registered successfully!`, 'success');
    loadOverview();
  } catch (err) {
    showToast(`Could not add guard: ${err.message}`, 'error');
  }
});

// Delete Guard
window.deleteGuard = async (accountId, accountName) => {
  const confirmed = confirm(`Are you sure you want to permanently delete guard "${accountName}"?`);
  if (!confirmed) return;

  try {
    await apiRequest(`/api/accounts?account=${accountId}`, {
      method: 'DELETE',
    });
    showToast(`Guard "${accountName}" removed.`, 'success');
    loadOverview();
  } catch (err) {
    showToast(`Failed to delete guard: ${err.message}`, 'error');
  }
};

// WhatsApp Session Actions
window.unlinkAndNewQR = async () => {
  const confirmed = confirm('Unlink this active WhatsApp session and generate a fresh QR code?');
  if (!confirmed) return;
  try {
    await apiRequest('/api/admin/whatsapp/logout', {
      method: 'POST',
      body: JSON.stringify({ accountId: state.currentAccountId }),
    });
    showToast('Unlinking session… Fresh QR code is generating!', 'info');
    loadOverview();
  } catch (err) {
    showToast(err.message, 'error');
  }
};

window.forceNewQR = async () => {
  try {
    await apiRequest('/api/admin/whatsapp/logout', {
      method: 'POST',
      body: JSON.stringify({ accountId: state.currentAccountId }),
    });
    showToast('Restarting WhatsApp and generating fresh QR…', 'info');
    loadOverview();
  } catch (err) {
    showToast(err.message, 'error');
  }
};

el.btnRestartWhatsApp.addEventListener('click', window.forceNewQR);
el.btnLogoutWhatsApp.addEventListener('click', window.unlinkAndNewQR);

// Apply Chat from dropdown
el.btnApplyChat.addEventListener('click', () => {
  const chosen = el.chatPicker.value;
  if (!chosen) return;
  el.schedGroupName.value = chosen;
  showToast(`Selected "${chosen}" as destination group. Remember to click "Save Changes"!`, 'info');
});

// Helper to switch account & tab
window.switchAccountAndTab = (accountId, tabName) => {
  state.currentAccountId = accountId;
  localStorage.setItem('watchpoint_active_account', accountId);
  el.accountSelector.value = accountId;

  // Switch tab
  el.navTabs.forEach(t => t.classList.toggle('active', t.dataset.tab === tabName));
  el.tabPanes.forEach(p => p.classList.toggle('active', p.id === `tab-${tabName}`));

  renderActiveAccountData();
};

// Account Selector Dropdown Change
el.accountSelector.addEventListener('change', (e) => {
  state.currentAccountId = e.target.value;
  localStorage.setItem('watchpoint_active_account', state.currentAccountId);
  renderActiveAccountData();
});

// Tab Switching
el.navTabs.forEach(tab => {
  tab.addEventListener('click', () => {
    el.navTabs.forEach(t => t.classList.remove('active'));
    el.tabPanes.forEach(p => p.classList.remove('active'));
    tab.classList.add('active');
    const target = document.getElementById(`tab-${tab.dataset.tab}`);
    if (target) target.classList.add('active');
  });
});

// Copy & Clear Logs
el.btnCopyLogs.addEventListener('click', () => {
  const current = state.overview?.accounts.find(a => a.account.id === state.currentAccountId);
  if (!current?.logs) return;
  const text = current.logs.map(l => `[${l.timestamp}] [${l.category || 'system'}] ${l.message}`).join('\n');
  navigator.clipboard.writeText(text);
  showToast('Activity logs copied to clipboard!', 'success');
});

el.btnClearLogs.addEventListener('click', async () => {
  try {
    await apiRequest(`/api/logs?account=${state.currentAccountId}&scope=all`, {
      method: 'DELETE',
    });
    showToast('Logs cleared.', 'success');
    loadOverview();
  } catch (err) {
    showToast(`Could not clear logs: ${err.message}`, 'error');
  }
});

// Manual Refresh
el.btnRefresh.addEventListener('click', () => {
  loadOverview();
  showToast('Dashboard refreshed.', 'info');
});

// Polling Loop (every 5 seconds)
function startPolling() {
  loadOverview();
  state.pollTimer = setInterval(loadOverview, 5000);
}

// Initial Boot
startPolling();
