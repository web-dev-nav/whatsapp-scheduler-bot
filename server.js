const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');
const QRCode = require('qrcode');
const { version: ENGINE_VERSION } = require('./package.json');
const { loadEnvFile } = require('./env');

loadEnvFile();

const {
  buildScheduleForWeeks,
  findNextSendAt,
  formatDate,
  loadConfigFromPath,
  saveConfigToPath,
  normalizeConfig,
} = require('./scheduler');

const HOST = process.env.HOST || '127.0.0.1';
const PORT = Number(process.env.PORT || 3000);
const DATA_DIR = path.resolve(process.env.DATA_DIR || __dirname);
const PATROL_TRIGGER_TOKEN = (process.env.PATROL_TRIGGER_TOKEN || '').trim();
const PUBLIC_DIR = path.join(__dirname, 'public');
const ACCOUNTS_PATH = path.resolve(process.env.ACCOUNTS_PATH || path.join(DATA_DIR, 'accounts.json'));
const LEGACY_SEND_HISTORY_PATH = path.resolve(
  process.env.SEND_HISTORY_PATH || path.join(DATA_DIR, 'send-history.json')
);
const LEGACY_WHATSAPP_AUTH_DIR = path.resolve(
  process.env.WHATSAPP_AUTH_DIR || path.join(DATA_DIR, '.wwebjs_auth')
);
const MS_PER_MINUTE = 60 * 1000;
const MS_PER_DAY = 24 * 60 * MS_PER_MINUTE;
// How long an account session token stays valid after login.
const SESSION_TOKEN_TTL_MS = Number(process.env.SESSION_TOKEN_TTL_HOURS || 24) * 60 * MS_PER_MINUTE;
// Login attempt limiting for POST /api/accounts/auth, keyed by IP+account.
const AUTH_ATTEMPT_WINDOW_MS = 15 * MS_PER_MINUTE;
const AUTH_ATTEMPT_LOCKOUT_MS = 15 * MS_PER_MINUTE;
const AUTH_ATTEMPT_MAX = 5;
// Optional shared secret(s) for the location/patrol trigger webhook. When either is
// set, callers must pass a matching token as ?token=, an X-Patrol-Token header, or
// {"token": "..."} in the body. Leave both unset for local/LAN-only use.
const PATROL_TOKEN = process.env.PATROL_TOKEN || '';
const runtimes = new Map();
const accountSessions = new Map();
const authAttempts = new Map();
let shuttingDown = false;
const startedAt = new Date();

fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(path.dirname(ACCOUNTS_PATH), { recursive: true });

function slugifyAccountId(name) {
  const slug = String(name)
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);

  return slug || 'account';
}

function readAccounts() {
  if (!fs.existsSync(ACCOUNTS_PATH)) {
    const accounts = [{ id: 'main', name: 'Main' }];
    writeAccounts(accounts);
    return accounts;
  }

  const parsed = JSON.parse(fs.readFileSync(ACCOUNTS_PATH, 'utf8'));
  const accounts = Array.isArray(parsed.accounts) ? parsed.accounts : parsed;

  if (!Array.isArray(accounts) || accounts.length === 0) {
    return [{ id: 'main', name: 'Main' }];
  }

  return accounts
    .map((account) => ({
      id: slugifyAccountId(account.id || account.name),
      name: String(account.name || account.id || 'Account').trim() || 'Account',
      passwordSalt: typeof account.passwordSalt === 'string' ? account.passwordSalt : '',
      passwordHash: typeof account.passwordHash === 'string' ? account.passwordHash : '',
    }))
    .filter((account, index, list) => list.findIndex((candidate) => candidate.id === account.id) === index);
}

function writeAccounts(accounts) {
  fs.writeFileSync(ACCOUNTS_PATH, `${JSON.stringify({ accounts }, null, 2)}\n`);
}

function publicAccount(account) {
  return {
    id: account.id,
    name: account.name,
    hasPassword: Boolean(account.passwordSalt && account.passwordHash),
  };
}

function publicAccounts() {
  return readAccounts().map(publicAccount);
}

function getAccount(accountId = 'main') {
  return readAccounts().find((account) => account.id === accountId);
}

function hashPassword(password, salt = crypto.randomBytes(16).toString('hex')) {
  const passwordHash = crypto.pbkdf2Sync(String(password), salt, 310000, 32, 'sha256').toString('hex');
  return { passwordSalt: salt, passwordHash };
}

function verifyPassword(account, password) {
  if (!account.passwordSalt || !account.passwordHash) return false;
  const { passwordHash } = hashPassword(password, account.passwordSalt);
  if (passwordHash.length !== account.passwordHash.length) return false;
  return crypto.timingSafeEqual(Buffer.from(passwordHash, 'hex'), Buffer.from(account.passwordHash, 'hex'));
}

function createAccountSession(accountId) {
  const token = crypto.randomBytes(32).toString('hex');
  accountSessions.set(token, { accountId, createdAt: Date.now() });
  return token;
}

function authTokenFromRequest(request) {
  return request.headers['x-account-auth'] || '';
}

