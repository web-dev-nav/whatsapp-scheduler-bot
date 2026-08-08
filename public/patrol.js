/* Patrol Mode — GPS-triggered patrol message.
 *
 * Lets the guard mark checkpoints on a map and, during a live patrol, sends the
 * WhatsApp patrol message automatically when the phone enters a checkpoint
 * radius. The actual send happens server-side (POST /api/patrol/trigger); this
 * page only detects location and calls that webhook. */

const DEFAULT_CENTER = [43.1394, -80.2644]; // Brantford, Ontario fallback
const DEFAULT_RADIUS = 60; // meters
const RE_ARM_MARGIN = 25; // must leave radius + this many meters before it can fire again

let currentAccountId = localStorage.getItem('currentAccountId') || 'main';
let loadedConfig = null; // full config object, so we can PUT it back intact
let accounts = [];
let checkpoints = []; // [{ id, name, lat, lng, radiusMeters }]
let map = null;
let markerLayers = new Map(); // id -> { marker, circle }
let meMarker = null;

let watchId = null;
const armed = new Map(); // checkpoint id -> true when ready to fire (left the zone)

const el = (id) => document.getElementById(id);
const accountQuery = () => `account=${encodeURIComponent(currentAccountId)}`;

function accountAuthKey(accountId = currentAccountId) {
  return `accountAuth:${accountId}`;
}

function accountAuthToken(accountId = currentAccountId) {
  return sessionStorage.getItem(accountAuthKey(accountId)) || '';
}

function setAccountAuthToken(accountId, token) {
  if (token) sessionStorage.setItem(accountAuthKey(accountId), token);
  else sessionStorage.removeItem(accountAuthKey(accountId));
}

function accountAuthHeaders(accountId = currentAccountId, headers = {}) {
  const token = accountAuthToken(accountId);
  return token ? { ...headers, 'X-Account-Auth': token } : headers;
}

function accountById(accountId) {
  return accounts.find((account) => account.id === accountId);
}

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (ch) => {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
  });
}

function requestPassword({ title, label, submitText }) {
  return new Promise((resolve) => {
    const backdrop = document.createElement('div');
    backdrop.className = 'password-dialog-backdrop';
    backdrop.innerHTML = `
      <form class="password-dialog">
        <h2>${escapeHtml(title)}</h2>
        <label class="field">
          <span>${escapeHtml(label)}</span>
          <input type="password" autocomplete="current-password" minlength="4" required />
        </label>
        <div class="password-dialog-actions">
          <button class="btn btn-ghost" type="button" data-cancel>Cancel</button>
          <button class="btn btn-primary" type="submit">${escapeHtml(submitText)}</button>
        </div>
      </form>
    `;

    const form = backdrop.querySelector('form');
    const input = backdrop.querySelector('input');
    const close = (value) => {
      backdrop.remove();
      resolve(value);
    };

    form.addEventListener('submit', (event) => {
      event.preventDefault();
      close(input.value);
    });
    backdrop.querySelector('[data-cancel]').addEventListener('click', () => close(null));
    backdrop.addEventListener('click', (event) => {
      if (event.target === backdrop) close(null);
    });

    document.body.append(backdrop);
    input.focus();
  });
}

async function setInitialAccountPassword(account) {
  const password = await requestPassword({
    title: `Protect ${account.name}`,
    label: 'Create password',
    submitText: 'Save password',
  });
  if (password === null) return false;

  const response = await fetch('/api/accounts/password', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: account.id, password }),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to set password.');

  accounts = payload.accounts || accounts.map((candidate) => (
    candidate.id === account.id ? { ...candidate, hasPassword: true } : candidate
  ));
  setAccountAuthToken(account.id, payload.token);
  return true;
}

async function loginToAccount(account) {
  const password = await requestPassword({
    title: `Unlock ${account.name}`,
    label: 'Password',
    submitText: 'Unlock',
  });
  if (password === null) return false;

  const response = await fetch('/api/accounts/auth', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ account: account.id, password }),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to unlock account.');

  setAccountAuthToken(account.id, payload.token);
  return true;
}

