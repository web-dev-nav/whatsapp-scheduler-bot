const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');
const QRCode = require('qrcode');
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
const runtimes = new Map();
let shuttingDown = false;

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
    }))
    .filter((account, index, list) => list.findIndex((candidate) => candidate.id === account.id) === index);
}

function writeAccounts(accounts) {
  fs.writeFileSync(ACCOUNTS_PATH, `${JSON.stringify({ accounts }, null, 2)}\n`);
}

function getAccount(accountId = 'main') {
  return readAccounts().find((account) => account.id === accountId);
}

function createAccount(name) {
  const accounts = readAccounts();
  const baseId = slugifyAccountId(name);
  let id = baseId;
  let suffix = 2;

  while (accounts.some((account) => account.id === id)) {
    id = `${baseId}-${suffix}`;
    suffix += 1;
  }

  const account = { id, name: String(name || id).trim() || id };
  accounts.push(account);
  writeAccounts(accounts);
  getRuntime(account.id);
  return account;
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
  const hash = messageHash(config.message);
  const chatId = chat?.id?._serialized || null;

  return {
    key: sendKey(scheduledAt, chatId || config.groupName, hash),
    status,
    scheduledAt: scheduledAt.toISOString(),
    attemptedAt: new Date().toISOString(),
    chatId,
    chatName: chat?.name || config.groupName,
    messageHash: hash,
    ...details,
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

const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://${HOST}:${PORT}`);
    const pathname = url.pathname;

    if (request.method === 'GET' && pathname === '/api/accounts') {
      sendJson(response, 200, { accounts: readAccounts() });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/accounts') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body || '{}');
      const account = createAccount(payload.name);
      sendJson(response, 201, { account, accounts: readAccounts() });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/whatsapp') {
      const runtime = requireRuntime(response, accountFromUrl(url));
      if (!runtime) return;

      if (runtime.state.status === 'ready') {
        await refreshChats(runtime);
      }

      sendJson(response, 200, { account: runtime.account, ...runtime.state });
      return;
    }

    if (request.method === 'POST' && pathname === '/api/whatsapp/logout') {
      const runtime = requireRuntime(response, accountFromUrl(url));
      if (!runtime) return;

      await logoutWhatsappClient(runtime);
      sendJson(response, 200, { account: runtime.account, ...runtime.state });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/config') {
      const runtime = requireRuntime(response, accountFromUrl(url));
      if (!runtime) return;

      const config = loadConfigFromPath(runtime.paths.configPath);
      sendJson(response, 200, { account: runtime.account, config, preview: buildPreview(config) });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/logs') {
      const runtime = requireRuntime(response, accountFromUrl(url));
      if (!runtime) return;

      sendJson(response, 200, { account: runtime.account, logs: runtime.logs });
      return;
    }

    if (request.method === 'PUT' && pathname === '/api/config') {
      const runtime = requireRuntime(response, accountFromUrl(url));
      if (!runtime) return;

      const body = await readRequestBody(request);
      const payload = JSON.parse(body);
      const config = saveConfigToPath(runtime.paths.configPath, payload.config);
      scheduleNextPatrolMessage(runtime);
      sendJson(response, 200, { account: runtime.account, config, preview: buildPreview(config) });
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
