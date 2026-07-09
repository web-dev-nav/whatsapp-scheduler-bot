const fs = require('fs');
const path = require('path');

const CONFIG_PATH = path.join(__dirname, 'config.json');
const TIMEZONE = 'America/Toronto';
const MS_PER_MINUTE = 60 * 1000;
const MS_PER_DAY = 24 * 60 * MS_PER_MINUTE;

const DEFAULT_CONFIG = {
  groupName: 'LADO RANI',
  timezone: TIMEZONE,
  message:
    'Patrol completed and verified all four checkpoints — East, West, South, and North. Ensured Main Entrances and truck entrance and bowery rd entrance were open as required, and Wright Street entrances were closed and confirmed secure. Conducted a thorough inspection of all areas with no unusual activity detected.',
  schedule: {
    activeShiftDays: [1, 2, 3],
    extraShiftDates: ['2026-07-09'],
    shiftStartHour: 20,
    shiftEndHour: 8,
    firstSendMinuteMin: 20,
    firstSendMinuteMax: 30,
    minSendIntervalMinutes: 90,
    maxSendIntervalMinutes: 110,
  },
};

function deepClone(value) {
  return JSON.parse(JSON.stringify(value));
}

function mergeConfig(config) {
  return {
    ...deepClone(DEFAULT_CONFIG),
    ...config,
    schedule: {
      ...deepClone(DEFAULT_CONFIG.schedule),
      ...(config.schedule || {}),
    },
  };
}

function loadConfig() {
  if (!fs.existsSync(CONFIG_PATH)) {
    return deepClone(DEFAULT_CONFIG);
  }

  const parsed = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  return mergeConfig(parsed);
}

function saveConfig(config) {
  const normalized = normalizeConfig(config);
  fs.writeFileSync(CONFIG_PATH, `${JSON.stringify(normalized, null, 2)}\n`);
  return normalized;
}

function normalizeConfig(config) {
  const merged = mergeConfig(config);
  const schedule = merged.schedule;

  schedule.activeShiftDays = [...new Set(schedule.activeShiftDays.map(Number))]
    .filter((day) => Number.isInteger(day) && day >= 0 && day <= 6)
    .sort((a, b) => a - b);
  schedule.extraShiftDates = [...new Set(schedule.extraShiftDates.map(String))]
    .filter((date) => /^\d{4}-\d{2}-\d{2}$/.test(date))
    .sort();

  [
    'shiftStartHour',
    'shiftEndHour',
    'firstSendMinuteMin',
    'firstSendMinuteMax',
    'minSendIntervalMinutes',
    'maxSendIntervalMinutes',
  ].forEach((key) => {
    schedule[key] = Number(schedule[key]);
  });

  if (schedule.firstSendMinuteMin > schedule.firstSendMinuteMax) {
    [schedule.firstSendMinuteMin, schedule.firstSendMinuteMax] = [
      schedule.firstSendMinuteMax,
      schedule.firstSendMinuteMin,
    ];
  }

  if (schedule.minSendIntervalMinutes > schedule.maxSendIntervalMinutes) {
    [schedule.minSendIntervalMinutes, schedule.maxSendIntervalMinutes] = [
      schedule.maxSendIntervalMinutes,
      schedule.minSendIntervalMinutes,
    ];
  }

  return merged;
}

function formatDate(date, timezone = TIMEZONE) {
  return date.toLocaleString('en-US', {
    timeZone: timezone,
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
    second: '2-digit',
  });
}

function seededRandom(seed) {
  let hash = 2166136261;

  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }

  return () => {
    hash += 0x6d2b79f5;
    let value = hash;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function randomInt(random, min, max) {
  return min + Math.floor(random() * (max - min + 1));
}

function startOfDay(date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function startOfWeek(date) {
  const day = date.getDay();
  const daysSinceMonday = day === 0 ? 6 : day - 1;
  return new Date(startOfDay(date).getTime() - daysSinceMonday * MS_PER_DAY);
}

function addDays(date, days) {
  return new Date(date.getTime() + days * MS_PER_DAY);
}

function formatDateKey(date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

function parseDateKey(dateKey) {
  const [year, month, day] = dateKey.split('-').map(Number);
  return new Date(year, month - 1, day);
}

function buildShiftSchedule(shiftDate, config) {
  const { schedule } = config;
  const random = seededRandom(formatDateKey(shiftDate));
  const firstMinute = randomInt(random, schedule.firstSendMinuteMin, schedule.firstSendMinuteMax);
  const shiftStart = new Date(
    shiftDate.getFullYear(),
    shiftDate.getMonth(),
    shiftDate.getDate(),
    schedule.shiftStartHour,
    firstMinute
  );
  const shiftEnd = new Date(
    shiftDate.getFullYear(),
    shiftDate.getMonth(),
    shiftDate.getDate() + (schedule.shiftEndHour <= schedule.shiftStartHour ? 1 : 0),
    schedule.shiftEndHour,
    0
  );
  const sends = [];
  let sendAt = shiftStart;

  while (sendAt < shiftEnd) {
    sends.push(sendAt);
    const intervalMinutes = randomInt(
      random,
      schedule.minSendIntervalMinutes,
      schedule.maxSendIntervalMinutes
    );
    sendAt = new Date(sendAt.getTime() + intervalMinutes * MS_PER_MINUTE);
  }

  return sends;
}

function buildScheduleForWeeks(config, baseDate = new Date(), weekCount = 2) {
  const normalized = normalizeConfig(config);
  const monday = startOfWeek(baseDate);
  const scheduleStart = monday;
  const scheduleEnd = addDays(monday, weekCount * 7);
  const sends = [];
  const scheduledDateKeys = new Set();

  for (let weekIndex = 0; weekIndex < weekCount; weekIndex += 1) {
    normalized.schedule.activeShiftDays.forEach((dayNumber) => {
      const shiftDate = addDays(monday, weekIndex * 7 + dayNumber - 1);
      scheduledDateKeys.add(formatDateKey(shiftDate));
      sends.push(...buildShiftSchedule(shiftDate, normalized));
    });
  }

  normalized.schedule.extraShiftDates.forEach((dateKey) => {
    const shiftDate = parseDateKey(dateKey);

    if (shiftDate < scheduleStart || shiftDate >= scheduleEnd || scheduledDateKeys.has(dateKey)) {
      return;
    }

    sends.push(...buildShiftSchedule(shiftDate, normalized));
  });

  return sends.sort((a, b) => a.getTime() - b.getTime());
}

function findNextSendAt(config, currentTime = new Date()) {
  const schedule = buildScheduleForWeeks(config, currentTime, 3);
  return schedule.find((sendAt) => sendAt > currentTime);
}

module.exports = {
  CONFIG_PATH,
  DEFAULT_CONFIG,
  buildScheduleForWeeks,
  findNextSendAt,
  formatDate,
  loadConfig,
  saveConfig,
};