async function ensureAccountAccess(accountId = currentAccountId) {
  if (accountAuthToken(accountId)) return true;

  const account = accountById(accountId);
  if (!account) throw new Error(`Unknown account "${accountId}".`);
  if (!account.hasPassword) return setInitialAccountPassword(account);
  return loginToAccount(account);
}

async function fetchWithAccountAuth(url, options = {}, accountId = currentAccountId) {
  const withAuth = {
    ...options,
    headers: accountAuthHeaders(accountId, options.headers || {}),
  };
  let response = await fetch(url, withAuth);

  if (response.status !== 401 && response.status !== 423) {
    return response;
  }

  setAccountAuthToken(accountId, '');
  const unlocked = await ensureAccountAccess(accountId);
  if (!unlocked) return response;

  response = await fetch(url, {
    ...options,
    headers: accountAuthHeaders(accountId, options.headers || {}),
  });
  return response;
}

function patrolTokenKey() {
  return `patrolToken:${currentAccountId}`;
}

function getPatrolToken() {
  return el('patrolToken').value.trim();
}

function patrolTriggerQuery(extra = '') {
  const params = new URLSearchParams(accountQuery());
  const token = getPatrolToken();
  if (token) params.set('token', token);
  if (extra) {
    const extraParams = new URLSearchParams(extra);
    extraParams.forEach((value, key) => params.set(key, value));
  }
  return params.toString();
}

function loadPatrolTokenInput() {
  el('patrolToken').value = localStorage.getItem(patrolTokenKey()) || '';
}

function savePatrolTokenInput() {
  const token = getPatrolToken();
  if (token) localStorage.setItem(patrolTokenKey(), token);
  else localStorage.removeItem(patrolTokenKey());
}

function toast(message, kind = 'ok') {
  const node = el('toast');
  node.textContent = message;
  node.className = `toast show ${kind}`;
  clearTimeout(node._timer);
  node._timer = setTimeout(() => {
    node.className = 'toast';
  }, 6000);
}

/* ---------- distance (haversine, meters) ---------- */
function distanceMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

/* ---------- accounts ---------- */
async function loadAccounts() {
  const response = await fetch(`/api/accounts?t=${Date.now()}`, { cache: 'no-store' });
  const data = await response.json();
  accounts = data.accounts || [];
  const select = el('accountSelect');
  select.innerHTML = '';

  if (!accounts.some((a) => a.id === currentAccountId)) {
    currentAccountId = accounts[0]?.id || 'main';
  }

  accounts.forEach((account) => {
    const option = document.createElement('option');
    option.value = account.id;
    option.textContent = account.name;
    select.appendChild(option);
  });
  select.value = currentAccountId;
}

/* ---------- WhatsApp connection status ---------- */
async function refreshConnection() {
  try {
    const response = await fetchWithAccountAuth(`/api/whatsapp?${accountQuery()}&t=${Date.now()}`, {
      cache: 'no-store',
    });
    const data = await response.json();
    const dot = el('connDot');
    const text = el('connText');

    if (data.status === 'ready') {
      dot.className = 'conn-dot ok';
      text.textContent = 'WhatsApp connected — ready to send';
    } else if (data.status === 'qr' || data.status === 'authenticated' || data.status === 'starting') {
      dot.className = 'conn-dot warn';
      text.textContent = 'WhatsApp not linked yet — open the Scheduler to connect';
    } else {
      dot.className = 'conn-dot bad';
      text.textContent = `WhatsApp: ${data.status}${data.error ? ` (${data.error})` : ''}`;
    }
  } catch (error) {
    el('connDot').className = 'conn-dot bad';
    el('connText').textContent = 'Cannot reach server';
  }
}

/* ---------- config / checkpoints ---------- */
async function loadConfig() {
  const response = await fetchWithAccountAuth(`/api/config?${accountQuery()}`);
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Unable to load patrol settings.');
  loadedConfig = data.config;
  checkpoints = [...((loadedConfig.patrol && loadedConfig.patrol.checkpoints) || [])];
  el('targetGroup').textContent = loadedConfig.groupName || 'your group';
}

