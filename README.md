# WhatsApp Patrol Check-In Scheduler

This is a simple Node.js bot that sends randomized patrol completion messages to one WhatsApp group during configured overnight patrol windows.

## Requirements

- Node.js 18 or newer
- A WhatsApp account that is already a member of the target group
- Your computer must stay on while the bot is running

Your current Node version was checked during setup and is new enough.

## Files

- `bot.js` - the bot code
- `config.json` - group, message, and schedule settings
- `server.js` - local settings UI
- `public/` - browser UI files
- `.wwebjs_auth/` - saved WhatsApp login session after you scan the QR code
- `.wwebjs_cache/` - browser cache used by WhatsApp Web

## First Setup

1. Open this folder in Terminal:

   ```bash
   cd /Users/navjotsingh/Github/whatsapp-scheduler-bot
   ```

2. Start the local settings UI:

   ```bash
   npm run ui
   ```

3. Open this URL in your browser:

   ```text
   http://127.0.0.1:3000
   ```

4. If the WhatsApp QR code appears in the UI, scan it from WhatsApp:

   Open WhatsApp > Settings > Linked Devices > Link a Device

5. Once WhatsApp is connected, choose the target group or chat from the dropdown, then set the message text, active days, extra shift dates, and timing ranges.

6. Start test mode:

   ```bash
   npm run test:bot
   ```

7. If a QR code appears in the terminal, scan it. The bot also saves the latest QR code as `latest-qr.png` in this folder, which you can open and scan instead:

   Open WhatsApp > Settings > Linked Devices > Link a Device

   Then point your phone camera at the QR code in Terminal.

8. After WhatsApp connects, the bot looks for the configured chat name. In test mode, it sends this message 60 seconds after startup:

   ```text
   ✅ Test message from bot
   ```

The QR scan is normally only needed once. The login session is saved in `.wwebjs_auth/`.

## Settings UI

Start the local UI:

```bash
npm run ui
```

Then open:

```text
http://127.0.0.1:3000
```

The UI can change:

- WhatsApp group or chat
- Patrol message text
- Active weekdays
- One-time extra shift dates, shown with human-readable month names
- Shift start and end hour
- First message minute range
- Random interval range

The UI is local-only by default and binds to `127.0.0.1`.

Use **Logout session** in the WhatsApp Connection panel to clear the current linked session and force the UI back through the QR-code setup flow.

## Preview The Schedule

Run:

```bash
npm run list:schedule
```

This prints the same schedule the bot and UI use, without connecting to WhatsApp or sending messages.

## If The Group Is Not Found

The bot prints all available WhatsApp group names and exits.

Copy the exact group name from that list into the UI or `config.json`, then run test mode again:

```bash
npm run test:bot
```

## Run The Real Scheduler

After test mode works, start the normal scheduler:

```bash
npm start
```

The bot reads `config.json`, finds the next configured send time, sends the patrol message, and then schedules the next one. While running, it re-checks the config about once per minute so UI changes can take effect without restarting in most cases.

## Change Message Texts

Use the local UI or edit `config.json`.

## Stop The Bot

In Terminal, press:

```text
Ctrl+C
```

## Start Again Later

Run:

```bash
npm start
```

If the saved login is still valid, no QR code should be needed.

## Notes

- Do not delete `.wwebjs_auth/` unless you want to log in again.
- Do not hardcode a group ID. This bot always finds the group by name at startup.
- If Chromium fails to launch, copy the full terminal error so the missing system dependency or OS-specific issue can be diagnosed.
