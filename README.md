# WhatsApp Patrol Scheduler

Local WhatsApp patrol scheduler with a browser UI, QR login, schedule preview, and live scheduler logs.

This project uses `whatsapp-web.js`, which automates WhatsApp Web through a linked-device session. It is not the official WhatsApp Business API.

## Installation

### 1. Install Requirements

Install these first:

- Node.js `18` or newer
- npm, included with Node.js
- Google Chrome or Chromium, used by `whatsapp-web.js`
- A WhatsApp account that can access the target group or chat
- A computer/server that stays awake and online while the scheduler is running

Check Node.js:

```bash
node -v
npm -v
```

This project supports Node versions:

```text
>=18 <27
```

### 2. Download The Repo

Clone the repo:

```bash
git clone git@github-personal:web-dev-nav/whatsapp-scheduler-bot.git
cd whatsapp-scheduler-bot
```

Or, if the repo is already on your computer:

```bash
cd /Users/navjotsingh/Github/whatsapp-scheduler-bot
git pull
```

### 3. Install Dependencies

```bash
npm install
```

### 4. Optional Environment Settings

The app works without a `.env` file for local use. By default it runs on:

```text
http://127.0.0.1:3000
```

For a normal local install, you can skip this step.

If you plan to expose the app through Tailscale Funnel, ngrok, Cloudflare Tunnel, Forge, or any public URL, set a patrol token so random visitors cannot trigger WhatsApp messages:

```bash
PATROL_TOKEN=change-this-token npm run ui
```

You can also create a `.env` file:

```bash
HOST=127.0.0.1
PORT=3000
PATROL_TOKEN=change-this-token
```

The token is only needed for the GPS patrol webhook. When `PATROL_TOKEN` is set, enter the same value in the **Patrol webhook token** field on `/patrol.html`.

### 5. Start The App

```bash
npm run ui
```

Open:

```text
http://127.0.0.1:3000
```

`npm run ui` starts the browser UI, WhatsApp connection, scheduled sender, and GPS patrol webhook in one process.

### 6. Link WhatsApp

If WhatsApp is not linked yet, the UI shows a QR code.

On your phone:

```text
WhatsApp > Settings > Linked Devices > Link a Device
```

Scan the QR code shown by the app. After linking, the app will load your WhatsApp chats and groups.

### 7. Configure The Scheduler

In the browser UI:

1. Choose the WhatsApp group or chat.
2. Set the message text.
3. Choose the shift days and shift time.
4. Turn automatic sending on or off.
5. Save the setup.

Use the schedule preview and activity log to confirm the setup.

### 8. Use GPS Patrol Mode

Open:

```text
http://127.0.0.1:3000/patrol.html
```

Then:

1. Select the sending account.
2. Enter the patrol webhook token if you started the app with `PATROL_TOKEN`.
3. Tap the map or use **Drop at my location** to add checkpoints.
4. Set the radius for each checkpoint.
5. Click **Save checkpoints**.
6. Click **Test connection (dry run — no message)**.
7. Click **Start live patrol** when you are ready.

When the phone enters a checkpoint circle, the server sends the saved WhatsApp patrol message.

### 9. iPhone And Tailscale Funnel Setup

Your iPhone cannot use your home Mac's `127.0.0.1` address. For real patrol use from a home Mac, expose the app with HTTPS.

Example with Tailscale Funnel:

```bash
PATROL_TOKEN=change-this-token npm run ui
```

In another terminal:

```bash
tailscale funnel 3000
```

Open the HTTPS Funnel URL on your iPhone:

```text
https://your-mac-name.your-tailnet.ts.net/patrol.html
```

Enter the same patrol token in the page. Then run the dry-run test.

Important iPhone notes:

- iPhone Safari requires HTTPS for GPS on non-localhost pages.
- Keep the Patrol Mode page open and the phone awake during live patrol.
- If you want background triggering with the screen off, use iPhone Shortcuts automation with the webhook URL.

### 10. Verify The Install

Run the syntax check:

```bash
npm run check
```

Preview the schedule in the terminal:

```bash
npm run list:schedule
```

Dry-run the GPS webhook without sending a message:

