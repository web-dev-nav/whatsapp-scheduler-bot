# WatchPoint

WatchPoint is a WhatsApp patrol platform with two clearly separated parts:

- **Scheduler API** — a continuously running Node.js service that owns WhatsApp sessions, accounts, schedules, logs, and message delivery.
- **WatchPoint for iOS** — the primary user interface for connecting accounts, configuring messages and schedules, managing checkpoints, and running patrols.

The Node service is the only component that communicates with WhatsApp. The iOS app never embeds WhatsApp Web or sends WhatsApp messages directly.

WatchPoint supports a shared-device, multi-guard workflow. Each Scheduler account represents one guard and has its own WhatsApp session, schedule, checkpoints, patrol history, deduplication state, and guard name. Switching accounts stops any active patrol before loading the next guard's data. Network URLs and GPS thresholds remain device-wide settings.

> This project uses `whatsapp-web.js`, which automates a linked WhatsApp Web session. It is not the official WhatsApp Business API.

## Architecture

```text
                               Admin API
WatchPoint iOS  ──────────────────────────────────┐
  • accounts                                      │
  • WhatsApp QR/status                            ▼
  • message and schedule                 Scheduler API (Node.js)
  • activity                             • account authentication
                                         • WhatsApp Web sessions
WatchPoint iOS                            • schedule engine
  • GPS checkpoints                      • send guards and logs
  • patrol events                                 │
         │                                         ▼
         └── HTTPS ──> n8n webhook ──> patrol API ──> WhatsApp
```

The iOS app currently defaults to:

```text
Admin API:     https://hp-server.tailed5092.ts.net:10000
Patrol webhook: https://hp-server.tailed5092.ts.net/webhook/patrol-test
```

Both URLs can be changed from the app's Preferences screen.

## Repository Layout

```text
server.js                         HTTP API and WhatsApp runtimes
scheduler.js                      Config normalization and schedule generation
config.json                       Legacy/main-account configuration
public/                           Optional browser admin interface
n8n/                              Patrol webhook workflow export
ios/WatchPoint/                   Native SwiftUI application
ios/WatchPoint/WatchPoint/
  SchedulerAdminAPI.swift         API client and Keychain token storage
  AppState.swift                  App state, GPS, accounts, config, and logs
  AccountTab.swift                Account and WhatsApp connection UI
  SetupView.swift                 Message and schedule UI
  PatrolTab.swift                 Map, checkpoints, and active patrol UI
  ActivityTab.swift               Patrol and scheduler activity UI
  HostStatusView.swift             Host reachability and connection diagnostics
```

## Scheduler API

### Requirements

- Node.js 18–26
- npm
- Chrome or Chromium
- A machine that remains powered on while messages are scheduled

### Install and Run

```bash
npm ci
npm run ui
```

The default listener is:

```text
http://127.0.0.1:3000
```

Use a `.env` file for production:

```dotenv
HOST=127.0.0.1
PORT=3000
DATA_DIR=/home/navjot/.whatsapp-scheduler-bot
SESSION_TOKEN_TTL_HOURS=24
PATROL_TOKEN=replace-with-a-long-random-secret

# Set only when Chrome is not found automatically.
# CHROME_EXECUTABLE_PATH=/usr/bin/google-chrome
```

`PATROL_TOKEN` and `PATROL_TRIGGER_TOKEN` are accepted interchangeably. Prefer setting only `PATROL_TOKEN` so there is one unambiguous patrol secret.

### API Authentication

Each WhatsApp account has its own password. After login, the API returns a temporary session token. Send it on protected requests:

```http
X-Account-Auth: <session-token>
```

Tokens expire after `SESSION_TOKEN_TTL_HOURS`, which defaults to 24 hours. They are held in memory, so restarting the API also invalidates them. The iOS app stores tokens in the device Keychain and returns to the password screen when a token is rejected.

Login is limited to five failed attempts per account and IP in 15 minutes, followed by a 15-minute lockout.

### Endpoints

