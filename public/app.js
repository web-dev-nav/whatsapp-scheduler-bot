'use strict';

const days = [
  { value: 0, short: 'Sun', label: 'Sunday' },
  { value: 1, short: 'Mon', label: 'Monday' },
  { value: 2, short: 'Tue', label: 'Tuesday' },
  { value: 3, short: 'Wed', label: 'Wednesday' },
  { value: 4, short: 'Thu', label: 'Thursday' },
  { value: 5, short: 'Fri', label: 'Friday' },
  { value: 6, short: 'Sat', label: 'Saturday' },
];

const el = (id) => document.getElementById(id);

// --- Views ---
const loginScreen = el('loginScreen');
const appShell = el('appShell');
const dashboard = el('dashboard');
const wizard = el('wizard');

// --- Login ---
const loginStatus = el('loginStatus');
const qrCode = el('qrCode');
const scanSteps = el('scanSteps');
const loginAccountSelect = el('loginAccountSelect');
const loginAccountForm = el('loginAccountForm');
const loginAccountName = el('loginAccountName');

// --- Header / account menu ---
const accountMenuButton = el('accountMenuButton');
const accountMenu = el('accountMenu');
const accountChipName = el('accountChipName');
const connectionDot = el('connectionDot');
const whatsappStatus = el('whatsappStatus');
const accountSelect = el('accountSelect');
const accountForm = el('accountForm');
const accountName = el('accountName');
const logoutWhatsapp = el('logoutWhatsapp');

// --- Dashboard ---
const summaryBadge = el('summaryBadge');
const summaryText = el('summaryText');
const dashEnableToggle = el('dashEnableToggle');
const autosendTitle = el('autosendTitle');
const autosendHint = el('autosendHint');
const nextSendCard = el('nextSendCard');
const nextSendTime = el('nextSendTime');
const editSetupButton = el('editSetupButton');
const previewList = el('previewList');
const schedulerLogList = el('schedulerLogList');

// --- Wizard ---
const wizardClose = el('wizardClose');
const wizardProgress = el('wizardProgress');
const wizardStepLabel = el('wizardStepLabel');
const wizardBack = el('wizardBack');
const wizardNext = el('wizardNext');
const wizardFinish = el('wizardFinish');
const saveStatus = el('saveStatus');
const wizardSteps = [...wizard.querySelectorAll('.wizard-step')].sort(
  (a, b) => Number(a.dataset.step) - Number(b.dataset.step)
);

// Step controls
const chatCombo = el('chatCombo');
const chatComboInput = el('chatComboInput');
const groupNameInput = el('groupName');
const chatComboMenu = el('chatComboMenu');
const chatHint = el('chatHint');
const dayGrid = el('dayGrid');
const currentWeekGrid = el('currentWeekGrid');
const extraShiftDateInput = el('extraShiftDateInput');
const addExtraDate = el('addExtraDate');
const extraDateList = el('extraDateList');
const dayShiftTime = el('dayShiftTime');
const nightShiftTime = el('nightShiftTime');
const message = el('message');
const reviewSummary = el('reviewSummary');
const wizardEnableToggle = el('wizardEnableToggle');
const timezone = el('timezone');
const shiftStartHour = el('shiftStartHour');
const shiftEndHour = el('shiftEndHour');
const firstSendAfter = el('firstSendAfter');
const sendEvery = el('sendEvery');
const timingPreview = el('timingPreview');

// The server stores randomized windows (firstSendMinuteMin/Max, min/maxSendIntervalMinutes)
// so messages look human. The UI exposes a single friendly value per concept and we
// expand it into a small window on save / collapse it back to the midpoint on load.
const FIRST_SEND_JITTER = 5; // minutes ± around the chosen "first message" time
const GAP_JITTER = 10; // minutes ± around the chosen "time between messages"

// --- State ---
let extraShiftDates = [];
let autoSendEnabled = true;
let availableChats = [];
let currentConfig;
let lastPreview = [];
let whatsappPollTimer;
let accounts = [];
let currentAccountId = localStorage.getItem('currentAccountId') || 'main';
let viewInitialized = false;
let isConnected = false;
let currentStep = 0;
let lastWhatsappError = null;

// ---------- Build day toggles ----------
days.forEach((day) => {
  const label = document.createElement('label');
  label.className = 'day-toggle';
  label.innerHTML = `<input type="checkbox" name="activeShiftDays" value="${day.value}" />${day.short}`;
  dayGrid.append(label);
});