```bash
curl -sS -X POST 'http://127.0.0.1:3000/api/patrol/trigger?account=main&dryRun=1' \
  -H 'Content-Type: application/json' \
  -d '{"source":"install-test"}'
```

If `PATROL_TOKEN` is set, include it:

```bash
curl -sS -X POST 'http://127.0.0.1:3000/api/patrol/trigger?account=main&dryRun=1&token=change-this-token' \
  -H 'Content-Type: application/json' \
  -d '{"source":"install-test"}'
```

## Patrol Trigger API

This repo now exposes the patrol trigger endpoint used by the iPhone Shortcuts -> n8n flow in the automation PDF:

```text
POST /api/patrol/trigger?account=main
```

Dry run without sending a WhatsApp message:

```text
POST /api/patrol/trigger?account=main&dryRun=1
```

Optional `.env` token protection:

```text
PATROL_TRIGGER_TOKEN=your-secret
```

Then call:

```text
POST /api/patrol/trigger?account=main&token=your-secret
```

Example JSON body:

```json
{
  "source": "n8n-iphone-shortcuts",
  "guard": "Navjot",
  "checkpointName": "North checkpoint"
}
```

The configured message is sent immediately, and the trigger adds checkpoint and guard details at the bottom of the message when provided.

## Deploy To Laravel Forge

This app deploys to Forge as a Node.js service behind Nginx, with Forge running `npm start` as a daemon.

See [DEPLOY.md](DEPLOY.md) for the AWS / Laravel Forge deployment steps, daemon command, Nginx proxy block, and persistent data directory setup.

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

## Multiple WhatsApp Accounts

Use the account selector to add separate sender accounts, such as your account and a friend's account. Each account has its own WhatsApp QR login, saved session, target chat, schedule settings, send history, and scheduler timer.

Run only one Node/Forge daemon process. That single process manages all configured accounts.

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

## GPS Patrol Mode

Open:

```text
http://127.0.0.1:3000/patrol.html
```

Patrol Mode lets you save checkpoint pins on a map. While live patrol is running on your phone, the browser watches GPS; when the phone enters a checkpoint circle, it calls:

```text
POST /api/patrol/trigger?account=main
```

The server sends the same saved WhatsApp message to the configured group. The webhook keeps the normal anti-spam guards: minimum time between sends and daily send cap.

Important iPhone/local-Mac behavior:

- GPS works on `127.0.0.1`, but your iPhone cannot reach your Mac's `127.0.0.1`.
- iPhone Safari requires HTTPS for GPS on non-localhost pages.
- For real patrol use from a local Mac, run an HTTPS tunnel to port `3000`, then open the tunnel URL on the iPhone.
- Keep the Patrol Mode page open and the phone awake during the patrol. Browser GPS can pause when the screen locks.

Set a webhook token before exposing the app through a tunnel:

```bash
PATROL_TOKEN=change-this-token npm run ui
```

Then enter the same token in **Patrol webhook token** on `/patrol.html`. The token is saved only in that browser's local storage.

For a tunnel, use any HTTPS tunnel that forwards to `http://127.0.0.1:3000`, such as Cloudflare Tunnel or ngrok. The public URL will look like:

```text
https://your-tunnel.example/patrol.html
```

### iPhone Shortcuts Geofence

The in-app map is easiest when you can keep the page open. For background triggering on iPhone, use Shortcuts:

1. Start the app with `PATROL_TOKEN` set.
2. Make the Mac app reachable from the iPhone with an HTTPS tunnel or hosted domain.
3. Open iPhone **Shortcuts > Automation > New Automation > Arrive**.
4. Pick the patrol checkpoint location and choose **Run Immediately** if iOS offers it.
5. Add **Get Contents of URL**.
6. Set Method to `POST`.
7. Use this URL, changing the host/token/account:

```text
https://your-tunnel.example/api/patrol/trigger?account=main&token=change-this-token
```

8. Set the request body to JSON:

```json
{
  "source": "ios-shortcuts",
  "checkpointName": "North checkpoint"
}
```

Create one automation per checkpoint if you want different checkpoint names.

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
