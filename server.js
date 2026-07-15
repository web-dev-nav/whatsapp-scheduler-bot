const http = require('http');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');
const QRCode = require('qrcode');
const { buildScheduleForWeeks, findNextSendAt, formatDate, loadConfig, saveConfig } = require('./scheduler');

const HOST = '127.0.0.1';
const PORT = Number(process.env.PORT || 3000);
const PUBLIC_DIR = path.join(__dirname, 'public');
const SEND_HISTORY_PATH = path.join(__dirname, 'send-history.json');
const MS_PER_MINUTE = 60 * 1000;
const MS_PER_DAY = 24 * 60 * MS_PER_MINUTE;
const whatsappState = {
  status: 'starting',
  qrDataUrl: null,
  chats: [],
  error: null,
};
let whatsappClient;
let whatsappStarting = false;
let schedulerTimer;
let whatsappReadyAt = null;
let lastChatRefreshErrorAt = 0;
let whatsappRestartTimer;
let whatsappRestartAttempts = 0;
const schedulerLogs = [];

function addSchedulerLog(type, message, details = {}) {
  const config = loadConfig();
  const entry = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    type,
    message,
    details,
    timestamp: new Date().toISOString(),
    label: formatDate(new Date(), config.timezone),
  };

  schedulerLogs.unshift(entry);
  schedulerLogs.splice(100);

  const logLine = `[${entry.label}] ${message}`;
  if (type === 'error') {
    console.error(logLine, details.error || '');
  } else {
    console.log(logLine);
  }
}

function resetWhatsappState(status = 'starting') {
  whatsappState.status = status;
  whatsappState.qrDataUrl = null;
  whatsappState.chats = [];
  whatsappState.error = null;
}

function chatDisplayName(chat) {
  return chat.name || chat.formattedTitle || chat.id.user || chat.id._serialized;
}

async function refreshChats() {
  if (!whatsappClient) return;

  try {
    const chats = await whatsappClient.getChats();
    whatsappState.chats = chats
      .map((chat) => ({
        id: chat.id._serialized,
        name: chatDisplayName(chat),
        isGroup: Boolean(chat.isGroup),
      }))
      .filter((chat) => chat.name)
      .sort((a, b) => {
        if (a.isGroup !== b.isGroup) return a.isGroup ? -1 : 1;
        return a.name.localeCompare(b.name);
      });
    whatsappState.error = null;
    lastChatRefreshErrorAt = 0;
  } catch (error) {
    whatsappState.error = `Could not load WhatsApp chats: ${error.message}`;

    const now = Date.now();
    if (now - lastChatRefreshErrorAt > 60 * 1000) {
      addSchedulerLog('error', 'Could not load WhatsApp chats.', { error: error.message });
      lastChatRefreshErrorAt = now;
    }
  }
}

function clearScheduler() {
  if (schedulerTimer) {
    clearTimeout(schedulerTimer);
    schedulerTimer = null;
    addSchedulerLog('info', 'Scheduler timer cleared.');
  }
}

function clearWhatsappRestart() {
  if (whatsappRestartTimer) {
    clearTimeout(whatsappRestartTimer);
    whatsappRestartTimer = null;
  }
}

async function findTargetChat(chatName) {
  const chats = await whatsappClient.getChats();
  return chats.find((chat) => chat.name === chatName);
}

function readSendHistory() {
  if (!fs.existsSync(SEND_HISTORY_PATH)) {
    return [];
  }

  try {
    const parsed = JSON.parse(fs.readFileSync(SEND_HISTORY_PATH, 'utf8'));
    return Array.isArray(parsed) ? parsed : [];
  } catch (error) {
    addSchedulerLog('error', 'Could not read send history. Blocking sends until the file is fixed.', {
      error: error.message,
    });
    return null;
  }
}