function requireAccountAuth(request, response, accountId) {
  const account = getAccount(accountId);
  if (!account) {
    sendJson(response, 404, { error: `Unknown account "${accountId}".` });
    return false;
  }

  if (!account.passwordSalt || !account.passwordHash) {
    sendJson(response, 423, {
      error: `Set a password before opening "${account.name}".`,
      requiresPasswordSetup: true,
      account: publicAccount(account),
    });
    return false;
  }

  const token = authTokenFromRequest(request);
  const session = accountSessions.get(token);
  if (session && Date.now() - session.createdAt > SESSION_TOKEN_TTL_MS) {
    accountSessions.delete(token);
  } else if (session && session.accountId === account.id) {
    return true;
  }

  sendJson(response, 401, { error: `Enter the password for "${account.name}".`, requiresLogin: true });
  return false;
}

function clientIp(request) {
  const forwarded = request.headers['x-forwarded-for'];
  if (forwarded) return String(forwarded).split(',')[0].trim();
  return request.socket.remoteAddress || 'unknown';
}

function checkAuthRateLimit(request, accountId) {
  const key = `${clientIp(request)}:${accountId}`;
  const attempt = authAttempts.get(key);
  const now = Date.now();

  if (!attempt) return { allowed: true, key };
  if (attempt.lockedUntil && now < attempt.lockedUntil) {
    return { allowed: false, retryAfterMs: attempt.lockedUntil - now };
  }
  if (now - attempt.windowStart > AUTH_ATTEMPT_WINDOW_MS) {
    authAttempts.delete(key);
    return { allowed: true, key };
  }

  return { allowed: true, key };
}

function recordAuthFailure(key) {
  const now = Date.now();
  const attempt = authAttempts.get(key) || { count: 0, windowStart: now };

  if (now - attempt.windowStart > AUTH_ATTEMPT_WINDOW_MS) {
    attempt.count = 0;
    attempt.windowStart = now;
  }

  attempt.count += 1;
  if (attempt.count >= AUTH_ATTEMPT_MAX) {
    attempt.lockedUntil = now + AUTH_ATTEMPT_LOCKOUT_MS;
  }

  authAttempts.set(key, attempt);
}

function clearAuthAttempts(key) {
  authAttempts.delete(key);
}

function setAccountPassword(accountId, password) {
  const trimmed = String(password || '');
  if (trimmed.length < 4) {
    return { ok: false, statusCode: 400, error: 'Password must be at least 4 characters.' };
  }

  const accounts = readAccounts();
  const index = accounts.findIndex((account) => account.id === accountId);
  if (index === -1) {
    return { ok: false, statusCode: 404, error: `Unknown account "${accountId}".` };
  }

  const nextAccount = { ...accounts[index], ...hashPassword(trimmed) };
  accounts[index] = nextAccount;
  writeAccounts(accounts);

  return { ok: true, account: nextAccount, token: createAccountSession(nextAccount.id) };
}

function createAccount(name, password) {
  const accounts = readAccounts();
  const baseId = slugifyAccountId(name);
  let id = baseId;
  let suffix = 2;

  while (accounts.some((account) => account.id === id)) {
    id = `${baseId}-${suffix}`;
    suffix += 1;
  }

  const trimmedPassword = String(password || '');
  if (trimmedPassword.length < 4) {
    throw new Error('Password must be at least 4 characters.');
  }

  const account = { id, name: String(name || id).trim() || id, ...hashPassword(trimmedPassword) };
  accounts.push(account);
  writeAccounts(accounts);
  getRuntime(account.id);
  return account;
}

async function deleteAccount(accountId) {
  const account = getAccount(accountId);

  if (!account) {
    return { ok: false, statusCode: 404, error: `Unknown account "${accountId}".` };
  }

  if (account.id === 'main') {
    return {
      ok: false,
      statusCode: 400,
      error: 'The main account cannot be removed. Log it out instead, or remove added accounts.',
    };
  }

  const runtime = runtimes.get(account.id);
  if (runtime) {
    clearScheduler(runtime);
    clearWhatsappRestart(runtime);

    if (runtime.client) {
      try {
        await runtime.client.destroy();
      } catch (error) {
        addSchedulerLog(runtime, 'error', 'Could not destroy WhatsApp client while removing account.', {
          error: error.message,
        });
      }
    }

    runtimes.delete(account.id);
  }

  const accounts = readAccounts().filter((candidate) => candidate.id !== account.id);
  writeAccounts(accounts.length ? accounts : [{ id: 'main', name: 'Main' }]);

  const paths = accountPaths(account);
  if (paths.dataDir !== DATA_DIR && paths.dataDir.startsWith(path.join(DATA_DIR, 'accounts'))) {
    fs.rmSync(paths.dataDir, { recursive: true, force: true });
    setTimeout(() => {
      fs.rmSync(paths.dataDir, { recursive: true, force: true });
    }, 2000);
  }

  return { ok: true, account, accounts: readAccounts() };
}

function accountPaths(account) {
  if (account.id === 'main') {
    return {
      dataDir: DATA_DIR,
      configPath: path.resolve(process.env.CONFIG_PATH || path.join(DATA_DIR, 'config.json')),
      sendHistoryPath: LEGACY_SEND_HISTORY_PATH,
      authDir: LEGACY_WHATSAPP_AUTH_DIR,
    };
  }

  const dataDir = path.join(DATA_DIR, 'accounts', account.id);

  return {
    dataDir,
    configPath: path.join(dataDir, 'config.json'),
    sendHistoryPath: path.join(dataDir, 'send-history.json'),
    authDir: path.join(dataDir, '.wwebjs_auth'),
  };
}

