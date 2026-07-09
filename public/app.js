const days = [
  { value: 0, label: 'Sunday' },
  { value: 1, label: 'Monday' },
  { value: 2, label: 'Tuesday' },
  { value: 3, label: 'Wednesday' },
  { value: 4, label: 'Thursday' },
  { value: 5, label: 'Friday' },
  { value: 6, label: 'Saturday' },
];

const form = document.querySelector('#settingsForm');
const loginScreen = document.querySelector('#loginScreen');
const appShell = document.querySelector('#appShell');
const dayGrid = document.querySelector('#dayGrid');
const currentWeekGrid = document.querySelector('#currentWeekGrid');
const previewList = document.querySelector('#previewList');
const schedulerLogList = document.querySelector('#schedulerLogList');
const saveStatus = document.querySelector('#saveStatus');
const saveSettingsButton = document.querySelector('#saveSettingsButton');
const loginStatus = document.querySelector('#loginStatus');
const whatsappStatus = document.querySelector('#whatsappStatus');
const qrCode = document.querySelector('#qrCode');
const logoutWhatsapp = document.querySelector('#logoutWhatsapp');
const chatCombo = document.querySelector('#chatCombo');
const chatComboInput = document.querySelector('#chatComboInput');
const chatComboMenu = document.querySelector('#chatComboMenu');
const dayShiftTime = document.querySelector('#dayShiftTime');
const nightShiftTime = document.querySelector('#nightShiftTime');
const extraShiftDateInput = document.querySelector('#extraShiftDateInput');
const addExtraDate = document.querySelector('#addExtraDate');
const extraDateList = document.querySelector('#extraDateList');
let extraShiftDates = [];
let whatsappPollTimer;
let availableChats = [];
let currentConfig;
let autoSaveTimer;

days.forEach((day) => {
  const label = document.createElement('label');
  label.className = 'day-toggle';
  label.innerHTML = `<input type="checkbox" name="activeShiftDays" value="${day.value}" />${day.label}`;
  dayGrid.append(label);
});

function startOfCurrentWeek() {
  const today = new Date();
  const day = today.getDay();
  const daysSinceMonday = day === 0 ? 6 : day - 1;
  const monday = new Date(today);
  monday.setHours(0, 0, 0, 0);
  monday.setDate(today.getDate() - daysSinceMonday);
  return monday;
}

function addDays(date, daysToAdd) {
  const nextDate = new Date(date);
  nextDate.setDate(date.getDate() + daysToAdd);
  return nextDate;
}

function dateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function renderCurrentWeekGrid() {
  const monday = startOfCurrentWeek();
  const weeklyDays = new Set(
    [...form.querySelectorAll('[name="activeShiftDays"]:checked')].map((input) => Number(input.value))
  );
  currentWeekGrid.innerHTML = '';

  for (let index = 0; index < 7; index += 1) {
    const date = addDays(monday, index);
    const key = dateKey(date);
    const dayNumber = date.getDay();
    const isWeekly = weeklyDays.has(dayNumber);
    const isExtra = extraShiftDates.includes(key);
    const button = document.createElement('button');
    button.className = 'week-toggle';
    button.type = 'button';
    button.dataset.date = key;
    button.disabled = isWeekly;
    button.setAttribute('aria-pressed', String(isWeekly || isExtra));
    button.innerHTML = `
      <span>${date.toLocaleDateString('en-US', { weekday: 'short' })}</span>
      <strong>${date.toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}</strong>
      <small>${isWeekly ? 'Weekly' : isExtra ? 'Extra' : 'Off'}</small>
    `;
    currentWeekGrid.append(button);
  }
}

function formatHourLabel(hour) {
  const suffix = hour >= 12 ? 'PM' : 'AM';
  const hour12 = hour % 12 || 12;
  return `${hour12}:00 ${suffix}`;
}

function formatMinuteOffset(minutes) {
  return `${minutes} minutes after start`;
}

function formatInterval(minutes) {
  const hours = Math.floor(minutes / 60);
  const remainingMinutes = minutes % 60;
  const parts = [];

  if (hours) {
    parts.push(`${hours} hour${hours === 1 ? '' : 's'}`);
  }

  if (remainingMinutes) {
    parts.push(`${remainingMinutes} minute${remainingMinutes === 1 ? '' : 's'}`);
  }

  return parts.join(' ') || '0 minutes';
}