// ---------- Date helpers ----------
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
  const next = new Date(date);
  next.setDate(date.getDate() + daysToAdd);
  return next;
}

function dateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function formatHumanDate(key) {
  const [year, month, day] = key.split('-').map(Number);
  return new Date(year, month - 1, day).toLocaleDateString('en-US', {
    weekday: 'short',
    month: 'long',
    day: 'numeric',
  });
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
  if (hours) parts.push(`${hours} hour${hours === 1 ? '' : 's'}`);
  if (remainingMinutes) parts.push(`${remainingMinutes} minute${remainingMinutes === 1 ? '' : 's'}`);
  return parts.join(' ') || '0 minutes';
}

function appendOption(select, value, label) {
  const option = document.createElement('option');
  option.value = String(value);
  option.textContent = label;
  select.append(option);
}

function firstSendLabel(minutes) {
  return `About ${minutes} minutes after the shift starts`;
}

function sendEveryLabel(minutes) {
  return `About every ${formatInterval(minutes)}`;
}

function populateHumanControls() {
  for (let hour = 0; hour < 24; hour += 1) {
    appendOption(shiftStartHour, hour, formatHourLabel(hour));
    appendOption(shiftEndHour, hour, formatHourLabel(hour));
  }
  for (let minute = 5; minute <= 45; minute += 5) {
    appendOption(firstSendAfter, minute, firstSendLabel(minute));
  }
  for (let minute = 75; minute <= 180; minute += 15) {
    appendOption(sendEvery, minute, sendEveryLabel(minute));
  }
}

// Make sure a stored value is selectable even if it doesn't line up with a preset
// step (e.g. a config saved before this simplification), inserting it in order.
function ensureSelectValue(select, value, label) {
  if ([...select.options].some((option) => Number(option.value) === value)) {
    select.value = String(value);
    return;
  }
  const option = document.createElement('option');
  option.value = String(value);
  option.textContent = label;
  const afterIndex = [...select.options].findIndex((existing) => Number(existing.value) > value);
  if (afterIndex === -1) select.append(option);
  else select.insertBefore(option, select.options[afterIndex]);
  select.value = String(value);
}

populateHumanControls();

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (ch) => {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
  });
}

function joinList(items) {
  if (items.length <= 1) return items.join('');
  if (items.length === 2) return `${items[0]} & ${items[1]}`;
  return `${items.slice(0, -1).join(', ')} & ${items[items.length - 1]}`;
}

// ---------- Accounts ----------
function accountQuery() {
  return `account=${encodeURIComponent(currentAccountId)}`;
}

function currentAccountName() {
  return accounts.find((account) => account.id === currentAccountId)?.name || currentAccountId;
}

function renderAccountOptions() {
  [accountSelect, loginAccountSelect].forEach((select) => {
    select.innerHTML = '';
    accounts.forEach((account) => {
      const option = document.createElement('option');
      option.value = account.id;
      option.textContent = account.name;
      select.append(option);
    });
    select.value = currentAccountId;
  });
  accountChipName.textContent = currentAccountName();
}

async function loadAccounts() {
  const response = await fetch(`/api/accounts?t=${Date.now()}`, { cache: 'no-store' });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to load accounts.');

  accounts = payload.accounts || [];
  if (!accounts.some((account) => account.id === currentAccountId)) {
    currentAccountId = accounts[0]?.id || 'main';
  }
  localStorage.setItem('currentAccountId', currentAccountId);
  renderAccountOptions();
}

async function addAccount(name) {
  const trimmed = name.trim();
  if (!trimmed) return;

  const response = await fetch('/api/accounts', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: trimmed }),
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to add account.');

  accounts = payload.accounts || accounts;
  currentAccountId = payload.account.id;
  localStorage.setItem('currentAccountId', currentAccountId);
  renderAccountOptions();
  closeAccountMenu();
  await switchToCurrentAccount();
}

async function switchToCurrentAccount() {
  viewInitialized = false;
  isConnected = false;
  availableChats = [];
  renderChatOptions([], groupNameInput.value);
  await loadSettings();
  await loadWhatsappState();
}

async function switchAccount(accountId) {
  if (accountId === currentAccountId) return;
  currentAccountId = accountId;
  localStorage.setItem('currentAccountId', currentAccountId);
  renderAccountOptions();
  closeAccountMenu();
  await switchToCurrentAccount();
}

function openAccountMenu() {
  accountMenu.hidden = false;
  accountMenuButton.setAttribute('aria-expanded', 'true');
}

function closeAccountMenu() {
  accountMenu.hidden = true;
  accountMenuButton.setAttribute('aria-expanded', 'false');
}