| Method | Path | Authentication | Purpose |
| --- | --- | --- | --- |
| `GET` | `/api/accounts` | None | List accounts |
| `POST` | `/api/accounts` | None | Create an account and password |
| `POST` | `/api/accounts/auth` | Password in body | Create a session token |
| `POST` | `/api/accounts/password` | Conditional | Set or change an account password |
| `DELETE` | `/api/accounts?account=<id>` | Account token | Remove a non-main account and its data |
| `GET` | `/api/whatsapp?account=<id>` | Account token | Get status, QR image, and chats |
| `POST` | `/api/whatsapp/logout?account=<id>` | Account token | Unlink the WhatsApp session |
| `GET` | `/api/config?account=<id>` | Account token | Read message and schedule configuration |
| `PUT` | `/api/config?account=<id>` | Account token | Save message and schedule configuration |
| `POST` | `/api/config/preview` | None | Preview a proposed schedule without saving |
| `GET` | `/api/logs?account=<id>` | Account token | Read scheduler activity |
| `POST` | `/api/patrol/trigger` | Patrol token or account token | Trigger a guarded patrol message |

### Account Example

Create an account:

```bash
curl -X POST http://127.0.0.1:3000/api/accounts \
  -H 'Content-Type: application/json' \
  -d '{"name":"Night Shift","password":"replace-this-password"}'
```

Log in:

```bash
curl -X POST http://127.0.0.1:3000/api/accounts/auth \
  -H 'Content-Type: application/json' \
  -d '{"account":"night-shift","password":"replace-this-password"}'
```

Use the returned token:

```bash
curl 'http://127.0.0.1:3000/api/whatsapp?account=night-shift' \
  -H 'X-Account-Auth: <session-token>'
```

### Patrol Trigger

When a patrol token is configured, send it as an `X-Patrol-Token` header, `token` query parameter, or JSON body property.

```bash
curl -X POST http://127.0.0.1:3000/api/patrol/trigger \
  -H 'Content-Type: application/json' \
  -H 'X-Patrol-Token: <patrol-token>' \
  -d '{
    "source":"watchpoint-ios",
    "guard":"Navjot",
    "checkpointName":"North entrance"
  }'
```

If `account` is omitted, the API selects a connected WhatsApp runtime. Specify `?account=<id>` when more than one connected account must be targeted explicitly.

Test the complete route without sending a WhatsApp message:

```text
POST /api/patrol/trigger?dryRun=1
```

Patrol triggers obey the configured cooldown and daily-send limits.

## WatchPoint for iOS

### Responsibilities

The iOS app provides the primary interface for:

- creating, selecting, and removing WhatsApp accounts;
- account password login with Keychain-backed tokens;
- displaying and sharing a WhatsApp pairing QR code;
- checking connection state and logging out a linked session;
- choosing a WhatsApp chat or group;
- editing the message, shift days, hours, and automatic-send state;
- viewing scheduler activity;
- viewing a day-grouped duty log with guard, GPS, retry, and response details;
- testing Admin API and n8n reachability from the Host & Connection screen;
- creating map checkpoints and adjusting their radius;
- detecting checkpoint entry and sending patrol events to n8n;
- retrying queued patrol events after temporary network failures.

The main account is intentionally protected from deletion. It can be logged out and re-linked.

### Open and Build

1. Open `ios/WatchPoint/WatchPoint.xcodeproj` in Xcode.
2. Select the `WatchPoint` target.
3. Choose the development team and bundle identifier appropriate for the device.
4. Build and run on an iPhone or simulator.

Command-line build example:

```bash
xcodebuild \
  -project ios/WatchPoint/WatchPoint.xcodeproj \
  -scheme WatchPoint \
  -sdk iphonesimulator \
  build
```

### First-Time Setup

1. Open **Account** in WatchPoint.
2. Confirm the Admin API URL in **Preferences**.
3. Select an account and enter its password.
4. If WhatsApp is not linked, display or share the QR code.
5. Scan it from WhatsApp under **Settings → Linked Devices → Link a Device**.
6. Open **Message & Schedule**, choose the chat, and save the schedule.
7. Open **Patrol**, create checkpoints, and grant location access.

QR pairing requires another display or device because the phone running WhatsApp cannot scan a QR shown on its own screen. WatchPoint provides full-screen and share actions for this reason.

### Patrol Data

WatchPoint checkpoints, patrol history, deduplication state, and guard name are stored locally on the iPhone under account-specific keys. Scheduler configuration and WhatsApp sessions are stored by the API. Saving a schedule from iOS round-trips the full server configuration so browser-created fields are not discarded.