async function saveCheckpoints() {
  if (!loadedConfig) return;
  // Read current UI values back into the checkpoint objects before saving.
  syncCheckpointsFromInputs();

  const nextConfig = {
    ...loadedConfig,
    patrol: {
      checkpoints: checkpoints.map((checkpoint, index) => ({
        id: checkpoint.id || `cp-${index + 1}`,
        name: checkpoint.name || `Checkpoint ${index + 1}`,
        lat: Number(checkpoint.lat),
        lng: Number(checkpoint.lng),
        radiusMeters: Number(checkpoint.radiusMeters) || DEFAULT_RADIUS,
      })),
    },
  };

  const button = el('saveCheckpoints');
  button.disabled = true;
  button.textContent = 'Saving…';
  try {
    const response = await fetchWithAccountAuth(`/api/config?${accountQuery()}`, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ config: nextConfig }),
    });
    if (!response.ok) throw new Error((await response.json()).error || 'Save failed');
    await loadConfig();
    renderCheckpoints();
    renderMapCheckpoints();
    toast(`${checkpoints.length} checkpoint${checkpoints.length === 1 ? '' : 's'} saved.`, 'ok');
  } catch (error) {
    toast(`Could not save: ${error.message}`, 'err');
  } finally {
    button.disabled = false;
    button.textContent = 'Save checkpoints';
  }
}

function nextCheckpointId() {
  let n = checkpoints.length + 1;
  let id = `cp-${n}`;
  const existing = new Set(checkpoints.map((c) => c.id));
  while (existing.has(id)) {
    n += 1;
    id = `cp-${n}`;
  }
  return id;
}

function addCheckpoint(lat, lng) {
  const id = nextCheckpointId();
  checkpoints.push({
    id,
    name: `Checkpoint ${checkpoints.length + 1}`,
    lat: Number(lat.toFixed(6)),
    lng: Number(lng.toFixed(6)),
    radiusMeters: DEFAULT_RADIUS,
  });
  renderCheckpoints();
  renderMapCheckpoints();
}

function removeCheckpoint(id) {
  checkpoints = checkpoints.filter((c) => c.id !== id);
  renderCheckpoints();
  renderMapCheckpoints();
}

// Pull edited name/radius values out of the list inputs into the data model.
function syncCheckpointsFromInputs() {
  checkpoints.forEach((cp) => {
    const nameInput = document.querySelector(`[data-name="${cp.id}"]`);
    const radiusInput = document.querySelector(`[data-radius="${cp.id}"]`);
    if (nameInput) cp.name = nameInput.value.trim() || cp.name;
    if (radiusInput) {
      const r = Number(radiusInput.value);
      if (Number.isFinite(r) && r > 0) cp.radiusMeters = r;
    }
  });
}

function renderCheckpoints() {
  const list = el('cpList');
  list.innerHTML = '';

  if (checkpoints.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'cp-empty';
    empty.textContent = 'No checkpoints yet — tap the map to add one.';
    list.appendChild(empty);
    return;
  }

  checkpoints.forEach((cp) => {
    const row = document.createElement('div');
    row.className = 'cp-item';

    const name = document.createElement('input');
    name.type = 'text';
    name.value = cp.name;
    name.setAttribute('data-name', cp.id);
    name.addEventListener('change', () => {
      cp.name = name.value.trim() || cp.name;
    });

    const radiusWrap = document.createElement('div');
    radiusWrap.className = 'cp-radius-wrap';
    const radius = document.createElement('input');
    radius.type = 'number';
    radius.min = '10';
    radius.max = '2000';
    radius.value = cp.radiusMeters;
    radius.setAttribute('data-radius', cp.id);
    radius.addEventListener('change', () => {
      const r = Number(radius.value);
      if (Number.isFinite(r) && r > 0) {
        cp.radiusMeters = r;
        renderMapCheckpoints();
      }
    });
    radiusWrap.appendChild(radius);
    const m = document.createElement('span');
    m.textContent = 'm';
    radiusWrap.appendChild(m);

    const del = document.createElement('button');
    del.className = 'cp-del';
    del.type = 'button';
    del.textContent = '🗑';
    del.title = 'Remove checkpoint';
    del.addEventListener('click', () => removeCheckpoint(cp.id));

    row.appendChild(name);
    row.appendChild(radiusWrap);
    row.appendChild(del);
    list.appendChild(row);
  });
}