// ---------- Chat combo ----------
function rankChats(chats, keyword) {
  const search = keyword.trim().toLowerCase();
  if (!search) return chats;

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

function openChatMenu() {
  chatComboMenu.hidden = false;
}

function closeChatMenu() {
  chatComboMenu.hidden = true;
}

function selectChat(chatName) {
  groupNameInput.value = chatName;
  chatComboInput.value = chatName;
  closeChatMenu();
}

function updateChatHint() {
  if (!chatHint) return;

  if (availableChats.length > 0) {
    chatHint.className = 'chat-hint';
    chatHint.textContent = `${availableChats.length} groups and chats found — search above to pick one.`;
    return;
  }

  if (lastWhatsappError) {
    const saved = groupNameInput.value.trim();
    chatHint.className = 'chat-hint warn';
    chatHint.innerHTML = `⚠️ Your chat list couldn't be loaded from WhatsApp right now. You can still type the <b>exact</b> group name${
      saved ? ` — it's currently set to <b>${escapeHtml(saved)}</b>` : ''
    } and it will be used when sending.`;
    return;
  }

  chatHint.className = 'chat-hint';
  chatHint.textContent = 'Loading your groups and chats…';
}

function renderChatOptions(chats = availableChats, selectedName = groupNameInput.value) {
  availableChats = chats;
  const selectedValue = selectedName || groupNameInput.value;
  const rankedChats = rankChats(availableChats, chatComboInput.value).slice(0, 30);
  chatComboMenu.innerHTML = '';
  updateChatHint();

  if (selectedValue && chatComboInput.value !== selectedValue && !chatComboInput.matches(':focus')) {
    chatComboInput.value = selectedValue;
  }

  if (rankedChats.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'combo-empty';
    empty.textContent = availableChats.length
      ? 'No matching chats'
      : 'Type the exact chat name if the list has not loaded yet';
    chatComboMenu.append(empty);
    return;
  }

  rankedChats.forEach((chat) => {
    const button = document.createElement('button');
    button.className = 'combo-option';
    button.type = 'button';
    button.dataset.name = chat.name;
    button.innerHTML = `<span>${escapeHtml(chat.name)}</span><small>${chat.isGroup ? 'Group' : 'Chat'}</small>`;
    chatComboMenu.append(button);
  });
}

// ---------- Days / extra dates ----------
function checkedDays() {
  return [...dayGrid.querySelectorAll('[name="activeShiftDays"]:checked')].map((input) => Number(input.value));
}

function renderCurrentWeekGrid() {
  const monday = startOfCurrentWeek();
  const weeklyDays = new Set(checkedDays());
  currentWeekGrid.innerHTML = '';

  for (let index = 0; index < 7; index += 1) {
    const date = addDays(monday, index);
    const key = dateKey(date);
    const isWeekly = weeklyDays.has(date.getDay());
    const isExtra = extraShiftDates.includes(key);
    const button = document.createElement('button');
    button.className = 'week-toggle';
    button.type = 'button';
    button.dataset.date = key;
    button.disabled = isWeekly;
    button.setAttribute('aria-pressed', String(isWeekly || isExtra));
    button.innerHTML = `
      <span>${date.toLocaleDateString('en-US', { weekday: 'short' })}</span>
      <strong>${date.toLocaleDateString('en-US', { day: 'numeric' })}</strong>
      <small>${isWeekly ? 'Weekly' : isExtra ? 'On' : 'Off'}</small>
    `;
    currentWeekGrid.append(button);
  }
}

function renderExtraDates() {
  extraDateList.innerHTML = '';
  renderCurrentWeekGrid();

  if (extraShiftDates.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'date-item';
    empty.innerHTML = '<span>No one-off dates added</span>';
    extraDateList.append(empty);
    return;
  }

  extraShiftDates.forEach((key) => {
    const row = document.createElement('div');
    row.className = 'date-item';
    row.innerHTML = `<span>${formatHumanDate(key)}</span><button class="date-remove" type="button" data-date="${key}">Remove</button>`;
    extraDateList.append(row);
  });
}

// ---------- Shift type ----------
function setShiftTypeFromHours(startHour, endHour) {
  const shiftType = Number(endHour) > Number(startHour) ? 'day' : 'night';
  document.querySelectorAll('[name="shiftType"]').forEach((input) => {
    input.checked = input.value === shiftType;
  });
  updateShiftTypeLabels();
}

function applyShiftType(shiftType) {
  if (shiftType === 'day') {
    shiftStartHour.value = '8';
    shiftEndHour.value = '20';
  }
  if (shiftType === 'night') {
    shiftStartHour.value = '20';
    shiftEndHour.value = '8';
  }
  updateShiftTypeLabels();
}

function updateShiftTypeLabels() {
  const startLabel = formatHourLabel(Number(shiftStartHour.value));
  const endLabel = formatHourLabel(Number(shiftEndHour.value));
  const selected = document.querySelector('[name="shiftType"]:checked')?.value;
  dayShiftTime.textContent = selected === 'day' ? `${startLabel} to ${endLabel}` : '8:00 AM to 8:00 PM';
  nightShiftTime.textContent = selected === 'night' ? `${startLabel} to ${endLabel}` : '8:00 PM to 8:00 AM';
}

// ---------- Config <-> form ----------
function fillForm(config) {
  currentConfig = config;
  autoSendEnabled = config.schedule.enabled !== false;

  groupNameInput.value = config.groupName;
  chatComboInput.value = config.groupName;
  renderChatOptions(availableChats, config.groupName);

  timezone.value = config.timezone;
  message.value = config.message;

  shiftStartHour.value = config.schedule.shiftStartHour;
  shiftEndHour.value = config.schedule.shiftEndHour;
  setShiftTypeFromHours(config.schedule.shiftStartHour, config.schedule.shiftEndHour);

  const firstMid = Math.round((config.schedule.firstSendMinuteMin + config.schedule.firstSendMinuteMax) / 2);
  ensureSelectValue(firstSendAfter, firstMid, firstSendLabel(firstMid));

  const gapMid = Math.round((config.schedule.minSendIntervalMinutes + config.schedule.maxSendIntervalMinutes) / 2);
  ensureSelectValue(sendEvery, gapMid, sendEveryLabel(gapMid));

  extraShiftDates = [...config.schedule.extraShiftDates];
  renderExtraDates();

  const activeDays = new Set(config.schedule.activeShiftDays.map(String));
  dayGrid.querySelectorAll('[name="activeShiftDays"]').forEach((input) => {
    input.checked = activeDays.has(input.value);
  });
  renderCurrentWeekGrid();

  dashEnableToggle.checked = autoSendEnabled;
  wizardEnableToggle.checked = autoSendEnabled;
}

function readForm() {
  const activeShiftDays = checkedDays();
  const exactMatch = availableChats.find(
    (chat) => chat.name.toLowerCase() === chatComboInput.value.trim().toLowerCase()
  );
  const groupName =
    groupNameInput.value.trim() || (exactMatch ? exactMatch.name : chatComboInput.value.trim());

  return {
    groupName,
    timezone: timezone.value.trim(),
    message: message.value.trim(),
    schedule: {
      enabled: autoSendEnabled,
      activeShiftDays,
      extraShiftDates,
      shiftStartHour: Number(shiftStartHour.value),
      shiftEndHour: Number(shiftEndHour.value),
      firstSendMinuteMin: Math.max(0, Number(firstSendAfter.value) - FIRST_SEND_JITTER),
      firstSendMinuteMax: Math.min(59, Number(firstSendAfter.value) + FIRST_SEND_JITTER),
      minSendIntervalMinutes: Number(sendEvery.value) - GAP_JITTER,
      maxSendIntervalMinutes: Number(sendEvery.value) + GAP_JITTER,
    },
  };
}

function isConfigured() {
  return Boolean(groupNameInput.value.trim() && message.value.trim() && checkedDays().length);
}

// ---------- Plain-language summary ----------
function formatTime(iso) {
  return new Date(iso).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
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

  if (!crossesMidnight) return formatShiftTitle(shiftStartIso);

  shiftEnd.setDate(shiftEnd.getDate() + 1);
  return `${shiftStart.toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  })} night into ${shiftEnd.toLocaleDateString('en-US', {
    weekday: 'long',
    month: 'long',
    day: 'numeric',
  })}`;
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
      groupsByKey.set(key, { title: formatShiftRangeTitle(key), shiftStartIso: key, items: [] });
    }
    groupsByKey.get(key).items.push(item);
  });

  return [...groupsByKey.values()];
}

function messagesPerShiftRange() {
  const upcoming = lastPreview.filter((item) => item.status === 'upcoming');
  const groups = groupByShift(upcoming);
  if (groups.length === 0) return null;
  const counts = groups.map((group) => group.items.length);
  return { min: Math.min(...counts), max: Math.max(...counts) };
}

function describePlan() {
  const group = escapeHtml(groupNameInput.value.trim() || 'your chat');
  const selectedDays = checkedDays().sort((a, b) => a - b);
  const dayShorts = selectedDays.map((value) => days.find((day) => day.value === value).short);

  let daysText;
  if (selectedDays.length === 7) daysText = 'every day';
  else if (selectedDays.length === 0) daysText = 'on the dates you pick';
  else daysText = `every ${joinList(dayShorts)}`;

  const start = Number(shiftStartHour.value);
  const end = Number(shiftEndHour.value);
  const shiftWord = end <= start ? 'overnight' : 'daytime';
  const startLabel = formatHourLabel(start);
  const endLabel = formatHourLabel(end);

  const range = messagesPerShiftRange();
  let countText = 'a few times';
  if (range) countText = range.min === range.max ? `${range.min} times` : `${range.min}–${range.max} times`;

  const futureExtras = extraShiftDates.filter((key) => {
    const [y, m, d] = key.split('-').map(Number);
    return new Date(y, m - 1, d).setHours(23, 59, 59, 999) >= Date.now();
  });
  const extrasNote = futureExtras.length
    ? ` Plus <b>${futureExtras.length} one-off date${futureExtras.length === 1 ? '' : 's'}</b> you added.`
    : '';

  return `${
    selectedDays.length ? 'On <b>' + daysText + '</b>,' : '<b>' + daysText + ',</b>'
  } I'll send your patrol message to <b>${group}</b> <b>${countText}</b> per ${shiftWord} shift, at natural random times between <b>${startLabel}</b> and <b>${endLabel}</b>.${extrasNote}`;
}

