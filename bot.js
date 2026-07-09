const { Client, LocalAuth } = require('whatsapp-web.js');
const qrcode = require('qrcode-terminal');
const QRCode = require('qrcode');
const { buildScheduleForWeeks, findNextSendAt, formatDate, loadConfig } = require('./scheduler');

const config = loadConfig();
const TIMEZONE = config.timezone;
process.env.TZ = TIMEZONE;

const TEST_MODE = process.argv.includes('--test');
const LIST_MODE = process.argv.includes('--list');
const MAX_SCHEDULE_RECHECK_MS = 60 * 1000;

const client = new Client({
  authStrategy: new LocalAuth(),
  puppeteer: {
    headless: true,
    args: ['--no-sandbox', '--disable-setuid-sandbox'],
  },
});

function now() {
  return new Date().toLocaleString('en-CA', {
    timeZone: TIMEZONE,
    dateStyle: 'short',
    timeStyle: 'medium',
  });
}

function log(message) {
  console.log(`[${now()}] ${message}`);
}

function printScheduleList() {
  const currentTime = new Date();
  const schedule = buildScheduleForWeeks(config, currentTime, 2);

  console.log(`Patrol schedule preview (${TIMEZONE})`);
  console.log(`Generated on: ${formatDate(currentTime)}`);
  console.log('Windows: Monday, Tuesday, Wednesday from 8:00 PM to 8:00 AM');
  console.log(`Extra shift dates: ${config.schedule.extraShiftDates.join(', ') || 'none'}`);
  console.log('');

  schedule.forEach((sendAt) => {
    const status = sendAt < currentTime ? 'past' : 'upcoming';
    console.log(`- ${formatDate(sendAt, TIMEZONE)} (${status})`);
  });
}

function groupDisplayName(group) {
  return group.name || '(unnamed group)';
}

async function findTargetChat(chatName = loadConfig().groupName) {
  const chats = await client.getChats();
  const availableChats = chats
    .filter((chat) => chat.name)
    .sort((a, b) => groupDisplayName(a).localeCompare(groupDisplayName(b)));

  const chat = availableChats.find((candidate) => candidate.name === chatName);

  if (!chat) {
    console.error(`Could not find a WhatsApp chat named: "${chatName}"`);
    console.error('Available chats:');

    if (availableChats.length === 0) {
      console.error('- No chats found. Make sure this WhatsApp account can see the target chat.');
    } else {
      availableChats.forEach((availableChat) => console.error(`- ${groupDisplayName(availableChat)}`));
    }

    process.exit(1);
  }

  return chat;
}

async function sendMessage(group, message) {
  try {
    await group.sendMessage(message);
    log(`Sent to "${group.name}": ${message}`);
  } catch (error) {
    console.error(`[${now()}] Failed to send to "${group.name}":`, error);
  }
}

function scheduleNextMessage(group) {
  const latestConfig = loadConfig();
  const nextSendAt = findNextSendAt(latestConfig);

  if (!nextSendAt) {
    console.error(`[${now()}] Could not find the next patrol send time.`);
    process.exit(1);
  }

  const delayMs = nextSendAt.getTime() - Date.now();

  log(`Next patrol message scheduled at ${formatDate(nextSendAt, TIMEZONE)} (${TIMEZONE})`);

  setTimeout(async () => {
    if (delayMs <= MAX_SCHEDULE_RECHECK_MS) {
      const sendConfig = loadConfig();
      const targetGroup = group.name === sendConfig.groupName ? group : await findTargetChat(sendConfig.groupName);
      await sendMessage(targetGroup, sendConfig.message);
      scheduleNextMessage(targetGroup);
      return;
    }

    scheduleNextMessage(group);
  }, Math.min(delayMs, MAX_SCHEDULE_RECHECK_MS));
}

if (LIST_MODE) {
  printScheduleList();
  process.exit(0);
}

client.on('qr', async (qr) => {
  console.log('\nScan this QR code with WhatsApp:\n');
  qrcode.generate(qr, { small: true });
  await QRCode.toFile('latest-qr.png', qr, { width: 500, margin: 2 });
  console.log('\nA scannable QR image was also saved to: latest-qr.png');
  console.log('\nOpen WhatsApp > Settings > Linked Devices > Link a Device, then scan the QR code above.\n');
});

client.on('ready', async () => {
  log('WhatsApp client is ready.');

  const group = await findTargetChat();
  log(`Found chat: "${group.name}"`);

  if (TEST_MODE) {
    log('TEST MODE enabled. A test message will be sent in 60 seconds.');
    setTimeout(() => {
      sendMessage(group, '✅ Test message from bot');
    }, 60 * 1000);
    return;
  }

  scheduleNextMessage(group);
  log('Scheduler is running.');
});

client.on('disconnected', (reason) => {
  console.error(`[${now()}] WhatsApp client disconnected: ${reason}`);
  process.exit(1);
});

client.initialize();