function appendOption(select, value, label) {
  const option = document.createElement('option');
  option.value = String(value);
  option.textContent = label;
  select.append(option);
}

function populateHumanControls() {
  for (let hour = 0; hour < 24; hour += 1) {
    appendOption(form.shiftStartHour, hour, formatHourLabel(hour));
    appendOption(form.shiftEndHour, hour, formatHourLabel(hour));
  }

  for (let minute = 0; minute <= 59; minute += 1) {
    appendOption(form.firstSendMinuteMin, minute, formatMinuteOffset(minute));
    appendOption(form.firstSendMinuteMax, minute, formatMinuteOffset(minute));
  }

  for (let minute = 30; minute <= 180; minute += 5) {
    appendOption(form.minSendIntervalMinutes, minute, formatInterval(minute));
    appendOption(form.maxSendIntervalMinutes, minute, formatInterval(minute));
  }
}

populateHumanControls();

function setStatus(message, type = '') {
  saveStatus.textContent = message;
  saveStatus.className = type ? `status-message ${type}` : 'status-message';
}

function formatHumanDate(dateKey) {
  const [year, month, day] = dateKey.split('-').map(Number);
  const date = new Date(year, month - 1, day);

  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
  });
}

function renderExtraDates() {
  extraDateList.innerHTML = '';
  renderCurrentWeekGrid();

  if (extraShiftDates.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'date-item';
    empty.innerHTML = '<span>No one-time extra shifts</span>';
    extraDateList.append(empty);
    return;
  }

  extraShiftDates.forEach((dateKey) => {
    const row = document.createElement('div');
    row.className = 'date-item';
    row.innerHTML = `
      <span>${formatHumanDate(dateKey)}</span>
      <button class="date-remove" type="button" data-date="${dateKey}">Remove</button>
    `;
    extraDateList.append(row);
  });
}

function rankChats(chats, keyword) {
  const search = keyword.trim().toLowerCase();

  if (!search) {
    return chats;
  }

  return [...chats].sort((a, b) => {
    const aName = a.name.toLowerCase();
    const bName = b.name.toLowerCase();
    const aStarts = aName.startsWith(search);
    const bStarts = bName.startsWith(search);
    const aIncludes = aName.includes(search);
    const bIncludes = bName.includes(search);

    if (aStarts !== bStarts) return aStarts ? -1 : 1;
    if (aIncludes !== bIncludes) return aIncludes ? -1 : 1;
    if (a.isGroup !== b.isGroup) return a.isGroup ? -1 : 1;
    return a.name.localeCompare(b.name);
  });
}

function chatTypeLabel(chat) {
  return chat.isGroup ? 'Group' : 'Chat';
}

function openChatMenu() {
  chatComboMenu.hidden = false;
}

function closeChatMenu() {
  chatComboMenu.hidden = true;
}

function selectChat(chatName) {
  form.groupName.value = chatName;
  chatComboInput.value = chatName;
  closeChatMenu();
}

function renderChatOptions(chats = availableChats, selectedName = form.groupName.value) {
  availableChats = chats;
  const selectedValue = selectedName || form.groupName.value;
  const rankedChats = rankChats(availableChats, chatComboInput.value).slice(0, 30);
  chatComboMenu.innerHTML = '';

  if (selectedValue && chatComboInput.value !== selectedValue && !chatComboInput.matches(':focus')) {
    chatComboInput.value = selectedValue;
  }

  if (rankedChats.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'combo-empty';
    empty.textContent = availableChats.length ? 'No matching chats' : 'Connect WhatsApp to load chats';
    chatComboMenu.append(empty);
    return;
  }

  rankedChats.forEach((chat) => {
    const button = document.createElement('button');
    button.className = 'combo-option';
    button.type = 'button';
    button.dataset.name = chat.name;
    button.innerHTML = `
      <span>${chat.name}</span>
      <small>${chatTypeLabel(chat)}</small>
    `;
    chatComboMenu.append(button);
  });
}