Older global device data is migrated once into the account selected during the first launch after upgrading. Other accounts start with independent local patrol data.

## Persistent Server Data

Set `DATA_DIR` outside the Git checkout in production. The service stores:

```text
accounts.json
config.json
send-history.json
.wwebjs_auth/
accounts/<account-id>/config.json
accounts/<account-id>/send-history.json
accounts/<account-id>/.wwebjs_auth/
```

Do not delete `.wwebjs_auth` unless the account should be forced to pair with WhatsApp again.

## Production Deployment

Run exactly one Scheduler API process. That process manages every account and scheduler timer. Multiple processes would compete for the same WhatsApp sessions and schedule data.

Recommended production shape:

```text
systemd or Docker -> Node API on 127.0.0.1:3000
Tailscale Funnel  -> HTTPS admin endpoint -> 127.0.0.1:3000
n8n               -> internal POST /api/patrol/trigger
WatchPoint iOS    -> HTTPS admin endpoint and n8n webhook
```

Keep the admin API behind authenticated HTTPS. Use a strong `PATROL_TOKEN`, persistent `DATA_DIR`, and filesystem backups. Do not expose the raw Node port directly to the public internet.

The browser interface under `public/` remains available as a maintenance fallback. WatchPoint iOS is the intended day-to-day interface.

## Verification

Check JavaScript syntax:

```bash
npm run check
```

Print the generated schedule:

```bash
npm run list:schedule
```

Check API health and account discovery:

```bash
curl -fsS http://127.0.0.1:3000/api/accounts
```

For an end-to-end release, verify:

- the Scheduler API process is healthy;
- the Admin API HTTPS endpoint works over cellular data;
- iOS can authenticate and refresh WhatsApp status;
- QR pairing reaches `ready` state;
- iOS can save and reload message/schedule configuration;
- a dry-run patrol reaches the Scheduler API through n8n;
- a controlled live patrol sends one expected WhatsApp message.

## Security and Operational Notes

- `whatsapp-web.js` sessions can disconnect and occasionally require re-pairing.
- Account session tokens are temporary and are invalidated by API restarts.
- Never commit `.env`, account passwords, patrol tokens, or WhatsApp session directories.
- GPS patrol needs location permission. Background behavior is subject to iOS location rules.
- The API enforces cooldown and daily limits, but live-trigger tests should still use a dedicated test chat whenever possible.

## Planned API Additions

The iOS Host & Connection screen currently performs real reachability checks but cannot show engine uptime or session totals. A future read-only `GET /api/health` endpoint should provide engine version, Node version, uptime, server time, and total/connected account counts.

Scheduler log entries currently expose flattened display strings. Future optional `accountId`, `accountName`, `level`, and message metadata fields would allow the iOS duty log to attribute server events without inferring from the selected account.

## Planned iOS Additions

WatchPoint's shared-device, multi-guard model (see Architecture) raises two gaps not yet addressed:

- **App lock.** The device holds multiple guards' WhatsApp sessions, checkpoints, and history behind Keychain tokens that do not expire from the device's perspective. Nothing today stops anyone who picks up the device from seeing all of it. Planned: a Face ID/passcode gate on launch and on returning from background (`LocalAuthentication`, with device-passcode fallback), toggleable in Preferences and on by default for shared-device deployments.
- **Shift-change reconfirmation.** Nothing prompts a guard to confirm their identity when picking the device back up after a while, so a guard could unknowingly patrol under the previous guard's account if nobody remembered to switch. Planned: track a per-account "last confirmed" timestamp, and prompt ("Still {guard} on {account}? Yes / Switch Guard") on the Patrol tab if it's been more than a few hours since the account was last selected or confirmed.

Also recommended, but dependent on backend changes and out of scope for the iOS-only session:

- **Persist session tokens server-side** (not just in memory) so guards aren't logged out mid-shift by an unrelated engine restart or deploy — this already caused one dead-end-UI bug (see git history).
- **WhatsApp pairing-code login** (`client.requestPairingCode`) as the real fix for "can't scan a QR on the same phone you're reading it on," instead of the current QR-only flow.
- **Invite-link account creation**: a single-use, time-limited token generated server-side that, opened in WatchPoint via a deep link, creates a new guard's account automatically instead of typing a name/password into "Add Guard" — best paired with pairing-code login above so the whole onboarding flow works from one device.
