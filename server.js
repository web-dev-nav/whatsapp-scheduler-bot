const http = require('http');
const fs = require('fs');
const path = require('path');
const { Client, LocalAuth } = require('whatsapp-web.js');
const QRCode = require('qrcode');
const { buildScheduleForWeeks, findNextSendAt, formatDate, loadConfig, saveConfig } = require('./scheduler');

const HOST = '127.0.0.1';
const PORT = Number(process.env.PORT || 3000);
const PUBLIC_DIR = path.join(__dirname, 'public');
const whatsappState = {
  status: 'starting',
  qrDataUrl: null,
  chats: [],
  error: null,
};
let whatsappClient;
let whatsappStarting = false;
let schedulerTimer;
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
}

function clearScheduler() {
  if (schedulerTimer) {
    clearTimeout(schedulerTimer);
    schedulerTimer = null;
    addSchedulerLog('info', 'Scheduler timer cleared.');
  }
}

async function findTargetChat(chatName) {
  const chats = await whatsappClient.getChats();
  return chats.find((chat) => chat.name === chatName);
}

async function sendPatrolMessage() {
  const config = loadConfig();
  const chat = await findTargetChat(config.groupName);

  if (!chat) {
    addSchedulerLog('error', `Could not find chat "${config.groupName}".`);
    return;
  }

  addSchedulerLog('info', `Sending patrol message to "${chat.name}".`);
  const sentMessage = await chat.sendMessage(config.message);
  addSchedulerLog('success', `Message sent to "${chat.name}".`, {
    chatName: chat.name,
    messageId: sentMessage?.id?._serialized || sentMessage?.id?.id || null,
  });
}

function scheduleNextPatrolMessage() {
  clearScheduler();

  if (whatsappState.status !== 'ready') {
    addSchedulerLog('info', 'Scheduler is waiting for WhatsApp to be ready.');
    return;
  }

  const config = loadConfig();
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
      await sendPatrolMessage();
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
    whatsappState.error = null;
  });

  client.on('ready', async () => {
    whatsappState.status = 'ready';
    whatsappState.qrDataUrl = null;
    whatsappState.error = null;
    await refreshChats();
    addSchedulerLog('info', 'WhatsApp is ready. Scheduler is active.');
    scheduleNextPatrolMessage();
  });

  client.on('disconnected', (reason) => {
    whatsappState.status = 'disconnected';
    whatsappState.error = reason;
    addSchedulerLog('error', 'WhatsApp disconnected.', { reason });
    clearScheduler();
  });
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
    })
    .finally(() => {
      whatsappStarting = false;
    });
}

async function logoutWhatsappClient() {
  resetWhatsappState('logging_out');
  clearScheduler();

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