function showLogin(payload) {
  loginScreen.hidden = false;
  appShell.hidden = true;

  if (payload.status === 'qr' && payload.qrDataUrl) {
    loginStatus.textContent = 'Scan this QR code in WhatsApp to continue.';
    qrCode.src = payload.qrDataUrl;
    qrCode.hidden = false;
    return;
  }

  qrCode.hidden = true;
  qrCode.removeAttribute('src');

  if (payload.error) {
    loginStatus.textContent = `${payload.status}: ${payload.error}`;
    return;
  }

  loginStatus.textContent = `WhatsApp status: ${payload.status}`;
}

function showApp(payload) {
  loginScreen.hidden = true;
  appShell.hidden = false;
  whatsappStatus.textContent = 'Connected. Groups and chats are loaded.';
  availableChats = payload.chats || [];
  renderChatOptions(payload.chats || [], form.groupName.value);
}

function fillForm(config) {
  currentConfig = config;
  form.groupName.value = config.groupName;
  chatComboInput.value = config.groupName;
  renderChatOptions(availableChats, config.groupName);
  form.timezone.value = config.timezone;
  form.message.value = config.message;
  form.shiftStartHour.value = config.schedule.shiftStartHour;
  form.shiftEndHour.value = config.schedule.shiftEndHour;
  setShiftTypeFromHours(config.schedule.shiftStartHour, config.schedule.shiftEndHour);
  form.firstSendMinuteMin.value = config.schedule.firstSendMinuteMin;
  form.firstSendMinuteMax.value = config.schedule.firstSendMinuteMax;
  form.minSendIntervalMinutes.value = config.schedule.minSendIntervalMinutes;
  form.maxSendIntervalMinutes.value = config.schedule.maxSendIntervalMinutes;
  extraShiftDates = [...config.schedule.extraShiftDates];
  renderExtraDates();

  const activeDays = new Set(config.schedule.activeShiftDays.map(String));
  form.querySelectorAll('[name="activeShiftDays"]').forEach((input) => {
    input.checked = activeDays.has(input.value);
  });
  renderCurrentWeekGrid();
}

function setShiftTypeFromHours(startHour, endHour) {
  const start = Number(startHour);
  const end = Number(endHour);
  const shiftType = end > start ? 'day' : 'night';

  form.querySelectorAll('[name="shiftType"]').forEach((input) => {
    input.checked = input.value === shiftType;
  });

  updateShiftTypeLabels();
}

function applyShiftType(shiftType) {
  if (shiftType === 'day') {
    form.shiftStartHour.value = '8';
    form.shiftEndHour.value = '20';
  }

  if (shiftType === 'night') {
    form.shiftStartHour.value = '20';
      form.shiftEndHour.value = '8';
  }

  updateShiftTypeLabels();
}

function updateShiftTypeLabels() {
  const startLabel = formatHourLabel(Number(form.shiftStartHour.value));
  const endLabel = formatHourLabel(Number(form.shiftEndHour.value));
  const selectedShiftType = form.querySelector('[name="shiftType"]:checked')?.value;

  dayShiftTime.textContent = selectedShiftType === 'day' ? `${startLabel} to ${endLabel}` : '8:00 AM to 8:00 PM';
  nightShiftTime.textContent =
    selectedShiftType === 'night' ? `${startLabel} to ${endLabel}` : '8:00 PM to 8:00 AM';
}

function readForm() {
  const activeShiftDays = [...form.querySelectorAll('[name="activeShiftDays"]:checked')].map((input) =>
    Number(input.value)
  );
  const exactChatMatch = availableChats.find(
    (chat) => chat.name.toLowerCase() === chatComboInput.value.trim().toLowerCase()
  );
  const groupName = form.groupName.value.trim() || (exactChatMatch ? exactChatMatch.name : chatComboInput.value.trim());

  return {
    groupName,
    timezone: form.timezone.value.trim(),
    message: form.message.value.trim(),
    schedule: {
      activeShiftDays,
      extraShiftDates,
      shiftStartHour: Number(form.shiftStartHour.value),
      shiftEndHour: Number(form.shiftEndHour.value),
      firstSendMinuteMin: Number(form.firstSendMinuteMin.value),
      firstSendMinuteMax: Number(form.firstSendMinuteMax.value),
      minSendIntervalMinutes: Number(form.minSendIntervalMinutes.value),
      maxSendIntervalMinutes: Number(form.maxSendIntervalMinutes.value),
    },
  };
}

