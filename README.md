# WatchPoint

WatchPoint is a WhatsApp patrol platform with two parts:

- **Scheduler API** — a Node.js process that owns WhatsApp sessions, accounts, schedules, logs, and message delivery.
- **WatchPoint for iOS** — the day-to-day UI for signing in, linking WhatsApp, configuring messages, placing checkpoints, and running patrols.

The Node service is the system of record and the only component that talks to WhatsApp. The iPhone app sends GPS and authenticated commands; it does not send WhatsApp messages itself.

Each Scheduler account is one guard: its own WhatsApp session, schedule, checkpoints, patrol history, and settings. The phone stores only the API URL, the selected account id, and Keychain session tokens.

> The server uses `whatsapp-web.js` (a linked WhatsApp Web session). It is not the official WhatsApp Business API.

## How it works

```text
Guard uses WatchPoint on iPhone
              │
              │ HTTPS
              ▼
Scheduler API (accounts, rules, WhatsApp session)
              │
              │ WhatsApp Web
              ▼
Chosen group or chat
```

There is no n8n hop in the iOS path. `n8n/` and `POST /api/patrol/trigger` remain only for optional legacy automation.

### Automatic messages

The guard saves an automatic message and shift schedule under **Account → Automatic Message & Schedule**. The server waits for an allowed send time and delivers that text to the shared destination. This continues even if the iPhone app is closed.

### Patrol messages

The guard starts a live patrol on the **Patrol** tab. The iPhone sends GPS samples to `POST /api/patrol/location`. The server checks accuracy, distance, outside-to-inside entry, the **minimum interval** between any two WhatsApp sends, and the **same-checkpoint cooldown**. On a valid arrival it sends the **patrol arrival** text only (no `Checkpoint:` / `Guard:` footer in WhatsApp). Checkpoint and guard names stay in WatchPoint activity.

Automatic and patrol texts are separate. They share one WhatsApp destination (**Account → Shared Destination Chat**) and one minimum send interval (**Account → Message Spacing**).

## Current production URL

The iOS app defaults to:

```text
https://hp-server.tailed5092.ts.net:10000
```

Change it under **Account → Server**. Do not point the app at an n8n or patrol-webhook URL.

Engine version comes from `package.json` (currently **1.3.0**). WatchPoint iOS requires engine **1.3.0** or newer (`AppRelease.requiredEngineVersion`). The server may also require a minimum app version via `minimumIOSVersion` (default `1.2`, override with `MINIMUM_IOS_VERSION`).

## Repository layout

```text
server.js                         HTTP API and WhatsApp runtimes
scheduler.js                      Config normalization and schedule generation
env.js                            .env loader
config.json                       Legacy/main-account configuration
public/                           Optional browser admin UI
n8n/                              Legacy external trigger export
ios/WatchPoint/                   SwiftUI app
ios/WatchPoint/WatchPoint/
  LoginView.swift                 Sign in / sign up, then WhatsApp QR gate
  ContentView.swift               App lock, pairing gate, Patrol / Activity / Account
  PatrolTab.swift                 Map, checkpoints, live patrol, send spacing
  ActivityTab.swift               Scheduled and patrol activity
  AccountTab.swift                Guard, spacing, messages, server ping
  DeliverySettingsView.swift      Shared WhatsApp destination only
  SetupView.swift                 Automatic message and schedule
  PatrolMessageView.swift         Patrol arrival message
  HostStatusView.swift            Server ping / versions
  AppState.swift                  Session, GPS, API state
  SchedulerAdminAPI.swift         HTTP client and Keychain tokens
```

## Scheduler API

### Requirements

- Node.js 18–26 (`package.json` engines)
- npm
- Chrome or Chromium
- A host that stays powered on while automatic messages are scheduled

### Install and run

```bash
npm ci
npm run ui
```

Default listen address: `http://127.0.0.1:3000`.

Production `.env` example:

```dotenv
HOST=127.0.0.1
PORT=3000
DATA_DIR=/home/navjot/.whatsapp-scheduler-bot
SESSION_TOKEN_TTL_HOURS=24
MINIMUM_IOS_VERSION=1.2
PATROL_TOKEN=replace-with-a-long-random-secret

# Only if Chrome is not found automatically:
# CHROME_EXECUTABLE_PATH=/usr/bin/google-chrome
```