/* ---------- map ---------- */
function initMap() {
  const center = checkpoints.length ? [checkpoints[0].lat, checkpoints[0].lng] : DEFAULT_CENTER;
  map = L.map('map').setView(center, checkpoints.length ? 16 : 12);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '© OpenStreetMap',
  }).addTo(map);

  map.on('click', (event) => {
    addCheckpoint(event.latlng.lat, event.latlng.lng);
  });

  renderMapCheckpoints();
  if (checkpoints.length > 1) {
    map.fitBounds(checkpoints.map((c) => [c.lat, c.lng]), { padding: [40, 40] });
  }
}

function renderMapCheckpoints() {
  if (!map) return;
  markerLayers.forEach(({ marker, circle }) => {
    map.removeLayer(marker);
    map.removeLayer(circle);
  });
  markerLayers.clear();

  checkpoints.forEach((cp) => {
    const marker = L.marker([cp.lat, cp.lng], { draggable: true }).addTo(map);
    marker.bindTooltip(cp.name, { permanent: false });
    const circle = L.circle([cp.lat, cp.lng], {
      radius: cp.radiusMeters,
      color: '#128c7e',
      fillColor: '#128c7e',
      fillOpacity: 0.12,
    }).addTo(map);

    marker.on('dragend', () => {
      const pos = marker.getLatLng();
      cp.lat = Number(pos.lat.toFixed(6));
      cp.lng = Number(pos.lng.toFixed(6));
      circle.setLatLng(pos);
    });

    markerLayers.set(cp.id, { marker, circle });
  });
}

/* ---------- live patrol ---------- */
function startPatrol() {
  if (!('geolocation' in navigator)) {
    toast('This device/browser has no GPS support.', 'err');
    return;
  }
  if (!window.isSecureContext) {
    toast('GPS on iPhone needs HTTPS. Open this through a secure tunnel or hosted domain.', 'err');
    return;
  }
  if (checkpoints.length === 0) {
    toast('Add at least one checkpoint first.', 'err');
    return;
  }

  armed.clear();
  checkpoints.forEach((cp) => armed.set(cp.id, true)); // start armed so first arrival fires

  el('startPatrol').hidden = true;
  el('stopPatrol').hidden = false;
  el('livePanel').classList.add('on');
  el('liveStatus').textContent = 'Tracking…';

  watchId = navigator.geolocation.watchPosition(onPosition, onPositionError, {
    enableHighAccuracy: true,
    maximumAge: 5000,
    timeout: 20000,
  });
}

function stopPatrol() {
  if (watchId !== null) {
    navigator.geolocation.clearWatch(watchId);
    watchId = null;
  }
  el('startPatrol').hidden = false;
  el('stopPatrol').hidden = true;
  el('livePanel').classList.remove('on');
  el('liveStatus').textContent = 'Idle';
  if (meMarker) {
    map.removeLayer(meMarker);
    meMarker = null;
  }
}

function onPositionError(error) {
  el('liveStatus').textContent = 'GPS error';
  toast(`GPS error: ${error.message}`, 'err');
}

function onPosition(position) {
  const { latitude, longitude, accuracy } = position.coords;
  el('liveAccuracy').textContent = `±${Math.round(accuracy)} m`;

  if (!meMarker) {
    meMarker = L.circleMarker([latitude, longitude], {
      radius: 7,
      color: '#0c6157',
      fillColor: '#25d366',
      fillOpacity: 1,
    }).addTo(map);
  } else {
    meMarker.setLatLng([latitude, longitude]);
  }

  let nearest = null;
  let nearestDist = Infinity;

  checkpoints.forEach((cp) => {
    const dist = distanceMeters(latitude, longitude, cp.lat, cp.lng);
    if (dist < nearestDist) {
      nearestDist = dist;
      nearest = cp;
    }

    // Re-arm once the phone has clearly left the zone (hysteresis avoids
    // re-firing while hovering on the boundary).
    if (dist > cp.radiusMeters + RE_ARM_MARGIN) {
      armed.set(cp.id, true);
    }

    if (dist <= cp.radiusMeters && armed.get(cp.id)) {
      armed.set(cp.id, false);
      fireTrigger(cp);
    }
  });

  if (nearest) {
    el('liveNearest').textContent = nearest.name;
    el('liveDistance').textContent = `${Math.round(nearestDist)} m`;
  }
}