function renderPreview(preview) {
  previewList.innerHTML = '';

  if (preview.length === 0) {
    previewList.textContent = 'No scheduled messages in the preview window.';
    return;
  }

  const upcoming = preview.filter((item) => item.status === 'upcoming');
  const past = preview.filter((item) => item.status === 'past');
  const next = upcoming[0];

  if (next) {
    const nextCard = document.createElement('section');
    nextCard.className = 'next-card';
    nextCard.innerHTML = `
      <span>Next message</span>
      <time datetime="${next.iso}">${next.label}</time>
    `;
    previewList.append(nextCard);
  }

  renderShiftGroups('Upcoming shifts', upcoming, false);
  renderShiftGroups('Past shifts', past, true);
}

function renderSchedulerLogs(logs) {
  schedulerLogList.innerHTML = '';

  if (logs.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'log-empty';
    empty.textContent = 'No scheduler activity yet.';
    schedulerLogList.append(empty);
    return;
  }

  logs.slice(0, 25).forEach((log) => {
    const row = document.createElement('div');
    row.className = `log-item ${log.type}`;
    row.innerHTML = `
      <span class="log-dot"></span>
      <div>
        <strong>${log.message}</strong>
        <time datetime="${log.timestamp}">${log.label}</time>
        ${log.details?.messageId ? `<small>Message ID: ${log.details.messageId}</small>` : ''}
      </div>
    `;
    schedulerLogList.append(row);
  });
}

async function loadSchedulerLogs() {
  const response = await fetch(`/api/logs?t=${Date.now()}`, { cache: 'no-store' });
  const payload = await response.json();

  if (!response.ok) {
    throw new Error(payload.error || 'Unable to load scheduler logs.');
  }

  renderSchedulerLogs(payload.logs || []);
}

function formatTime(iso) {
  return new Date(iso).toLocaleTimeString('en-US', {
    hour: 'numeric',
    minute: '2-digit',
  });
}

function formatShiftTitle(iso) {
  return new Date(iso).toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    year: 'numeric',
  });
}

function formatShiftRangeTitle(shiftStartIso) {
  const shiftStart = new Date(shiftStartIso);
  const shiftEnd = new Date(shiftStart);
  const crossesMidnight =
    Number(currentConfig?.schedule?.shiftEndHour ?? 8) <= Number(currentConfig?.schedule?.shiftStartHour ?? 20);

  if (!crossesMidnight) {
    return formatShiftTitle(shiftStartIso);
  }

  shiftEnd.setDate(shiftEnd.getDate() + 1);

  return `${shiftStart.toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  })} night shift into ${shiftEnd.toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
    year: 'numeric',
  })}`;
}

function formatShiftTime(iso, shiftStartIso) {
  const sendAt = new Date(iso);
  const shiftStart = new Date(shiftStartIso);
  const time = formatTime(iso);

  if (sendAt.toDateString() === shiftStart.toDateString()) {
    return time;
  }

  return `${sendAt.toLocaleDateString('en-US', { weekday: 'short' })} ${time}`;
}

function groupByShift(items) {
  const groupsByKey = new Map();
  const shiftEndHour = Number(currentConfig?.schedule?.shiftEndHour ?? 8);
  const crossesMidnight =
    Number(currentConfig?.schedule?.shiftEndHour ?? 8) <= Number(currentConfig?.schedule?.shiftStartHour ?? 20);

  items.forEach((item) => {
    const sendAt = new Date(item.iso);
    const shiftDate = new Date(sendAt);

    if (crossesMidnight && sendAt.getHours() < shiftEndHour) {
      shiftDate.setDate(shiftDate.getDate() - 1);
    }

    shiftDate.setHours(0, 0, 0, 0);
    const key = shiftDate.toISOString();

    if (!groupsByKey.has(key)) {
      groupsByKey.set(key, {
        title: formatShiftRangeTitle(key),
        shiftStartIso: key,
        items: [],
      });
    }

    groupsByKey.get(key).items.push(item);
  });

  return [...groupsByKey.values()];
}