`PATROL_TOKEN` and `PATROL_TRIGGER_TOKEN` are interchangeable. Prefer setting only `PATROL_TOKEN`.

Scripts:

| Script | Purpose |
| --- | --- |
| `npm run ui` / `npm start` | Run the Scheduler API |
| `npm run start:prod` | Run with `NODE_ENV=production` |
| `npm run check` | Syntax-check server, scheduler, bot, and public JS |
| `npm run list:schedule` | Print the generated schedule |
| `npm run test:bot` | Bot test helper |

### Authentication

Each account has its own password. `POST /api/accounts/auth` returns a session token. Send it as:

```http
X-Account-Auth: <session-token>
```

Query `token=` is also accepted (used by the browser pairing page). Tokens live in memory for `SESSION_TOKEN_TTL_HOURS` (default 24). Restarting the API invalidates them. Login is limited to five failures per account and IP in 15 minutes, then a 15-minute lockout.

### WhatsApp pairing (iOS signup)

1. Sign Up with account name and password.
2. WatchPoint shows a **pairing-only** screen until WhatsApp status is `ready`. Patrol, Activity, and Account are blocked until then.
3. Scan the in-app QR from WhatsApp → **Settings → Linked devices → Link a device**.

Optional browser QR (for another phone). The production host typically forwards only `/api`, so use:

```text
https://<host>:<port>/api/pair?account=<account-id>&token=<session-token>
```

`GET /pair.html` exists in `server.js` but will 405 if the reverse proxy does not forward non-`/api` GETs. Prefer `/api/pair`. The handler embeds the current QR in HTML when the token is valid, then polls `GET /api/whatsapp`.

```bash
curl -sI "https://hp-server.tailed5092.ts.net:10000/api/pair?account=<id>&token=<token>"
```

Expect HTTP 200 and `content-type: text/html`. Treat that URL like a password until WhatsApp is linked.

### Endpoints

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/health` | None | Engine version, uptime, account/session counts |
| `GET` | `/api/pair` | `account` + `token` query | Browser WhatsApp QR page |
| `GET` | `/api/accounts` | None | List accounts |
| `POST` | `/api/accounts` | None | Create account; returns token |
| `POST` | `/api/accounts/auth` | Password in body | Create session token |
| `POST` | `/api/accounts/password` | Conditional | Set or change password |
| `DELETE` | `/api/accounts?account=<id>` | Account token | Delete a non-last account |
| `GET` | `/api/whatsapp?account=<id>` | Account token | Status, QR data URL, chats |
| `POST` | `/api/whatsapp/logout?account=<id>` | Account token | Unlink WhatsApp |
| `GET` | `/api/config?account=<id>` | Account token | Destination, delivery interval, schedule, patrol message |
| `PUT` | `/api/config?account=<id>` | Account token | Save that configuration |
| `POST` | `/api/config/preview` | None | Preview a proposed schedule |
| `GET` | `/api/logs?account=<id>` | Account token | Scheduler activity |
| `DELETE` | `/api/logs?account=<id>&scope=all\|schedule\|patrol` | Account token | Clear visible logs (and patrol history for `all`/`patrol`); keep send-history/dedupe |
| `GET` | `/api/patrol/state?account=<id>` | Account token | Profile, settings, checkpoints, history, session |
| `PUT` | `/api/patrol/state?account=<id>` | Account token | Save profile, settings, checkpoints, session |
| `POST` | `/api/patrol/import?account=<id>` | Account token | One-time import of legacy iOS patrol data |
| `POST` | `/api/patrol/location?account=<id>` | Account token | GPS sample; server decides checkpoint arrivals |
| `POST` | `/api/patrol/events?account=<id>` | Account token | Manual test arrival |
| `POST` | `/api/patrol/events/retry?account=<id>` | Account token | Retry failed/queued patrol events |
| `GET` | `/api/patrol/status?account=<id>` | Account token | Min interval, checkpoint cooldown, next allowed send |
| `POST` | `/api/patrol/trigger` | Patrol token or account token | Legacy external send |

### Health payload

`GET /api/health` is unauthenticated so the app can ping the engine before login. It does not include account names, tokens, chats, or phone numbers.

```json
{
  "status": "ok",
  "engineVersion": "1.3.0",
  "minimumIOSVersion": "1.2",
  "nodeVersion": "v22.22.1",
  "startedAt": "2026-08-22T08:45:09.487Z",
  "uptimeSeconds": 3600,
  "serverTime": "2026-08-23T13:00:00.000Z",
  "totalAccounts": 3,
  "connectedAccounts": 1,
  "activeSessions": 2
}
```

`connectedAccounts` counts WhatsApp runtimes with status `ready`. `activeSessions` counts unexpired login tokens (expired tokens are dropped while health is built). iOS decodes this as `SchedulerHealth` in `SchedulerAdminAPI.swift`. **Account → Server → Test Server Connection** pings this URL and shows round-trip time.

### Patrol state

After login, iOS loads:

```http
GET /api/patrol/state?account=<id>
X-Account-Auth: <session-token>
```

Authoritative shape:

```json
{
  "account": { "id": "night-shift", "name": "Night Shift", "hasPassword": true },
  "profile": { "name": "Navjot" },
  "settings": {
    "accuracyThresholdMeters": 50,
    "checkpointCooldownMinutes": 12
  },
  "checkpoints": [
    {
      "id": "4f604bc1-761a-4ed7-a49c-e68146db12fe",
      "name": "North entrance",
      "latitude": 43.1394,
      "longitude": -80.2644,
      "radiusMeters": 100
    }
  ],
  "history": [],
  "session": {
    "active": false,
    "updatedAt": "2026-08-19T13:00:00.000Z"
  }
}
```

Keep this in memory for UI only. Saves must `PUT` the full `profile`, `settings`, `checkpoints`, and `session`, then replace local state with the response.

Checkpoint cooldown on iOS is **5–120 minutes** (5-minute steps). The API clamps cooldown to **1–240 minutes**. Accuracy is clamped **5–200 m** (iOS UI 10–100 m).

### GPS samples

While `session.active` is true, iOS posts:

```http
POST /api/patrol/location?account=<id>
X-Account-Auth: <session-token>
Content-Type: application/json