async function fireTrigger(checkpoint) {
  el('liveStatus').textContent = `Reached ${checkpoint.name} — sending…`;
  savePatrolTokenInput();
  try {
    const response = await fetchWithAccountAuth(`/api/patrol/trigger?${patrolTriggerQuery()}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: 'patrol-gps', checkpointName: checkpoint.name }),
    });
    const data = await response.json();
    if (data.ok) {
      el('liveStatus').textContent = `Sent at ${checkpoint.name} ✓`;
      toast(`Message sent to "${data.chatName}" at ${checkpoint.name}.`, 'ok');
    } else {
      el('liveStatus').textContent = 'Tracking…';
      toast(`Not sent at ${checkpoint.name}: ${data.reason || data.error}`, 'err');
    }
  } catch (error) {
    el('liveStatus').textContent = 'Tracking…';
    toast(`Trigger failed: ${error.message}`, 'err');
  }
}

async function testTrigger() {
  savePatrolTokenInput();
  try {
    const response = await fetchWithAccountAuth(`/api/patrol/trigger?${patrolTriggerQuery('dryRun=1')}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: 'patrol-test' }),
    });
    const data = await response.json();
    if (data.ok) {
      toast(`Dry run OK — would send to "${data.chatName}". No message sent.`, 'ok');
    } else {
      toast(`Would be blocked: ${data.reason || data.error}`, 'err');
    }
  } catch (error) {
    toast(`Test failed: ${error.message}`, 'err');
  }
}

/* ---------- location helpers ---------- */
function dropAtMyLocation() {
  if (!('geolocation' in navigator)) {
    toast('No GPS support on this device.', 'err');
    return;
  }
  navigator.geolocation.getCurrentPosition(
    (position) => {
      const { latitude, longitude } = position.coords;
      addCheckpoint(latitude, longitude);
      map.setView([latitude, longitude], 17);
    },
    (error) => toast(`Could not get location: ${error.message}`, 'err'),
    { enableHighAccuracy: true, timeout: 15000 }
  );
}

function recenter() {
  if (checkpoints.length) {
    if (checkpoints.length === 1) {
      map.setView([checkpoints[0].lat, checkpoints[0].lng], 16);
    } else {
      map.fitBounds(checkpoints.map((c) => [c.lat, c.lng]), { padding: [40, 40] });
    }
  }
}

/* ---------- init ---------- */
async function switchAccount(accountId) {
  stopPatrol();
  const previousAccountId = currentAccountId;
  currentAccountId = accountId;
  localStorage.setItem('currentAccountId', accountId);
  loadPatrolTokenInput();
  const unlocked = await ensureAccountAccess(accountId);
  if (!unlocked) {
    currentAccountId = previousAccountId;
    localStorage.setItem('currentAccountId', previousAccountId);
    el('accountSelect').value = previousAccountId;
    loadPatrolTokenInput();
    return;
  }
  await loadConfig();
  renderCheckpoints();
  renderMapCheckpoints();
  recenter();
  refreshConnection();
}

async function init() {
  await loadAccounts();
  loadPatrolTokenInput();
  initMap();
  el('secureContextWarning').hidden = window.isSecureContext;

  el('accountSelect').addEventListener('change', (e) => switchAccount(e.target.value));
  el('patrolToken').addEventListener('change', savePatrolTokenInput);
  el('saveCheckpoints').addEventListener('click', saveCheckpoints);
  el('startPatrol').addEventListener('click', startPatrol);
  el('stopPatrol').addEventListener('click', stopPatrol);
  el('testTrigger').addEventListener('click', testTrigger);
  el('useMyLocation').addEventListener('click', dropAtMyLocation);
  el('recenter').addEventListener('click', recenter);

  const unlocked = await ensureAccountAccess(currentAccountId);
  if (!unlocked) {
    toast('Account locked. Select an account and enter its password to continue.', 'err');
    return;
  }
  await loadConfig();
  renderCheckpoints();
  refreshConnection();
  setInterval(refreshConnection, 10000);
}

init();