function ensureAccountPaths(paths) {
  fs.mkdirSync(paths.dataDir, { recursive: true });
  fs.mkdirSync(path.dirname(paths.configPath), { recursive: true });
  fs.mkdirSync(path.dirname(paths.sendHistoryPath), { recursive: true });
  fs.mkdirSync(paths.authDir, { recursive: true });
}

function createRuntime(account) {
  const paths = accountPaths(account);
  ensureAccountPaths(paths);

  return {
    account,
    paths,
    state: {
      status: 'starting',
      qrDataUrl: null,
      chats: [],
      error: null,
    },
    client: null,
    starting: false,
    schedulerTimer: null,
    readyAt: null,
    lastChatRefreshErrorAt: 0,
    restartTimer: null,
    restartAttempts: 0,
    logs: [],
  };
}

function getRuntime(accountId = 'main') {
  const account = getAccount(accountId);

  if (!account) {
    return null;
  }

  if (!runtimes.has(account.id)) {
    const runtime = createRuntime(account);
    runtimes.set(account.id, runtime);
    startWhatsappClient(runtime);
  }

  return runtimes.get(account.id);
}

function startAllAccounts() {
  readAccounts().forEach((account) => {
    getRuntime(account.id);
  });
}

function addSchedulerLog(runtime, type, message, details = {}) {
  const config = loadConfigFromPath(runtime.paths.configPath);
  const entry = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    type,
    message,
    details,
    timestamp: new Date().toISOString(),
    label: formatDate(new Date(), config.timezone),
    accountId: runtime.account.id,
    accountName: runtime.account.name,
  };

  runtime.logs.unshift(entry);
  runtime.logs.splice(100);

  const logLine = `[${runtime.account.name}] [${entry.label}] ${message}`;
  if (type === 'error') {
    console.error(logLine, details.error || '');
  } else {
    console.log(logLine);
  }
}

function resetWhatsappState(runtime, status = 'starting') {
  runtime.state.status = status;
  runtime.state.qrDataUrl = null;
  runtime.state.chats = [];
  runtime.state.error = null;
}

function chatDisplayName(chat) {
  return chat.name || chat.formattedTitle || chat.id.user || chat.id._serialized;
}

// Resilient chat enumeration.
//
// whatsapp-web.js `client.getChats()` serializes every chat, which triggers an
// IndexedDB read that current WhatsApp Web builds reject
// ("DataError: Failed to execute 'get' on 'IDBObjectStore'", surfaced as the
// minified "r"). We only need id/name/isGroup, so we read those fields straight
// off the in-memory chat models and skip the broken serialization entirely.
async function extractChats(runtime) {
  if (!runtime.client || !runtime.client.pupPage) return [];

  const chats = await runtime.client.pupPage.evaluate(async () => {
    const collection = window.require('WAWebCollections').Chat.getModelsArray();

    return collection
      .map((chat) => {
        let name = null;
        try { name = chat.formattedTitle; } catch (error) { /* ignore */ }
        if (!name) { try { name = chat.name; } catch (error) { /* ignore */ } }
        if (!name && chat.contact) {
          try {
            name = chat.contact.name || chat.contact.pushname || chat.contact.formattedName;
          } catch (error) { /* ignore */ }
        }

        let id = null;
        try { id = chat.id && (chat.id._serialized || String(chat.id)); } catch (error) { /* ignore */ }
        if (!name && chat.id) {
          try { name = chat.id.user || chat.id._serialized; } catch (error) { /* ignore */ }
        }

        let isGroup = false;
        try { isGroup = (chat.id && chat.id.server === 'g.us') || Boolean(chat.isGroup); } catch (error) { /* ignore */ }

        return { id, name, isGroup };
      })
      .filter((chat) => chat.id);
  });

  return chats;
}