{
  "source": "watchpoint-ios",
  "lat": 43.1394,
  "lng": -80.2644,
  "accuracyMeters": 12
}
```

The server applies accuracy, geofence entry, per-checkpoint cooldown, and the shared `delivery.minMessageIntervalMinutes`. WhatsApp text is the patrol message with any `Checkpoint:` / `Guard:` footer stripped.

Manual test: `POST /api/patrol/events`. Retry: `POST /api/patrol/events/retry`. Do not call `/api/patrol/trigger` from iOS.

### Config (messages and schedule)

`GET`/`PUT /api/config` carries `groupName`, `timezone`, `message` (automatic), `delivery.minMessageIntervalMinutes`, `schedule`, and `patrol.message`. Minimum interval is edited on **Account → Message Spacing** (0–240 minutes, 5-minute steps), not on the destination screen.

Automatic schedule `minSendIntervalMinutes` is separate (75–240 minutes) and only applies to the timed scheduler.

### Logs

`GET /api/logs` returns entries with `type`, `category` (`schedule`, `patrol`, or `system`), `message`, and timestamps. “Automatic scheduled messages are disabled” is logged only when a running timer is actually stopped, not on every config save.

### Example

```bash
curl -X POST http://127.0.0.1:3000/api/accounts \
  -H 'Content-Type: application/json' \
  -d '{"name":"Night Shift","password":"replace-this-password"}'

curl -X POST http://127.0.0.1:3000/api/accounts/auth \
  -H 'Content-Type: application/json' \
  -d '{"account":"night-shift","password":"replace-this-password"}'

curl 'http://127.0.0.1:3000/api/whatsapp?account=night-shift' \
  -H 'X-Account-Auth: <session-token>'
```

### Legacy patrol trigger

Not used by iOS. External tools may post when `PATROL_TOKEN` is set (`X-Patrol-Token`, `?token=`, or JSON `token`).

```bash
curl -X POST http://127.0.0.1:3000/api/patrol/trigger \
  -H 'Content-Type: application/json' \
  -H 'X-Patrol-Token: <patrol-token>' \
  -d '{"source":"external","guard":"Navjot","checkpointName":"North entrance"}'