function renderShiftGroups(title, items, collapsed) {
  if (items.length === 0) return;

  const section = document.createElement('section');
  section.className = 'shift-section';
  const contentId = `shift-${title.toLowerCase().replace(/\s+/g, '-')}`;
  section.innerHTML = `
    <button class="shift-toggle" type="button" aria-expanded="${String(!collapsed)}" aria-controls="${contentId}">
      <span>${title}</span>
      <small>${items.length} messages</small>
    </button>
    <div class="shift-content" id="${contentId}" ${collapsed ? 'hidden' : ''}></div>
  `;
  const toggle = section.querySelector('.shift-toggle');
  const content = section.querySelector('.shift-content');

  toggle.addEventListener('click', () => {
    const isExpanded = toggle.getAttribute('aria-expanded') === 'true';
    toggle.setAttribute('aria-expanded', String(!isExpanded));
    content.hidden = isExpanded;
  });

  groupByShift(items).forEach((group) => {
    const shift = document.createElement('section');
    shift.className = 'shift-group';
    const first = group.items[0];
    const last = group.items[group.items.length - 1];
    shift.innerHTML = `
      <div class="shift-heading">
        <h3>${group.title}</h3>
        <p>${group.items.length} messages · ${formatTime(first.iso)} to ${formatTime(last.iso)}</p>
      </div>
      <div class="time-grid"></div>
    `;
    const timeGrid = shift.querySelector('.time-grid');

    group.items.forEach((item) => {
      const time = document.createElement('time');
      time.dateTime = item.iso;
      time.textContent = formatShiftTime(item.iso, group.shiftStartIso);
      timeGrid.append(time);
    });

    content.append(shift);
  });

  previewList.append(section);
}

async function loadWhatsappState() {
  const response = await fetch(`/api/whatsapp?t=${Date.now()}`, { cache: 'no-store' });
  const payload = await response.json();

  if (!response.ok) {
    const message = payload.error || 'Unable to load WhatsApp status.';

    if (appShell.hidden) {
      loginStatus.textContent = message;
    } else {
      whatsappStatus.textContent = message;
    }

    return;
  }

  if (payload.status === 'ready') {
    showApp(payload);
    return;
  }

  showLogin(payload);
}

function scheduleWhatsappPoll(delay = 1000) {
  clearTimeout(whatsappPollTimer);
  whatsappPollTimer = setTimeout(async () => {
    try {
      await loadWhatsappState();
      scheduleWhatsappPoll(appShell.hidden ? 1000 : 5000);
    } catch (error) {
      if (appShell.hidden) {
        loginStatus.textContent = error.message;
      } else {
        whatsappStatus.textContent = error.message;
      }

      scheduleWhatsappPoll(2000);
    }
  }, delay);
}

async function logoutWhatsappSession() {
  logoutWhatsapp.disabled = true;
  whatsappStatus.textContent = 'Logging out and restarting WhatsApp session...';
  loginStatus.textContent = 'Logging out and restarting WhatsApp session...';
  loginScreen.hidden = false;
  appShell.hidden = true;
  qrCode.hidden = true;
  qrCode.removeAttribute('src');
  renderChatOptions([], form.groupName.value);

  const response = await fetch('/api/whatsapp/logout', { method: 'POST' });
  const payload = await response.json();

  if (!response.ok) {
    whatsappStatus.textContent = payload.error || 'Logout failed.';
    logoutWhatsapp.disabled = false;
    return;
  }

  whatsappStatus.textContent = 'Session logged out. Waiting for a new QR code...';
  await loadWhatsappState();
  logoutWhatsapp.disabled = false;
}

async function loadSettings() {
  const response = await fetch('/api/config');
  const payload = await response.json();

  if (!response.ok) {
    throw new Error(payload.error || 'Unable to load settings.');
  }

  fillForm(payload.config);
  renderPreview(payload.preview);
  setStatus('Settings loaded');
  await loadWhatsappState();
  await loadSchedulerLogs();
}