async function refreshChats(runtime) {
  if (!runtime.client) return;

  try {
    const chats = await extractChats(runtime);
    runtime.state.chats = chats
      .filter((chat) => chat.name)
      .sort((a, b) => {
        if (a.isGroup !== b.isGroup) return a.isGroup ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
    runtime.state.error = null;
    runtime.lastChatRefreshErrorAt = 0;
  } catch (error) {
    runtime.state.error = `Could not load WhatsApp chats: ${error.message}`;

    const now = Date.now();
    if (now - runtime.lastChatRefreshErrorAt > 60 * 1000) {
      addSchedulerLog(runtime, 'error', 'Could not load WhatsApp chats.', { error: error.message });
      runtime.lastChatRefreshErrorAt = now;
    }
  }
}

function clearScheduler(runtime) {
  if (runtime.schedulerTimer) {
    clearTimeout(runtime.schedulerTimer);
    runtime.schedulerTimer = null;
    addSchedulerLog(runtime, 'info', 'Scheduler timer cleared.');
  }
}

function clearWhatsappRestart(runtime) {
  if (runtime.restartTimer) {
    clearTimeout(runtime.restartTimer);
    runtime.restartTimer = null;
  }
}

async function findTargetChat(runtime, chatName) {
  const chats = await extractChats(runtime);
  const match = chats.find((chat) => chat.name === chatName);

  if (!match) return null;

  // Return a lightweight chat wrapper. Sending goes through
  // client.sendMessage(id, ...), which resolves the chat via the working
  // WWebJS.getChat/sendMessage path rather than the broken getChats serializer.
  return {
    id: { _serialized: match.id },
    name: match.name,
    isGroup: match.isGroup,
    sendMessage: (content, options) => runtime.client.sendMessage(match.id, content, options),
  };
}

function readSendHistory(runtime) {
  if (!fs.existsSync(runtime.paths.sendHistoryPath)) {
    return [];
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(runtime.paths.sendHistoryPath, 'utf8'));
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    addSchedulerLog(runtime, 'error', 'Could not read send history. Blocking sends until the file is fixed.', {
      error: error.message,
    });
    return null;
  }
}

function writeSendHistory(runtime, history) {
  const recentHistory = history.slice(-500);
  fs.writeFileSync(runtime.paths.sendHistoryPath, `${JSON.stringify(recentHistory, null, 2)}\n`);
}

function messageHash(message) {
  return crypto.createHash('sha256').update(message).digest('hex').slice(0, 16);
}

function sendKey(scheduledAt, chatId, hash) {
  return `${scheduledAt.toISOString()}|${chatId}|${hash}`;
}

function countRecentSuccessfulSends(history, now) {
  const since = now.getTime() - MS_PER_DAY;
  return history.filter((entry) => {
    if (entry.status !== 'sent') return false;
    return new Date(entry.attemptedAt).getTime() >= since;
  }).length;
}

function findLastSuccessfulSend(history) {
  return [...history]
    .filter((entry) => entry.status === 'sent')
    .sort((a, b) => new Date(b.attemptedAt).getTime() - new Date(a.attemptedAt).getTime())[0];
}

function appendSendHistory(runtime, entry) {
  const history = readSendHistory(runtime);

  if (!history) {
    return false;
  }

  history.push(entry);
  writeSendHistory(runtime, history);
  return true;
}

function buildHistoryEntry(status, scheduledAt, config, chat, details = {}) {
  // `message` (if passed) is the actual text that was sent/attempted, which can
  // differ from config.message when a checkpoint/guard-triggered send templated
  // it via buildTriggeredPatrolMessage. It's used only to compute the hash below
  // and is not itself persisted, to keep history entries small.
  const { message, ...rest } = details;
  const hash = messageHash(message || config.message);
  const chatId = chat?.id?._serialized || null;

  return {
    key: sendKey(scheduledAt, chatId || config.groupName, hash),
    status,
    scheduledAt: scheduledAt.toISOString(),
    attemptedAt: new Date().toISOString(),
    chatId,
    chatName: chat?.name || config.groupName,
    messageHash: hash,
    ...rest,
  };
}

function getSendBlockReason(runtime, config, chat, scheduledAt, history, now = new Date()) {
  const schedule = config.schedule;
  const hash = messageHash(config.message);
  const chatId = chat.id._serialized;
  const key = sendKey(scheduledAt, chatId, hash);
  const existingAttempt = history.find((entry) => entry.key === key && entry.status !== 'skipped');

  if (!schedule.enabled) {
    return 'Scheduler is disabled.';
  }

  if (!config.message.trim()) {
    return 'Message is empty.';
  }

  if (existingAttempt) {
    return `This scheduled message already has a ${existingAttempt.status} history entry.`;
  }

  const staleByMs = now.getTime() - scheduledAt.getTime();
  const staleGraceMs = schedule.staleSendGraceMinutes * MS_PER_MINUTE;

  if (staleByMs > staleGraceMs) {
    return `Scheduled time is more than ${schedule.staleSendGraceMinutes} minutes old.`;
  }

  if (runtime.readyAt) {
    const readyCooldownMs = schedule.reconnectCooldownMinutes * MS_PER_MINUTE;
    const readyAgeMs = now.getTime() - runtime.readyAt.getTime();

    if (readyAgeMs < readyCooldownMs) {
      return `WhatsApp reconnected less than ${schedule.reconnectCooldownMinutes} minutes ago.`;
    }
  }

  const lastSuccessfulSend = findLastSuccessfulSend(history);

  if (lastSuccessfulSend) {
    const minutesSinceLastSend =
      (now.getTime() - new Date(lastSuccessfulSend.attemptedAt).getTime()) / MS_PER_MINUTE;

    if (minutesSinceLastSend < schedule.minMinutesBetweenSends) {
      return `Last successful send was less than ${schedule.minMinutesBetweenSends} minutes ago.`;
    }
  }

  if (countRecentSuccessfulSends(history, now) >= schedule.maxSendsPerDay) {
    return `Daily send cap of ${schedule.maxSendsPerDay} messages has been reached.`;
  }

  return null;
}

async function sendPatrolMessage(runtime, scheduledAt) {
  const config = loadConfigFromPath(runtime.paths.configPath);
  const chat = await findTargetChat(runtime, config.groupName);

  if (!chat) {
    addSchedulerLog(runtime, 'error', `Could not find chat "${config.groupName}".`);
    return;
  }

  const history = readSendHistory(runtime);

  if (!history) {
    return;
  }

  const blockReason = getSendBlockReason(runtime, config, chat, scheduledAt, history);

  if (blockReason) {
    appendSendHistory(runtime, buildHistoryEntry('skipped', scheduledAt, config, chat, { reason: blockReason }));
    addSchedulerLog(runtime, 'info', `Skipped patrol message to "${chat.name}": ${blockReason}`);
    return;
  }

  addSchedulerLog(runtime, 'info', `Sending patrol message to "${chat.name}".`);

  try {
    const sentMessage = await chat.sendMessage(config.message);
    const messageId = sentMessage?.id?._serialized || sentMessage?.id?.id || null;
    appendSendHistory(runtime, buildHistoryEntry('sent', scheduledAt, config, chat, { messageId }));
    addSchedulerLog(runtime, 'success', `Message sent to "${chat.name}".`, {
      chatName: chat.name,
      messageId,
    });
  } catch (error) {
    appendSendHistory(runtime, buildHistoryEntry('failed', scheduledAt, config, chat, { error: error.message }));
    addSchedulerLog(runtime, 'error', 'Failed to send patrol message. No immediate retry will be attempted.', {
      error: error.message,
    });
  }
}

// On-demand send used by the GPS/location trigger (patrol mode). Unlike the
// scheduled path, this ignores the fixed timetable (there is no scheduledAt and
// no shift window) but keeps the anti-spam guards that matter: min gap between
// sends and the daily cap. This prevents re-entering a geofence from spamming
// the group while still letting a real patrol fire a message immediately.
async function sendPatrolMessageNow(
  runtime,
  { source = 'patrol-gps', checkpointName = null, guard = null, message: messageOverride = null, dryRun = false } = {}
) {
  const config = loadConfigFromPath(runtime.paths.configPath);

  if (runtime.state.status !== 'ready') {
    return { ok: false, reason: 'WhatsApp is not connected yet.' };
  }

  const message = buildTriggeredPatrolMessage(config, { message: messageOverride, checkpointName, guard });

  if (!message) {
    return { ok: false, reason: 'Message is empty.' };
  }

  const chat = await findTargetChat(runtime, config.groupName);

  if (!chat) {
    return { ok: false, reason: `Could not find chat "${config.groupName}".` };
  }

  const history = readSendHistory(runtime);

  if (!history) {
    return { ok: false, reason: 'Send history is unreadable; sends are blocked.' };
  }

  const now = new Date();
  const lastSuccessfulSend = findLastSuccessfulSend(history);

  if (lastSuccessfulSend) {
    const minutesSinceLastSend =
      (now.getTime() - new Date(lastSuccessfulSend.attemptedAt).getTime()) / MS_PER_MINUTE;

    if (minutesSinceLastSend < config.schedule.minMinutesBetweenSends) {
      return {
        ok: false,
        reason: `Last send was ${Math.round(minutesSinceLastSend)} min ago (minimum ${config.schedule.minMinutesBetweenSends} min).`,
      };
    }
  }

  if (countRecentSuccessfulSends(history, now) >= config.schedule.maxSendsPerDay) {
    return { ok: false, reason: `Daily send cap of ${config.schedule.maxSendsPerDay} messages has been reached.` };
  }

  if (dryRun) {
    return {
      ok: true,
      dryRun: true,
      chatName: chat.name,
      message,
      reason: 'All guards passed. No message was sent (dry run).',
    };
  }

  addSchedulerLog(
    runtime,
    'info',
    `Location trigger: sending patrol message to "${chat.name}"${checkpointName ? ` (${checkpointName})` : ''}.`
  );

  try {
    const sentMessage = await chat.sendMessage(message);
    const messageId = sentMessage?.id?._serialized || sentMessage?.id?.id || null;
    appendSendHistory(
      runtime,
      buildHistoryEntry('sent', now, config, chat, { message, messageId, source, checkpointName, guard })
    );
    addSchedulerLog(runtime, 'success', `Patrol message sent to "${chat.name}" via ${source}.`, {
      chatName: chat.name,
      messageId,
    });
    return { ok: true, chatName: chat.name, messageId };
  } catch (error) {
    appendSendHistory(runtime, buildHistoryEntry('failed', now, config, chat, { message, error: error.message, source }));
    addSchedulerLog(runtime, 'error', 'Failed to send location-triggered patrol message.', { error: error.message });
    return { ok: false, reason: error.message };
  }
}

function scheduleNextPatrolMessage(runtime) {
  clearScheduler(runtime);

  if (runtime.state.status !== 'ready') {
    addSchedulerLog(runtime, 'info', 'Scheduler is waiting for WhatsApp to be ready.');
    return;
  }

  const config = loadConfigFromPath(runtime.paths.configPath);

  if (!config.schedule.enabled) {
    addSchedulerLog(runtime, 'info', 'Scheduler is disabled. No patrol message is scheduled.');
    return;
  }

  const nextSendAt = findNextSendAt(config);

  if (!nextSendAt) {
    addSchedulerLog(runtime, 'error', 'Could not find next patrol send time.');
    return;
  }

  const delayMs = nextSendAt.getTime() - Date.now();
  addSchedulerLog(runtime, 'scheduled', `Next patrol message scheduled for ${formatDate(nextSendAt, config.timezone)}.`, {
    nextSendAt: nextSendAt.toISOString(),
  });

  runtime.schedulerTimer = setTimeout(async () => {
    try {
      await sendPatrolMessage(runtime, nextSendAt);
    } catch (error) {
      addSchedulerLog(runtime, 'error', 'Failed to send patrol message.', { error: error.message });
    } finally {
      scheduleNextPatrolMessage(runtime);
    }
  }, Math.max(delayMs, 0));
}

function createWhatsappClient(runtime) {
  const puppeteerOptions = {
    headless: true,
    args: [
      '--no-sandbox',
      '--disable-setuid-sandbox',
      '--disable-dev-shm-usage',
      '--disable-gpu',
    ],
  };

  if (process.env.CHROME_EXECUTABLE_PATH) {
    puppeteerOptions.executablePath = process.env.CHROME_EXECUTABLE_PATH;
  }

  return new Client({
    authStrategy: new LocalAuth({
      dataPath: runtime.paths.authDir,
    }),
    puppeteer: puppeteerOptions,
  });
}

function attachWhatsappHandlers(runtime, client) {
  client.on('qr', async (qr) => {
    runtime.state.status = 'qr';
    runtime.state.qrDataUrl = await QRCode.toDataURL(qr, { width: 360, margin: 2 });
    runtime.state.error = null;
  });

  client.on('authenticated', () => {
    runtime.state.status = 'authenticated';
    runtime.state.qrDataUrl = null;
    runtime.state.error = null;
  });

  client.on('ready', async () => {
    runtime.state.status = 'ready';
    runtime.readyAt = new Date();
    runtime.state.qrDataUrl = null;
    runtime.state.error = null;
    runtime.restartAttempts = 0;
    clearWhatsappRestart(runtime);
    await refreshChats(runtime);
    const config = loadConfigFromPath(runtime.paths.configPath);
    addSchedulerLog(
      runtime,
      'info',
      `WhatsApp is ready. Scheduler cooldown is ${config.schedule.reconnectCooldownMinutes} minutes.`
    );
    scheduleNextPatrolMessage(runtime);
  });

  client.on('disconnected', (reason) => {
    runtime.state.status = 'disconnected';
    runtime.readyAt = null;
    runtime.state.error = reason;
    addSchedulerLog(runtime, 'error', 'WhatsApp disconnected.', { reason });
    clearScheduler(runtime);
  });

  client.on('auth_failure', (message) => {
    runtime.state.status = 'error';
    runtime.state.error = message;
    addSchedulerLog(runtime, 'error', 'WhatsApp authentication failed.', { error: message });
  });
}

function scheduleWhatsappRestart(runtime, error) {
  const transientPuppeteerError = /Execution context was destroyed|Runtime\.callFunctionOn|Protocol error/i.test(
    error.message
  );

  if (!transientPuppeteerError || runtime.restartAttempts >= 3 || runtime.restartTimer) {
    return;
  }

  runtime.restartAttempts += 1;
  addSchedulerLog(runtime, 'error', `WhatsApp startup failed. Retrying (${runtime.restartAttempts}/3).`, {
    error: error.message,
  });

  runtime.restartTimer = setTimeout(async () => {
    runtime.restartTimer = null;

    if (runtime.client) {
      try {
        await runtime.client.destroy();
      } catch (destroyError) {
        addSchedulerLog(runtime, 'error', 'Could not destroy failed WhatsApp browser before retry.', {
          error: destroyError.message,
        });
      }
    }

    runtime.client = null;
    startWhatsappClient(runtime);
  }, 5000);
}

function startWhatsappClient(runtime) {
  if (runtime.starting) return;

  runtime.starting = true;
  resetWhatsappState(runtime, 'starting');
  runtime.client = createWhatsappClient(runtime);
  attachWhatsappHandlers(runtime, runtime.client);
  runtime.client
    .initialize()
    .catch((error) => {
      runtime.state.status = 'error';
      runtime.state.error = error.message;
      scheduleWhatsappRestart(runtime, error);
    })
    .finally(() => {
      runtime.starting = false;
    });
}

async function logoutWhatsappClient(runtime) {
  resetWhatsappState(runtime, 'logging_out');
  clearScheduler(runtime);
  clearWhatsappRestart(runtime);
  runtime.restartAttempts = 0;

  if (runtime.client) {
    try {
      await runtime.client.logout();
    } catch (error) {
      if (!/not logged in|Protocol error|Session closed/i.test(error.message)) {
        runtime.state.error = error.message;
      }
    }

    try {
      await runtime.client.destroy();
    } catch (error) {
      if (!runtime.state.error) {
        runtime.state.error = error.message;
      }
    }
  }

  runtime.client = null;
  startWhatsappClient(runtime);
}

function sendJson(response, statusCode, payload) {
  response.writeHead(statusCode, {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-store',
  });
  response.end(JSON.stringify(payload));
}

function sanitizeMessageLine(value) {
  return String(value || '')
    .replace(/\s+/g, ' ')
    .trim();
}

function buildTriggeredPatrolMessage(config, payload) {
  const baseMessage = sanitizeMessageLine(payload.message || config.message);
  const checkpointName = sanitizeMessageLine(payload.checkpointName);
  const guard = sanitizeMessageLine(payload.guard);

  if (!checkpointName && !guard) {
    return baseMessage;
  }

  const detailParts = [];

  if (checkpointName) {
    detailParts.push(`Checkpoint: ${checkpointName}`);
  }

  if (guard) {
    detailParts.push(`Guard: ${guard}`);
  }

  return `${baseMessage}\n\n${detailParts.join('\n')}`;
}

function readPatrolTriggerToken(url, request, payload) {
  return sanitizeMessageLine(
    url.searchParams.get('token') || request.headers['x-patrol-token'] || payload.token
  );
}

function readRequestBody(request) {
  return new Promise((resolve, reject) => {
    let body = '';

    request.on('data', (chunk) => {
      body += chunk;

      if (body.length > 1024 * 1024) {
        request.destroy();
        reject(new Error('Request body is too large.'));
      }
    });

    request.on('end', () => resolve(body));
    request.on('error', reject);
  });
}

function buildPreview(config) {
  const now = new Date();

  return buildScheduleForWeeks(config, now, 2).map((sendAt) => ({
    iso: sendAt.toISOString(),
    label: formatDate(sendAt, config.timezone),
    status: sendAt < now ? 'past' : 'upcoming',
  }));
}

function contentType(filePath) {
  if (filePath.endsWith('.css')) return 'text/css';
  if (filePath.endsWith('.js')) return 'text/javascript';
  if (filePath.endsWith('.html')) return 'text/html';
  return 'application/octet-stream';
}

function sendStatic(request, response) {
  const requestedPath = request.url === '/' ? '/index.html' : decodeURIComponent(request.url);
  const filePath = path.normalize(path.join(PUBLIC_DIR, requestedPath));

  if (!filePath.startsWith(PUBLIC_DIR)) {
    response.writeHead(403);
    response.end('Forbidden');
    return;
  }

  fs.readFile(filePath, (error, content) => {
    if (error) {
      response.writeHead(404);
      response.end('Not found');
      return;
    }

    response.writeHead(200, { 'Content-Type': contentType(filePath) });
    response.end(content);
  });
}

function accountFromUrl(url) {
  return url.searchParams.get('account') || 'main';
}

function requireRuntime(response, accountId) {
  const runtime = getRuntime(accountId);

  if (!runtime) {
    sendJson(response, 404, { error: `Unknown account "${accountId}".` });
    return null;
  }

  return runtime;
}

// Used by /api/patrol/trigger when the caller doesn't name an account: picks
// whichever linked WhatsApp account is actually connected, so callers (n8n,
// iOS Shortcuts, anyone) don't need to know or hardcode a specific account id.
function findReadyRuntime() {
  for (const runtime of runtimes.values()) {
    if (runtime.state.status === 'ready') {
      return runtime;
    }
  }
  return null;
}

function buildHealthResponse() {
  const now = Date.now();

  for (const [token, session] of accountSessions.entries()) {
    if (now - session.createdAt > SESSION_TOKEN_TTL_MS) {
      accountSessions.delete(token);
    }
  }

  const accounts = readAccounts();
  const connectedAccounts = accounts.reduce((count, account) => {
    return count + (runtimes.get(account.id)?.state.status === 'ready' ? 1 : 0);
  }, 0);

  return {
    status: shuttingDown ? 'shutting_down' : 'ok',
    engineVersion: ENGINE_VERSION,
    nodeVersion: process.version,
    startedAt: startedAt.toISOString(),
    uptimeSeconds: Math.floor((now - startedAt.getTime()) / 1000),
    serverTime: new Date(now).toISOString(),
    totalAccounts: accounts.length,
    connectedAccounts,
    activeSessions: accountSessions.size,
  };
}

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${HOST}:${PORT}`);
    const pathname = url.pathname;

    if (request.method === 'GET' && pathname === '/api/health') {
      sendJson(response, 200, buildHealthResponse());
      return;
    }

    if (request.method === 'GET' && pathname === '/api/accounts') {
      sendJson(response, 200, { accounts: publicAccounts() });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/accounts') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body || '{}');
      const account = createAccount(payload.name, payload.password);
      const token = createAccountSession(account.id);
      sendJson(response, 201, { account: publicAccount(account), accounts: publicAccounts(), token });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/accounts/auth') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body || '{}');
      const account = getAccount(payload.account || accountFromUrl(url));
      if (!account) {
        sendJson(response, 404, { error: `Unknown account "${payload.account || accountFromUrl(url)}".` });
        return;
      }

      if (!account.passwordSalt || !account.passwordHash) {
        sendJson(response, 423, {
          error: `Set a password before opening "${account.name}".`,
          requiresPasswordSetup: true,
          account: publicAccount(account),
        });
        return;
      }

      const rateLimit = checkAuthRateLimit(request, account.id);
      if (!rateLimit.allowed) {
        sendJson(response, 429, {
          error: 'Too many failed login attempts. Try again later.',
          retryAfterSeconds: Math.ceil(rateLimit.retryAfterMs / 1000),
        });
        return;
      }

      if (!verifyPassword(account, payload.password || '')) {
        recordAuthFailure(rateLimit.key);
        sendJson(response, 401, { error: 'Incorrect password.' });
        return;
      }

      clearAuthAttempts(rateLimit.key);
      sendJson(response, 200, { account: publicAccount(account), token: createAccountSession(account.id) });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/accounts/password') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body || '{}');
      const accountId = payload.account || accountFromUrl(url);
      const account = getAccount(accountId);
      if (!account) {
        sendJson(response, 404, { error: `Unknown account "${accountId}".` });
        return;
      }

      if (account.passwordSalt && account.passwordHash && !requireAccountAuth(request, response, account.id)) {
        return;
      }

      const result = setAccountPassword(account.id, payload.password);
      if (!result.ok) {
        sendJson(response, result.statusCode || 400, { error: result.error });
        return;
      }

      sendJson(response, 200, { account: publicAccount(result.account), accounts: publicAccounts(), token: result.token });
      return;
    }

    if (request.method === 'DELETE' && pathname === '/api/accounts') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const result = await deleteAccount(accountId);
      if (!result.ok) {
        sendJson(response, result.statusCode || 400, { error: result.error });
        return;
      }

      sendJson(response, 200, { account: publicAccount(result.account), accounts: publicAccounts() });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/whatsapp') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const runtime = requireRuntime(response, accountId);
      if (!runtime) return;

      if (runtime.state.status === 'ready') {
        await refreshChats(runtime);
      }

      sendJson(response, 200, { account: publicAccount(runtime.account), ...runtime.state });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/whatsapp/logout') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const runtime = requireRuntime(response, accountId);
      if (!runtime) return;

      await logoutWhatsappClient(runtime);
      sendJson(response, 200, { account: publicAccount(runtime.account), ...runtime.state });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/config') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const runtime = requireRuntime(response, accountId);
      if (!runtime) return;

      const config = loadConfigFromPath(runtime.paths.configPath);
      sendJson(response, 200, { account: publicAccount(runtime.account), config, preview: buildPreview(config) });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/logs') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const runtime = requireRuntime(response, accountId);
      if (!runtime) return;

      sendJson(response, 200, { account: publicAccount(runtime.account), logs: runtime.logs });
      return;
    }

    if (request.method === 'PUT' && pathname === '/api/config') {
      const accountId = accountFromUrl(url);
      if (!requireAccountAuth(request, response, accountId)) return;

      const runtime = requireRuntime(response, accountId);
      if (!runtime) return;

      const body = await readRequestBody(request);
      const payload = JSON.parse(body);
      const config = saveConfigToPath(runtime.paths.configPath, payload.config);
      scheduleNextPatrolMessage(runtime);
      sendJson(response, 200, { account: publicAccount(runtime.account), config, preview: buildPreview(config) });
      return;
    }

    // Patrol trigger webhook. Called by the in-app Patrol Mode page (browser GPS),
    // a native phone geofence (iOS Shortcuts / Android Tasker), or the n8n bridge
    // used by WatchPoint. Sends the patrol message on demand, guarded against spam
    // (cooldown + daily cap), and templates in checkpoint/guard details when given.
    if (request.method === 'POST' && pathname === '/api/patrol/trigger') {
      const body = await readRequestBody(request);
      const payload = body ? JSON.parse(body) : {};
      const providedToken = readPatrolTriggerToken(url, request, payload);
      const requestedAccountId = url.searchParams.get('account');

      if (PATROL_TOKEN || PATROL_TRIGGER_TOKEN) {
        const validTokens = [PATROL_TOKEN, PATROL_TRIGGER_TOKEN].filter(Boolean);
        if (!validTokens.includes(providedToken)) {
          sendJson(response, 401, { ok: false, error: 'Invalid or missing patrol token.' });
          return;
        }
      } else if (!requireAccountAuth(request, response, requestedAccountId || 'main')) {
        return;
      }

      // No ?account= given: don't assume "main" — dynamically use whichever
      // account is actually connected, so the caller doesn't need to know or
      // hardcode a specific account id. Pass ?account=<id> to target one
      // explicitly (e.g. when more than one account is linked at once).
      let runtime;
      if (requestedAccountId) {
        runtime = requireRuntime(response, requestedAccountId);
        if (!runtime) return;
      } else {
        runtime = findReadyRuntime();
        if (!runtime) {
          sendJson(response, 409, {
            ok: false,
            error: 'No linked WhatsApp account is currently connected.',
          });
          return;
        }
      }

      const dryRun =
        url.searchParams.get('dryRun') === '1' ||
        ['1', 'true', 'yes'].includes(String(payload.dryRun || '').toLowerCase());
      const result = await sendPatrolMessageNow(runtime, {
        source: payload.source || 'patrol-gps',
        checkpointName: payload.checkpointName || null,
        guard: payload.guard || null,
        message: payload.message || null,
        dryRun,
      });

      sendJson(response, result.ok ? 200 : 409, { account: publicAccount(runtime.account), ...result });
      return;
    }

    // Dry-run preview: compute the schedule for a proposed config WITHOUT saving it,
    // so the UI can show the effect of timing changes live before the user commits.
    if (request.method === 'POST' && pathname === '/api/config/preview') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body);
      const config = normalizeConfig(payload.config);
      sendJson(response, 200, { config, preview: buildPreview(config) });
      return;
    }

    if (request.method === 'GET') {
      sendStatic(request, response);
      return;
    }

    response.writeHead(405);
    response.end('Method not allowed');
  } catch (error) {
    sendJson(response, 400, { error: error.message });
  }
});

server.on('error', (error) => {
  console.error(`Could not start server on ${HOST}:${PORT}.`, error);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`Schedule UI running at http://${HOST}:${PORT}`);
});

async function shutdown(signal) {
  if (shuttingDown) {
    return;
  }

  shuttingDown = true;
  console.log(`Received ${signal}. Shutting down...`);

  await Promise.all(
    [...runtimes.values()].map(async (runtime) => {
      clearScheduler(runtime);
      clearWhatsappRestart(runtime);

      if (runtime.client) {
        try {
          await runtime.client.destroy();
        } catch (error) {
          console.error(`[${runtime.account.name}] Could not destroy WhatsApp client during shutdown.`, error.message);
        }
      }
    })
  );

  server.close(() => {
    process.exit(0);
  });
}

process.on('SIGINT', () => {
  shutdown('SIGINT');
});

process.on('SIGTERM', () => {
  shutdown('SIGTERM');
});

startAllAccounts();
