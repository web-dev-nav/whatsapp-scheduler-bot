# WhatsApp Patrol Scheduler

Local WhatsApp patrol scheduler with a browser UI, QR login, schedule preview, and live scheduler logs.

This project uses `whatsapp-web.js`, which automates WhatsApp Web through a linked-device session. It is not the official WhatsApp Business API.

## Requirements

- Node.js 18 or newer
- A WhatsApp account that can access the target group or chat
- The computer/server must stay awake and online while the scheduler is running

## Start The App

```bash
cd /Users/navjotsingh/Github/whatsapp-scheduler-bot
npm install
npm run ui
```

Open:

```text
http://127.0.0.1:3000
```

`npm run ui` starts the browser UI, WhatsApp connection, and scheduled sender in one process.

## First Login

If WhatsApp is not linked yet, the UI shows a centered QR code.

Scan it from your phone:

```text
WhatsApp > Settings > Linked Devices > Link a Device
```

After the scan succeeds, the Patrol Scheduler UI appears.

The session is saved in:

```text
.wwebjs_auth/
```

Use **Logout session** in the UI to clear the linked session and force a fresh QR login.

## Main UI Controls

- **WhatsApp group or chat**: searchable picker for the target group/chat.
- **Shift type**:
  - Day shift: `8:00 AM` to `8:00 PM`
  - Night shift: `8:00 PM` to `8:00 AM`
- **Weekly shift start days**: recurring weekly schedule.
- **This week only**: temporary shifts for the current week without changing the recurring pattern.
- **Other one-time shift dates**: specific exception dates outside the current week.
- **Patrol starts / Patrol ends**: custom start/end hours.
- **First message earliest/latest**: random first-message minute window after shift start.
- **Shortest/Longest gap**: random interval range between patrol messages.
- **Message**: WhatsApp message text.

Click **Save settings** to save changes. The button and header confirm when settings are saved.

## How Shift Days Work

The selected day is the day the shift starts.

Example night shift:

```text
Monday selected
8:00 PM to 8:00 AM
```

This means:

```text
Monday night through Tuesday morning
```

For a one-time Thursday shift this week only, use **This week only** instead of selecting Thursday as a weekly day.

## Schedule Preview

The UI shows:

- Next message
- Upcoming shifts grouped by shift window
- Past shifts, expandable

For overnight shifts, after-midnight messages are grouped under the shift start day and show the actual weekday beside the time.

You can also print the schedule in the terminal:

```bash
npm run list:schedule
```

This does not send messages.

## Scheduler Log

The UI includes a **Scheduler Log** panel that shows:

- WhatsApp ready state
- Next scheduled message time
- Message send attempts
- Successful sends
- WhatsApp message ID when available
- Send errors

Use this panel to verify that a scheduled message was actually sent.

## Important Runtime Behavior

The scheduler only runs while the Node process is running.

If your laptop shuts down, sleeps, loses internet, or the terminal process stops, messages will not send.

For continuous operation, run it on a server/VPS/EC2 instance and use a process manager such as `pm2`.

Example:

```bash
npm install -g pm2
pm2 start server.js --name whatsapp-patrol-scheduler
pm2 save
pm2 startup
```

## Useful Commands

Start UI and scheduler:

```bash
npm run ui
```

Preview schedule:

```bash
npm run list:schedule
```

Start guarded scheduler:

```bash
npm start
```

The old standalone sender is disabled because it bypasses the guarded scheduler.
Use the list command only for schedule previews:

```bash
npm run list:schedule
```

## Files

- `server.js`: local UI server, WhatsApp connection, scheduler, scheduler logs
- `scheduler.js`: shared schedule generation and config helpers
- `config.json`: saved settings
- `send-history.json`: local send/skip/failure history used by the guarded sender
- `public/`: browser UI
- `bot.js`: older standalone bot entrypoint
- `.wwebjs_auth/`: saved WhatsApp session
- `.wwebjs_cache/`: WhatsApp Web cache

## Safety Note

This project uses an unofficial WhatsApp Web automation library. It can work technically, but it is not the same as Meta's official WhatsApp Business Platform API and may carry account risk.

For production/commercial messaging, use the official WhatsApp Business Platform where possible.