function writeSendHistory(history) {
  const recentHistory = history.slice(-500);
  fs.writeFileSync(SEND_HISTORY_PATH, `${JSON.stringify(recentHistory, null, 2)}\n`);
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

function appendSendHistory(entry) {
  const history = readSendHistory();

  if (!history) {
    return false;
  }

  history.push(entry);
  writeSendHistory(history);
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

function getSendBlockReason(config, chat, scheduledAt, history, now = new Date()) {
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

  if (whatsappReadyAt) {
    const readyCooldownMs = schedule.reconnectCooldownMinutes * MS_PER_MINUTE;
    const readyAgeMs = now.getTime() - whatsappReadyAt.getTime();

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

async function sendPatrolMessage(scheduledAt) {
  const config = loadConfig();
  const chat = await findTargetChat(config.groupName);

  if (!chat) {
    addSchedulerLog('error', `Could not find chat "${config.groupName}".`);
    return;
  }

  const history = readSendHistory();

  if (!history) {
    return;
  }

  const blockReason = getSendBlockReason(config, chat, scheduledAt, history);

  if (blockReason) {
    appendSendHistory(buildHistoryEntry('skipped', scheduledAt, config, chat, { reason: blockReason }));
    addSchedulerLog('info', `Skipped patrol message to "${chat.name}": ${blockReason}`);
    return;
  }

  addSchedulerLog('info', `Sending patrol message to "${chat.name}".`);

  try {
    const sentMessage = await chat.sendMessage(config.message);
    const messageId = sentMessage?.id?._serialized || sentMessage?.id?.id || null;
    appendSendHistory(buildHistoryEntry('sent', scheduledAt, config, chat, { messageId }));
    addSchedulerLog('success', `Message sent to "${chat.name}".`, {
      chatName: chat.name,
      messageId,
    });
  } catch (error) {
    appendSendHistory(buildHistoryEntry('failed', scheduledAt, config, chat, { error: error.message }));
    addSchedulerLog('error', 'Failed to send patrol message. No immediate retry will be attempted.', {
      error: error.message,
    });
  }
}

function scheduleNextPatrolMessage() {
  clearScheduler();

  if (whatsappState.status !== 'ready') {
    addSchedulerLog('info', 'Scheduler is waiting for WhatsApp to be ready.');
    return;
  }

  const config = loadConfig();

  if (!config.schedule.enabled) {
    addSchedulerLog('info', 'Scheduler is disabled. No patrol message is scheduled.');
    return;
  }

  const nextSendAt = findNextSendAt(config);

  if (!nextSendAt) {
    addSchedulerLog('error', 'Could not find next patrol send time.');
    return;
  }

  const delayMs = nextSendAt.getTime() - Date.now();
  addSchedulerLog('scheduled', `Next patrol message scheduled for ${formatDate(nextSendAt, config.timezone)}.`, {
    nextSendAt: nextSendAt.toISOString(),
  });

  schedulerTimer = setTimeout(async () => {
    try {
      await sendPatrolMessage(nextSendAt);
    } catch (error) {
      addSchedulerLog('error', 'Failed to send patrol message.', { error: error.message });
    } finally {
      scheduleNextPatrolMessage();
    }
  }, Math.max(delayMs, 0));
}

function createWhatsappClient() {
  return new Client({
    authStrategy: new LocalAuth(),
    puppeteer: {
      headless: true,
      args: ['--no-sandbox', '--disable-setuid-sandbox'],
    },
  });
}

function attachWhatsappHandlers(client) {
  client.on('qr', async (qr) => {
    whatsappState.status = 'qr';
    whatsappState.qrDataUrl = await QRCode.toDataURL(qr, { width: 360, margin: 2 });
    whatsappState.error = null;
  });

  client.on('authenticated', () => {
    whatsappState.status = 'authenticated';
    whatsappState.qrDataUrl = null;
    whatsappState.error = null;
  });

  client.on('ready', async () => {
    whatsappState.status = 'ready';
    whatsappReadyAt = new Date();
    whatsappState.qrDataUrl = null;
    whatsappState.error = null;
    whatsappRestartAttempts = 0;
    clearWhatsappRestart();
    await refreshChats();
    const config = loadConfig();
    addSchedulerLog(
      'info',
      `WhatsApp is ready. Scheduler cooldown is ${config.schedule.reconnectCooldownMinutes} minutes.`
    );
    scheduleNextPatrolMessage();
  });

  client.on('disconnected', (reason) => {
    whatsappState.status = 'disconnected';
    whatsappReadyAt = null;
    whatsappState.error = reason;
    addSchedulerLog('error', 'WhatsApp disconnected.', { reason });
    clearScheduler();
  });

  client.on('auth_failure', (message) => {
    whatsappState.status = 'error';
    whatsappState.error = message;
    addSchedulerLog('error', 'WhatsApp authentication failed.', { error: message });
  });
}

function scheduleWhatsappRestart(error) {
  const transientPuppeteerError = /Execution context was destroyed|Runtime\.callFunctionOn|Protocol error/i.test(
    error.message
  );

  if (!transientPuppeteerError || whatsappRestartAttempts >= 3 || whatsappRestartTimer) {
    return;
  }

  whatsappRestartAttempts += 1;
  addSchedulerLog('error', `WhatsApp startup failed. Retrying (${whatsappRestartAttempts}/3).`, {
    error: error.message,
  });

  whatsappRestartTimer = setTimeout(async () => {
    whatsappRestartTimer = null;

    if (whatsappClient) {
      try {
        await whatsappClient.destroy();
      } catch (destroyError) {
        addSchedulerLog('error', 'Could not destroy failed WhatsApp browser before retry.', {
          error: destroyError.message,
        });
      }
    }

    whatsappClient = null;
    startWhatsappClient();
  }, 5000);
}

function startWhatsappClient() {
  if (whatsappStarting) return;

  whatsappStarting = true;
  resetWhatsappState('starting');
  whatsappClient = createWhatsappClient();
  attachWhatsappHandlers(whatsappClient);
  whatsappClient
    .initialize()
    .catch((error) => {
      whatsappState.status = 'error';
      whatsappState.error = error.message;
      scheduleWhatsappRestart(error);
    })
    .finally(() => {
      whatsappStarting = false;
    });
}

async function logoutWhatsappClient() {
  resetWhatsappState('logging_out');
  clearScheduler();
  clearWhatsappRestart();
  whatsappRestartAttempts = 0;

  if (whatsappClient) {
    try {
      await whatsappClient.logout();
    } catch (error) {
      if (!/not logged in|Protocol error|Session closed/i.test(error.message)) {
        whatsappState.error = error.message;
      }
    }

    try {
      await whatsappClient.destroy();
    } catch (error) {
      if (!whatsappState.error) {
        whatsappState.error = error.message;
      }
    }
  }

  whatsappClient = null;
  startWhatsappClient();
}

startWhatsappClient();

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

const server = http.createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, `http://${HOST}:${PORT}`).pathname;

    if (request.method === 'GET' && pathname === '/api/whatsapp') {
      if (whatsappState.status === 'ready') {
        await refreshChats();
      }

      sendJson(response, 200, whatsappState);
      return;
    }

    if (request.method === 'POST' && pathname === '/api/whatsapp/logout') {
      await logoutWhatsappClient();
      sendJson(response, 200, whatsappState);
      return;
    }

    if (request.method === 'GET' && pathname === '/api/config') {
      const config = loadConfig();
      sendJson(response, 200, { config, preview: buildPreview(config) });
      return;
    }

    if (request.method === 'GET' && pathname === '/api/logs') {
      sendJson(response, 200, { logs: schedulerLogs });
      return;
    }

    if (request.method === 'PUT' && pathname === '/api/config') {
      const body = await readRequestBody(request);
      const payload = JSON.parse(body);
      const config = saveConfig(payload.config);
      scheduleNextPatrolMessage();
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

server.listen(PORT, HOST, () => {
  console.log(`Schedule UI running at http://${HOST}:${PORT}`);
});