```

`?dryRun=1` exercises the route without sending WhatsApp. Cooldown and daily caps still apply.

## WatchPoint for iOS

### Screens

| Screen | Role |
| --- | --- |
| Sign In | Account name + password; Sign In or Sign Up |
| Link WhatsApp | QR, share pairing link, open in browser; Sign Out. No other tabs |
| Patrol | Live patrol, map, checkpoints, next-send countdown |
| Activity | Scheduled vs patrol logs; clear by scope |
| Account | Guard name, Face ID lock, GPS accuracy, message spacing, destination, automatic message, patrol message, server URL + ping |

App lock uses **Face ID** once the window is active (recent device Face ID may be reused for a few seconds). **Use Passcode** is optional. After four hours, Patrol asks the guard to confirm they are still the same person.

The last remaining server account cannot be deleted.

### Build

1. Open `ios/WatchPoint/WatchPoint.xcodeproj`.
2. Select the WatchPoint target, team, and bundle id (`Brainandbolt.WatchPoint`).
3. Run on an iPhone (Face ID and background location need a device).

```bash
xcodebuild \
  -project ios/WatchPoint/WatchPoint.xcodeproj \
  -scheme WatchPoint \
  -sdk iphonesimulator \
  build
```

### First-time setup

1. Sign Up (or Sign In) with a guard name and password.
2. Scan the pairing QR from another phone’s WhatsApp (or share `/api/pair` after the server is updated).
3. When WhatsApp is **ready**, set **Shared Destination Chat**.
4. Set **Message Spacing** (minimum interval and same-checkpoint cooldown).
5. Set automatic message/schedule and patrol arrival message.
6. On Patrol, add checkpoints and allow location (Always for background patrol).

QR pairing needs a second screen: the phone that runs WhatsApp cannot scan a QR on itself.

## Persistent server data

Set `DATA_DIR` outside the git checkout in production:

```text
accounts.json
config.json
send-history.json
patrol-state.json
.wwebjs_auth/
accounts/<account-id>/config.json
accounts/<account-id>/send-history.json
accounts/<account-id>/patrol-state.json
accounts/<account-id>/.wwebjs_auth/
```

Do not delete `.wwebjs_auth` unless you intend to force a new WhatsApp pair.

## Production

Run **one** Scheduler process. Two processes would fight over WhatsApp sessions and timers.

```text
systemd → Node on 127.0.0.1:3000
Tailscale / TLS  → HTTPS :10000 → 127.0.0.1:3000
WatchPoint iOS   → that HTTPS URL
```

Forward `/api` (including `GET /api/pair`, `/api/health`, `/api/whatsapp`) to Node. Keep `DATA_DIR` on persistent disk and back it up. Do not expose the raw Node port on the public internet.

`public/` is a maintenance UI. iOS is the intended daily client.

Upgrade order: back up `DATA_DIR`, deploy Node, confirm `GET /api/health` then authenticated patrol/config, then ship iOS. Restarting the API logs everyone out (in-memory tokens).

## Verification

```bash
npm run check
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS http://127.0.0.1:3000/api/accounts
```

Release checks:

- HTTPS health over cellular
- Sign up → QR → WhatsApp `ready`
- Destination and spacing save once (interval only on Account)
- Automatic and patrol messages save independently
- Patrol start/stop persists; GPS hits `/api/patrol/location`
- WhatsApp receives only the message body
- Activity does not spam “scheduled messages are disabled”
- Face ID unlocks after returning from background
- Second device or fresh install reloads checkpoints from the API

## Security

- WhatsApp Web sessions can drop and need re-pairing.
- Session tokens die on API restart.
- Never commit `.env`, passwords, patrol tokens, or `.wwebjs_auth`.
- Background patrol depends on iOS location permission.
- Use a dedicated test chat for live send tests.

## API compatibility

iOS depends on `/api/health`, `/api/pair`, structured logs, config `delivery`, and the patrol endpoints above. Add fields freely; do not rename existing ones without updating `SchedulerAdminAPI.swift`, `WatchPointModels.swift`, and this file together. Always trust the JSON the server returns after a write, not the payload the client sent.