// ---------- Dashboard rendering ----------
function updateSummary() {
  summaryText.innerHTML = describePlan();
  reviewSummary.innerHTML = describePlan();

  dashEnableToggle.checked = autoSendEnabled;
  wizardEnableToggle.checked = autoSendEnabled;

  if (autoSendEnabled) {
    summaryBadge.textContent = 'All set';
    summaryBadge.classList.remove('off');
    autosendTitle.textContent = 'Automatic sending is on';
    autosendHint.textContent = 'Messages will be sent for you at the scheduled times.';
  } else {
    summaryBadge.textContent = 'Preview mode';
    summaryBadge.classList.add('off');
    autosendTitle.textContent = 'Automatic sending is off';
    autosendHint.textContent = 'You are previewing the schedule. Turn on to start sending.';
  }

  const next = lastPreview.find((item) => item.status === 'upcoming');
  if (next && autoSendEnabled) {
    nextSendCard.hidden = false;
    nextSendTime.textContent = next.label;
  } else {
    nextSendCard.hidden = true;
  }
}

function formatShiftTime(iso, shiftStartIso) {
  const sendAt = new Date(iso);
  const shiftStart = new Date(shiftStartIso);
  const time = formatTime(iso);
  if (sendAt.toDateString() === shiftStart.toDateString()) return time;
  return `${sendAt.toLocaleDateString('en-US', { weekday: 'short' })} ${time}`;
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
    const expanded = toggle.getAttribute('aria-expanded') === 'true';
    toggle.setAttribute('aria-expanded', String(!expanded));
    content.hidden = expanded;
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

function renderPreview(preview) {
  lastPreview = preview || [];
  previewList.innerHTML = '';

  if (lastPreview.length === 0) {
    const empty = document.createElement('p');
    empty.className = 'preview-empty';
    empty.textContent = 'No scheduled messages in the preview window.';
    previewList.append(empty);
    return;
  }

  renderShiftGroups('Upcoming shifts', lastPreview.filter((item) => item.status === 'upcoming'), false);
  renderShiftGroups('Past shifts', lastPreview.filter((item) => item.status === 'past'), true);
}

function renderSchedulerLogs(logs) {
  schedulerLogList.innerHTML = '';
  if (logs.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'log-empty';
    empty.textContent = 'No activity yet.';
    schedulerLogList.append(empty);
    return;
  }

  logs.slice(0, 25).forEach((log) => {
    const row = document.createElement('div');
    row.className = `log-item ${log.type}`;
    row.innerHTML = `
      <span class="log-dot"></span>
      <div>
        <strong>${escapeHtml(log.message)}</strong>
        <time datetime="${log.timestamp}">${log.label}</time>
        ${log.details?.messageId ? `<small>Message ID: ${escapeHtml(log.details.messageId)}</small>` : ''}
      </div>
    `;
    schedulerLogList.append(row);
  });
}

async function loadSchedulerLogs() {
  const response = await fetch(`/api/logs?${accountQuery()}&t=${Date.now()}`, { cache: 'no-store' });
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to load logs.');
  renderSchedulerLogs(payload.logs || []);
}

// ---------- Views ----------
function showDashboard() {
  wizard.hidden = true;
  dashboard.hidden = false;
  updateSummary();
}

function showStep(index) {
  currentStep = Math.max(0, Math.min(index, wizardSteps.length - 1));
  wizardSteps.forEach((step, i) => {
    step.hidden = i !== currentStep;
  });

  wizardProgress.innerHTML = '';
  wizardSteps.forEach((step, i) => {
    const bar = document.createElement('span');
    if (i < currentStep) bar.className = 'done';
    else if (i === currentStep) bar.className = 'active';
    wizardProgress.append(bar);
  });

  wizardStepLabel.textContent = `Step ${currentStep + 1} of ${wizardSteps.length}`;
  wizardBack.disabled = currentStep === 0;
  const onLast = currentStep === wizardSteps.length - 1;
  wizardNext.hidden = onLast;
  wizardFinish.hidden = !onLast;
  wizardClose.hidden = !isConfigured();
  setSaveStatus('');

  if (onLast) {
    updateSummary();
    refreshTimingPreview();
  }
}

function openWizard(step = 0) {
  dashboard.hidden = true;
  wizard.hidden = false;
  showStep(step);
}

function decideInitialView() {
  if (isConfigured()) showDashboard();
  else openWizard(0);
}

function setSaveStatus(text, type = '') {
  saveStatus.textContent = text;
  saveStatus.className = type ? `save-hint ${type}` : 'save-hint';
}

function validateStep(index) {
  if (index === 0 && !groupNameInput.value.trim() && !chatComboInput.value.trim()) {
    setSaveStatus('Pick a group or chat first.', 'error');
    chatComboInput.focus();
    return false;
  }
  if (index === 3 && !message.value.trim()) {
    setSaveStatus('Add a message to send.', 'error');
    message.focus();
    return false;
  }
  return true;
}

// ---------- WhatsApp connection ----------
function updateConnectionUI(status, errorText) {
  accountChipName.textContent = currentAccountName();
  if (status === 'ready' && !errorText) {
    connectionDot.className = 'dot dot-ok';
    whatsappStatus.textContent = `${currentAccountName()} is connected`;
  } else if (status === 'ready' && errorText) {
    connectionDot.className = 'dot dot-wait';
    whatsappStatus.textContent = `Connected, but: ${errorText}`;
  } else {
    connectionDot.className = 'dot dot-wait';
    whatsappStatus.textContent = errorText || `Status: ${status}`;
  }
}

function showLogin(payload) {
  isConnected = false;
  loginScreen.hidden = false;
  appShell.hidden = true;

  if (payload.status === 'qr' && payload.qrDataUrl) {
    loginStatus.textContent = `Scan to connect ${currentAccountName()}`;
    qrCode.src = payload.qrDataUrl;
    qrCode.hidden = false;
    scanSteps.hidden = false;
    return;
  }

  qrCode.hidden = true;
  qrCode.removeAttribute('src');
  scanSteps.hidden = true;

  if (payload.error) {
    loginStatus.textContent = `${payload.status}: ${payload.error}`;
    return;
  }
  loginStatus.textContent = `Getting ${currentAccountName()} ready…`;
}

function showConnectedApp(payload) {
  isConnected = true;
  loginScreen.hidden = true;
  appShell.hidden = false;
  lastWhatsappError = payload.error || null;
  availableChats = payload.chats || [];
  renderChatOptions(availableChats, groupNameInput.value);
  updateConnectionUI('ready', lastWhatsappError);

  if (!viewInitialized) {
    viewInitialized = true;
    decideInitialView();
  }
}

async function loadWhatsappState() {
  const response = await fetch(`/api/whatsapp?${accountQuery()}&t=${Date.now()}`, { cache: 'no-store' });
  const payload = await response.json();

  if (!response.ok) {
    const messageText = payload.error || 'Unable to load WhatsApp status.';
    if (appShell.hidden) loginStatus.textContent = messageText;
    else updateConnectionUI('error', messageText);
    return;
  }

  if (payload.status === 'ready') {
    showConnectedApp(payload);
    return;
  }
  showLogin(payload);
}

function scheduleWhatsappPoll(delay = 1000) {
  clearTimeout(whatsappPollTimer);
  whatsappPollTimer = setTimeout(async () => {
    try {
      await loadWhatsappState();
      scheduleWhatsappPoll(isConnected ? 5000 : 1000);
    } catch (error) {
      if (appShell.hidden) loginStatus.textContent = error.message;
      scheduleWhatsappPoll(2000);
    }
  }, delay);
}

async function logoutWhatsappSession() {
  logoutWhatsapp.disabled = true;
  closeAccountMenu();
  viewInitialized = false;
  isConnected = false;
  loginScreen.hidden = false;
  appShell.hidden = true;
  loginStatus.textContent = 'Logging out and restarting…';
  qrCode.hidden = true;
  qrCode.removeAttribute('src');
  renderChatOptions([], groupNameInput.value);

  const response = await fetch(`/api/whatsapp/logout?${accountQuery()}`, { method: 'POST' });
  const payload = await response.json();
  if (!response.ok) {
    loginStatus.textContent = payload.error || 'Logout failed.';
    logoutWhatsapp.disabled = false;
    return;
  }

  loginStatus.textContent = 'Logged out. Waiting for a new QR code…';
  await loadWhatsappState();
  logoutWhatsapp.disabled = false;
}

// ---------- Load / save config ----------
async function loadSettings() {
  const response = await fetch(`/api/config?${accountQuery()}`);
  const payload = await response.json();
  if (!response.ok) throw new Error(payload.error || 'Unable to load settings.');

  renderPreview(payload.preview);
  fillForm(payload.config);
  if (!wizard.hidden || !dashboard.hidden) updateSummary();
  await loadSchedulerLogs();
}

async function saveSettings() {
  setSaveStatus('Saving…');
  const response = await fetch(`/api/config?${accountQuery()}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ config: readForm() }),
  });
  const payload = await response.json();
  if (!response.ok) {
    setSaveStatus(payload.error || 'Save failed', 'error');
    throw new Error(payload.error || 'Save failed');
  }

  renderPreview(payload.preview);
  fillForm(payload.config);
  updateSummary();
  return payload;
}

// Live "dry-run" preview of the schedule for the current (unsaved) selections.
let timingPreviewTimer;

function renderTimingPreview(preview) {
  if (!timingPreview) return;

  const upcoming = (preview || []).filter((item) => item.status === 'upcoming').slice(0, 6);

  if (upcoming.length === 0) {
    timingPreview.innerHTML =
      '<div class="tp-head">Preview</div><p class="tp-empty">Pick at least one shift day to see when messages would go out.</p>';
    return;
  }

  let lastDate = '';
  const rows = upcoming
    .map((item, index) => {
      const date = new Date(item.iso);
      const dateStr = date.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' });
      const timeStr = date.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
      const sameDay = dateStr === lastDate;
      lastDate = dateStr;
      const badge = index === 0 ? '<span class="tp-badge">Next</span>' : '';
      return `<li>${badge}<span class="tp-when">${sameDay ? '' : `${dateStr} · `}<b>${timeStr}</b></span></li>`;
    })
    .join('');

  timingPreview.innerHTML = `<div class="tp-head">Preview · upcoming messages with these settings</div><ul class="tp-list">${rows}</ul>`;
}

function refreshTimingPreview() {
  if (!timingPreview) return;

  clearTimeout(timingPreviewTimer);
  timingPreviewTimer = setTimeout(async () => {
    try {
      const response = await fetch('/api/config/preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ config: readForm() }),
      });
      const payload = await response.json();
      if (!response.ok) throw new Error(payload.error || 'Preview failed');
      renderTimingPreview(payload.preview);
    } catch (error) {
      timingPreview.innerHTML =
        '<div class="tp-head">Preview</div><p class="tp-empty">Couldn\'t build a preview right now.</p>';
    }
  }, 200);
}

// ---------- Events: wizard ----------
wizardNext.addEventListener('click', () => {
  if (!validateStep(currentStep)) return;
  showStep(currentStep + 1);
});

wizardBack.addEventListener('click', () => showStep(currentStep - 1));

wizardClose.addEventListener('click', () => {
  if (isConfigured()) {
    // discard unsaved wizard edits by reloading saved config
    loadSettings().then(showDashboard).catch((error) => setSaveStatus(error.message, 'error'));
  }
});

wizardFinish.addEventListener('click', async () => {
  if (!validateStep(0) || !validateStep(3)) return;
  wizardFinish.disabled = true;
  try {
    await saveSettings();
    showDashboard();
  } catch (error) {
    // status already shown
  } finally {
    wizardFinish.disabled = false;
  }
});

editSetupButton.addEventListener('click', () => openWizard(0));

// ---------- Events: auto-send toggles ----------
dashEnableToggle.addEventListener('change', async () => {
  autoSendEnabled = dashEnableToggle.checked;
  try {
    await saveSettings();
  } catch (error) {
    autoSendEnabled = !autoSendEnabled;
    dashEnableToggle.checked = autoSendEnabled;
  }
});

wizardEnableToggle.addEventListener('change', () => {
  autoSendEnabled = wizardEnableToggle.checked;
  updateSummary();
});

// ---------- Events: step controls ----------
dayGrid.addEventListener('change', () => {
  renderCurrentWeekGrid();
  refreshTimingPreview();
});

document.querySelectorAll('[name="shiftType"]').forEach((input) => {
  input.addEventListener('change', () => {
    applyShiftType(input.value);
    refreshTimingPreview();
  });
});

shiftStartHour.addEventListener('change', () => {
  setShiftTypeFromHours(shiftStartHour.value, shiftEndHour.value);
  refreshTimingPreview();
});
shiftEndHour.addEventListener('change', () => {
  setShiftTypeFromHours(shiftStartHour.value, shiftEndHour.value);
  refreshTimingPreview();
});

firstSendAfter.addEventListener('change', refreshTimingPreview);
sendEvery.addEventListener('change', refreshTimingPreview);

addExtraDate.addEventListener('click', () => {
  const key = extraShiftDateInput.value;
  if (!key || extraShiftDates.includes(key)) return;
  extraShiftDates = [...extraShiftDates, key].sort();
  extraShiftDateInput.value = '';
  renderExtraDates();
  refreshTimingPreview();
});

extraDateList.addEventListener('click', (event) => {
  const button = event.target.closest('[data-date]');
  if (!button) return;
  extraShiftDates = extraShiftDates.filter((key) => key !== button.dataset.date);
  renderExtraDates();
  refreshTimingPreview();
});

currentWeekGrid.addEventListener('click', (event) => {
  const button = event.target.closest('[data-date]');
  if (!button || button.disabled) return;
  const key = button.dataset.date;
  if (extraShiftDates.includes(key)) extraShiftDates = extraShiftDates.filter((date) => date !== key);
  else extraShiftDates = [...extraShiftDates, key].sort();
  renderExtraDates();
  refreshTimingPreview();
});

// ---------- Events: chat combo ----------
chatComboInput.addEventListener('input', () => {
  groupNameInput.value = '';
  openChatMenu();
  renderChatOptions(availableChats, groupNameInput.value);
});

chatComboInput.addEventListener('focus', () => {
  openChatMenu();
  renderChatOptions(availableChats, groupNameInput.value);
});

chatComboMenu.addEventListener('click', (event) => {
  const option = event.target.closest('[data-name]');
  if (option) selectChat(option.dataset.name);
});

document.addEventListener('click', (event) => {
  if (!chatCombo.contains(event.target)) closeChatMenu();
  if (!accountMenu.contains(event.target) && !accountMenuButton.contains(event.target)) closeAccountMenu();
});

// ---------- Events: account menu ----------
accountMenuButton.addEventListener('click', () => {
  if (accountMenu.hidden) openAccountMenu();
  else closeAccountMenu();
});

[accountSelect, loginAccountSelect].forEach((select) => {
  select.addEventListener('change', () => {
    switchAccount(select.value).catch((error) => {
      setSaveStatus(error.message, 'error');
      loginStatus.textContent = error.message;
    });
  });
});

accountForm.addEventListener('submit', (event) => {
  event.preventDefault();
  addAccount(accountName.value)
    .then(() => {
      accountName.value = '';
    })
    .catch((error) => setSaveStatus(error.message, 'error'));
});

loginAccountForm.addEventListener('submit', (event) => {
  event.preventDefault();
  addAccount(loginAccountName.value)
    .then(() => {
      loginAccountName.value = '';
    })
    .catch((error) => {
      loginStatus.textContent = error.message;
    });
});

logoutWhatsapp.addEventListener('click', () => {
  logoutWhatsappSession().catch((error) => {
    loginStatus.textContent = error.message;
    logoutWhatsapp.disabled = false;
  });
});

// ---------- Startup ----------
loadAccounts()
  .then(() => loadSettings())
  .catch((error) => {
    setSaveStatus(error.message, 'error');
    loginStatus.textContent = error.message;
  });

scheduleWhatsappPoll();
setInterval(() => {
  if (isConnected) loadSchedulerLogs().catch(() => {});
}, 5000);