async function saveSettings({ showConfirmation = false } = {}) {
  setStatus('Saving...');
  saveSettingsButton.disabled = true;
  const originalButtonText = saveSettingsButton.textContent;
  saveSettingsButton.textContent = 'Saving...';

  try {
    const response = await fetch('/api/config', {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ config: readForm() }),
    });
    const payload = await response.json();

    if (!response.ok) {
      setStatus(payload.error || 'Save failed', 'error');
      saveSettingsButton.textContent = originalButtonText;
      return;
    }

    fillForm(payload.config);
    renderPreview(payload.preview);

    if (showConfirmation) {
      setStatus('Settings saved successfully', 'success');
      saveSettingsButton.textContent = 'Saved';
      setTimeout(() => {
        if (saveStatus.textContent === 'Settings saved successfully') {
          setStatus('');
        }

        saveSettingsButton.textContent = originalButtonText;
      }, 3000);
      return;
    }

    setStatus('');
  } finally {
    saveSettingsButton.disabled = false;

    if (!showConfirmation || saveSettingsButton.textContent === 'Saving...') {
      saveSettingsButton.textContent = originalButtonText;
    }
  }
}

function queueAutoSave() {
  clearTimeout(autoSaveTimer);
  setStatus('Saving...');
  autoSaveTimer = setTimeout(() => {
    saveSettings().catch((error) => {
      setStatus(error.message);
    });
  }, 250);
}

addExtraDate.addEventListener('click', () => {
  const dateKey = extraShiftDateInput.value;

  if (!dateKey || extraShiftDates.includes(dateKey)) {
    return;
  }

  extraShiftDates = [...extraShiftDates, dateKey].sort();
  extraShiftDateInput.value = '';
  renderExtraDates();
  queueAutoSave();
});

extraDateList.addEventListener('click', (event) => {
  const button = event.target.closest('[data-date]');

  if (!button) return;

  extraShiftDates = extraShiftDates.filter((dateKey) => dateKey !== button.dataset.date);
  renderExtraDates();
  queueAutoSave();
});

currentWeekGrid.addEventListener('click', (event) => {
  const button = event.target.closest('[data-date]');

  if (!button || button.disabled) return;

  const key = button.dataset.date;

  if (extraShiftDates.includes(key)) {
    extraShiftDates = extraShiftDates.filter((date) => date !== key);
  } else {
    extraShiftDates = [...extraShiftDates, key].sort();
  }

  renderExtraDates();
  queueAutoSave();
});

dayGrid.addEventListener('change', () => {
  renderCurrentWeekGrid();
  queueAutoSave();
});

form.querySelectorAll('[name="shiftType"]').forEach((input) => {
  input.addEventListener('change', () => {
    applyShiftType(input.value);
    queueAutoSave();
  });
});

form.shiftStartHour.addEventListener('change', () => {
  setShiftTypeFromHours(form.shiftStartHour.value, form.shiftEndHour.value);
  queueAutoSave();
});

form.shiftEndHour.addEventListener('change', () => {
  setShiftTypeFromHours(form.shiftStartHour.value, form.shiftEndHour.value);
  queueAutoSave();
});

chatComboInput.addEventListener('input', () => {
  form.groupName.value = '';
  openChatMenu();
  renderChatOptions(availableChats, form.groupName.value);
});

chatComboInput.addEventListener('focus', () => {
  openChatMenu();
  renderChatOptions(availableChats, form.groupName.value);
});

chatComboMenu.addEventListener('click', (event) => {
  const option = event.target.closest('[data-name]');

  if (!option) return;

  selectChat(option.dataset.name);
});

document.addEventListener('click', (event) => {
  if (!chatCombo.contains(event.target)) {
    closeChatMenu();
  }
});

logoutWhatsapp.addEventListener('click', () => {
  logoutWhatsappSession().catch((error) => {
    whatsappStatus.textContent = error.message;
    logoutWhatsapp.disabled = false;
  });
});

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  saveSettings({ showConfirmation: true }).catch((error) => {
    setStatus(error.message);
  });
});

loadSettings().catch((error) => {
  setStatus(error.message);
});

scheduleWhatsappPoll();
setInterval(() => {
  loadSchedulerLogs().catch(() => {});
}, 5000);
