# WatchPoint

WatchPoint is a WhatsApp patrol platform with two clearly separated parts:

- **Scheduler API** — a continuously running Node.js service that owns WhatsApp sessions, accounts, schedules, logs, and message delivery.
- **WatchPoint for iOS** — the primary user interface for connecting accounts, configuring messages and schedules, managing checkpoints, and running patrols.

The Node service is the system of record and the only component that communicates with WhatsApp. The iOS app is an API-driven UI: it collects device GPS, renders server data, and sends authenticated commands, but it does not own patrol business state or message delivery.

WatchPoint supports a shared-device, multi-guard workflow. Each Scheduler account represents one guard and has its own WhatsApp session, schedule, checkpoints, patrol history, active-patrol state, deduplication state, settings, and guard profile on the server. Switching accounts stops the old account's patrol through the API before loading the next account. Only the API base URL, selected-account pointer, and Keychain login tokens remain device-local.

> This project uses `whatsapp-web.js`, which automates a linked WhatsApp Web session. It is not the official WhatsApp Business API.

## Architecture

```text
WatchPoint iOS                         Scheduler API (Node.js)
  • SwiftUI screens     HTTPS/JSON       • authentication
  • Keychain token  ──────────────────>  • account-scoped persistence
  • device GPS samples                   • checkpoints and patrol sessions
  • map and forms      <────────────────  • GPS transition/dedupe engine
                                          • schedules, history, and logs
                                          • WhatsApp Web sessions
                                                    │
                                                    ▼
                                                WhatsApp
```

The iOS app currently defaults to:

```text
Scheduler API: https://hp-server.tailed5092.ts.net:10000
```

The URL can be changed from the app's Preferences screen. iOS must not be configured with an n8n or patrol-webhook URL; patrol traffic uses the authenticated Scheduler API.

## Repository Layout

```text
server.js                         HTTP API and WhatsApp runtimes
scheduler.js                      Config normalization and schedule generation
config.json                       Legacy/main-account configuration
public/                           Optional browser admin interface
n8n/                              Legacy/optional external integration export
ios/WatchPoint/                   Native SwiftUI application
ios/WatchPoint/WatchPoint/
  SchedulerAdminAPI.swift         API client and Keychain token storage
  AppState.swift                  API-backed UI state and device GPS forwarding
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
| `GET` | `/api/health` | None | Read engine health, uptime, versions, and account/session totals |
| `GET` | `/api/accounts` | None | List accounts |
| `POST` | `/api/accounts` | None | Create an account and password |
| `POST` | `/api/accounts/auth` | Password in body | Create a session token |
| `POST` | `/api/accounts/password` | Conditional | Set or change an account password |
| `DELETE` | `/api/accounts?account=<id>` | Account token | Remove a non-main account and its data |
| `GET` | `/api/whatsapp?account=<id>` | Account token | Get status, QR image, and chats |
| `POST` | `/api/whatsapp/logout?account=<id>` | Account token | Unlink the WhatsApp session |
| `GET` | `/api/config?account=<id>` | Account token | Read shared delivery, automatic-message, patrol-message, and schedule configuration |
| `PUT` | `/api/config?account=<id>` | Account token | Save shared delivery, automatic-message, patrol-message, and schedule configuration |
| `POST` | `/api/config/preview` | None | Preview a proposed schedule without saving |
| `GET` | `/api/logs?account=<id>` | Account token | Read scheduler activity |
| `GET` | `/api/patrol/state?account=<id>` | Account token | Read profile, settings, checkpoints, history, and patrol session |
| `PUT` | `/api/patrol/state?account=<id>` | Account token | Save profile, settings, checkpoints, and active-patrol state |
| `POST` | `/api/patrol/import?account=<id>` | Account token | One-time import of legacy iOS patrol data into an empty server state |
| `POST` | `/api/patrol/location?account=<id>` | Account token | Process an iOS GPS sample and trigger checkpoint-entry events |
| `POST` | `/api/patrol/events?account=<id>` | Account token | Manually trigger a checkpoint arrival from the UI |
| `POST` | `/api/patrol/events/retry?account=<id>` | Account token | Retry queued, failed, or engine-not-ready patrol events |
| `POST` | `/api/patrol/trigger` | Patrol token or account token | Legacy external-integration message trigger |

### iOS Server Contract

The Host & Connection screen reads `GET /api/health`. The endpoint is intentionally unauthenticated so the app can diagnose the engine before an account login succeeds. It does not expose account names, tokens, configuration, chats, or phone numbers.

Example response:

```json
{
  "status": "ok",
  "engineVersion": "1.2.0",
  "nodeVersion": "v26.0.0",
  "startedAt": "2026-08-19T12:00:00.000Z",
  "uptimeSeconds": 3600,
  "serverTime": "2026-08-19T13:00:00.000Z",
  "totalAccounts": 3,
  "connectedAccounts": 2,
  "activeSessions": 2
}
```

`connectedAccounts` counts WhatsApp runtimes in the `ready` state. `activeSessions` counts unexpired Admin API login tokens; expired tokens are removed while health is calculated. The iOS model for this payload is `SchedulerHealth` in `SchedulerAdminAPI.swift`.

Scheduler entries returned by `GET /api/logs?account=<id>` include stable structured attribution in addition to their display text:

```json
{
  "id": "1787144400000-a1b2c3",
  "type": "success",
  "message": "Patrol message sent to \"Operations\" via watchpoint-ios.",
  "timestamp": "2026-08-19T13:00:00.000Z",
  "label": "Aug 19, 2026, 9:00:00 AM",
  "accountId": "night-shift",
  "accountName": "Night Shift",
  "details": {
    "chatName": "Operations",
    "messageId": "..."
  }
}
```

The iOS client decodes `accountId` and `accountName` as optional fields for compatibility with older servers. `type` is the log severity/category (`info`, `success`, `error`, or `scheduled`). `details` is event-specific metadata and clients should tolerate unknown keys.

#### Patrol state

After account login or account switching, iOS must call:

```http
GET /api/patrol/state?account=<id>
X-Account-Auth: <session-token>
```

The response is the authoritative UI model:

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

iOS may keep this response in memory for rendering, but must not persist these domain fields in `UserDefaults`, files, Core Data, or another local database. To edit them, send the complete `profile`, `settings`, `checkpoints`, and `session` values to `PUT /api/patrol/state`; then replace the in-memory UI model with the returned normalized state.

#### GPS and patrol events

Starting or stopping a patrol is a state update with `session.active` set to `true` or `false`. While the returned session is active, iOS sends device location samples:

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

The server—not iOS—applies the accuracy threshold, calculates checkpoint distance, detects outside-to-inside transitions, enforces per-checkpoint cooldown, creates history, and calls the guarded WhatsApp sender. Checkpoint arrivals use this per-checkpoint cooldown rather than the automatic scheduler's global message gap, so visiting multiple checkpoints during one patrol is allowed. The response contains `ignored`, any newly created `events`, and the latest full `state`; iOS replaces its in-memory patrol model with that state.

For the **Send Test Arrival** UI action, call `POST /api/patrol/events` with `checkpointId`, source, event type, and optional current GPS values. For **Retry Queue**, call `POST /api/patrol/events/retry`. Both return the latest state. Do not call `/api/patrol/trigger` from the iOS app; that endpoint remains only for legacy automation or external services authenticated with `PATROL_TOKEN`.

#### Upgrade migration

Older app builds stored patrol data locally. On the first authenticated load per account, the updated iOS client reads those legacy keys once and calls `POST /api/patrol/import`. The server imports checkpoints/history only when the corresponding server collection is empty, normalizes the result, and returns the authoritative state. After a successful import, iOS deletes the legacy local keys and records only a migration-complete marker.

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

### Legacy External Patrol Trigger

This route is not part of the iOS flow. External automation can use it when a patrol token is configured, supplied as an `X-Patrol-Token` header, `token` query parameter, or JSON body property.

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
- testing Scheduler API health from the Host & Connection screen;
- creating map checkpoints and adjusting their radius;
- forwarding device GPS samples to the authenticated Scheduler API;
- presenting server-detected checkpoint arrivals and retrying server-owned events.

Any account, including `main`, can be removed when at least one other guard account exists. The final remaining account is protected from deletion so the service always retains a usable account. Removing `main` deletes only its known root-level config, history, patrol state, and WhatsApp authentication directory; it never deletes the shared `DATA_DIR` or other guards.

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
6. Open **Shared Delivery Settings**, select the WhatsApp destination, and choose the minimum interval used by both send paths.
7. Open **Automatic Message & Schedule** and save the timed schedule and its message.
8. Open **Patrol Arrival Message** and set the separate text sent on checkpoint entry.
9. Open **Patrol**, create checkpoints, and grant location access.

QR pairing requires another display or device because the phone running WhatsApp cannot scan a QR shown on its own screen. WatchPoint provides full-screen and share actions for this reason.

### Patrol Data

The Scheduler API stores the guard profile, GPS settings, checkpoints, active-patrol state, transition/deduplication state, patrol history, schedule configuration, and WhatsApp session under the selected account. The iOS app holds the latest API response in memory only for rendering.

The API base URL, selected-account pointer, temporary Keychain token, current device GPS fix, and location permission are necessarily device-local. They are connection/UI concerns, not patrol business records. Legacy iOS patrol records are imported once as described in the iOS Server Contract.

## Persistent Server Data

Set `DATA_DIR` outside the Git checkout in production. The service stores:

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

Do not delete `.wwebjs_auth` unless the account should be forced to pair with WhatsApp again.

## Production Deployment

Run exactly one Scheduler API process. That process manages every account and scheduler timer. Multiple processes would compete for the same WhatsApp sessions and schedule data.

Recommended production shape:

```text
systemd or Docker -> Node API on 127.0.0.1:3000
Tailscale Funnel  -> HTTPS admin endpoint -> 127.0.0.1:3000
WatchPoint iOS    -> one HTTPS Scheduler API endpoint
Optional n8n      -> legacy external POST /api/patrol/trigger
```

Keep the admin API behind authenticated HTTPS. Use a strong `PATROL_TOKEN`, persistent `DATA_DIR`, and filesystem backups. Do not expose the raw Node port directly to the public internet.

The browser interface under `public/` remains available as a maintenance fallback. WatchPoint iOS is the intended day-to-day interface.

### API-First Upgrade Order

Deploy the server before distributing the updated iOS app:

1. Back up the complete production `DATA_DIR`.
2. Deploy the Node changes and restart the single Scheduler API process.
3. Confirm `GET /api/health`, then authenticate a test account and confirm `GET /api/patrol/state?account=<id>` returns `200`.
4. Confirm the process can create and retain `patrol-state.json` under `DATA_DIR`.
5. Release the updated iOS build only after those checks pass.
6. On the first iOS login for each existing account, allow the legacy import to finish before editing checkpoints or starting patrol.
7. Confirm checkpoints/history reload after force-quitting and reopening the app, then include `patrol-state.json` in normal backups.

The old iOS build can continue using its local data and n8n path during a staged server rollout. The new iOS build requires the new patrol endpoints and should not be released against an older server. Do not remove the legacy `/api/patrol/trigger` or n8n workflow until all deployed phones have upgraded and their local data has been imported.

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
- iOS can independently save and reload automatic and patrol-arrival messages;
- starting/stopping patrol persists through `/api/patrol/state`;
- GPS samples reach `/api/patrol/location` without duplicating an inside transition;
- checkpoints and history reload from the API on a second device or fresh app launch;
- a controlled live patrol sends one expected WhatsApp message.

## Security and Operational Notes

- `whatsapp-web.js` sessions can disconnect and occasionally require re-pairing.
- Account session tokens are temporary and are invalidated by API restarts.
- Never commit `.env`, account passwords, patrol tokens, or WhatsApp session directories.
- GPS patrol needs location permission. Background behavior is subject to iOS location rules.
- The API enforces cooldown and daily limits, but live-trigger tests should still use a dedicated test chat whenever possible.

## API Compatibility

The iOS app consumes `/api/health`, structured scheduler logs, and every authenticated patrol endpoint documented above. Keep these fields backward compatible when evolving the server. New response fields may be added, but existing field names and types should not change without updating `SchedulerAdminAPI.swift`, `WatchPointModels.swift`, and this contract together. Every iOS mutation must use the state returned by the API rather than assuming the submitted value was accepted unchanged.

Engine `1.2.0` introduces account-level shared delivery settings. `groupName` and `delivery.minMessageIntervalMinutes` apply to both automatic and patrol-arrival messages, while their message bodies remain separate. Older configs normalize the shared interval to zero, preventing the former automatic-scheduler 75-minute floor from blocking checkpoints in the same patrol. Older clients preserve these server fields during unrelated config saves.

### Implementation Record — 2026-08-19

The server-to-iOS diagnostics handoff was implemented across the following components:

- `server.js` exposes the unauthenticated, non-sensitive `GET /api/health` response and removes expired Admin API sessions while calculating `activeSessions`.
- `SchedulerAdminAPI.swift` defines `SchedulerHealth` and provides the iOS health request.
- `HostStatusView.swift` replaces the generic Admin API reachability probe with the semantic health check and displays engine version, Node version, uptime, connected WhatsApp accounts, and active logins.
- `WatchPointModels.swift` decodes optional `accountId` and `accountName` scheduler-log attribution for compatibility with both updated and older servers.
- `ActivityTab.swift` displays the attributed account name and log category.
- This README defines the API payloads and compatibility rules that must be passed forward with future server or iOS changes.

Verification completed on 2026-08-19:

- `npm run check` passed for all JavaScript entry points.
- An isolated live server returned a valid `200` response from `/api/health`.
- `git diff --check` passed.
- An iOS/Xcode build was not run in the Linux server environment because Xcode is unavailable; the Swift changes require final compilation in Xcode before an iOS release.

### API-First Patrol Record — 2026-08-19

The patrol domain was moved from iOS local storage and the n8n send path into the Scheduler API:

- The engine version was raised to `1.1.0` for the new patrol API contract.
- The iOS marketing/build version was raised to `1.1 (2)` so the API-first client can be distinguished during staged deployment.
- `server.js` persists per-account `patrol-state.json`, normalizes profile/settings/checkpoints, owns active-patrol and deduplication state, calculates GPS transitions, records delivery history, retries events, and invokes WhatsApp delivery.
- `SchedulerAdminAPI.swift` is the single iOS transport for patrol reads, writes, GPS samples, manual events, retries, and legacy import.
- `AppState.swift` retains API responses only in memory, forwards device location samples, and reloads returned server state after every patrol operation.
- `PatrolTab.swift`, `AccountTab.swift`, `PreferencesView.swift`, and `HostStatusView.swift` use the single API-backed flow; the n8n URL UI and direct webhook service were removed.
- Legacy per-account or global iOS data is imported once into empty server collections, then removed from local storage.
- `config.json` patrol checkpoints remain synchronized with `patrol-state.json` for browser/config compatibility.

Server validation completed with `npm run check`, `git diff --check`, and isolated authenticated smoke tests covering legacy import, state creation, checkpoint/settings persistence, patrol start, inaccurate-location rejection, accurate checkpoint entry, concurrent duplicate suppression, event persistence, engine-not-ready delivery status, and retry-count persistence. Xcode verification is still required on macOS before release.

### Recheck Record — 2026-08-20

A clean re-audit against `origin/main` repeated JavaScript validation and authenticated API tests for health, normalized state writes, accuracy filtering, concurrent transition deduplication, manual-coordinate fallback, retries, history, and persistence across a process restart. The review also tightened two state rules: dedupe entries for deleted checkpoints are pruned during normalization, and one-time legacy import only replaces profile/settings while those server fields still have their defaults. Existing customized server settings remain authoritative. Targeted follow-up tests confirmed both dedupe pruning after checkpoint deletion and protection of customized profile/settings during legacy import.

### Production Deployment Record — 2026-08-20

Commit `6de3122` (including the API-first work in `11b9caf`) was deployed on `Hp-server` through `whatsapp-scheduler.service`. Before installation, the service was stopped and the complete 38 MB `DATA_DIR` (`/home/navjot/.whatsapp-scheduler-bot`) was archived to `/home/navjot/watchpoint-backups/2026-08-20-pre-api-first.tar.gz`; the resulting 19 MB archive was listed successfully and contains account configuration and `.wwebjs_auth` session data. `git pull --ff-only` confirmed the checkout was current, `npm ci` completed, and `npm run check` passed.

Both `whatsapp-scheduler.service` and `tailscale-admin-funnel.service` were restarted. External `GET https://hp-server.tailed5092.ts.net:10000/api/health` returned `200` with engine `1.1.0`; `/api/accounts` returned the main account; and unauthenticated patrol-state/location probes returned the expected `401 requiresLogin` rather than `404`, confirming the new routes are live. Restarting the API invalidated in-memory Admin tokens, so iOS users must enter the account password again.

At the end of deployment, API/Funnel health was good but `/api/health` still reported `connectedAccounts: 0`. One controlled Scheduler retry did not restore WhatsApp readiness. The production log shows WhatsApp browser startup failures began before this deployment, and direct access to `web.whatsapp.com` succeeds, so this is tracked as a pre-existing saved-session/browser recovery issue rather than an API rollout failure. Do not delete `.wwebjs_auth`; use the iOS Account screen to inspect status and re-link WhatsApp only if the saved session does not recover. `npm ci` also reported eight high-severity transitive dependency findings; no automatic audit fix was applied because forced dependency changes could be breaking and require a separate reviewed upgrade.

### Pending 1.2.0 Server Handoff — 2026-08-20

Production remains on engine `1.1.0`. The `1.2.0` implementation is now present in this local working tree but has not been committed or pushed to `origin/main`; do not pull or restart production for this handoff until the implementation commit has been pushed and reviewed.

The expected `1.2.0` contract is:

- one shared WhatsApp destination for scheduled and patrol delivery;
- one shared minimum-message interval, defaulting to **No wait**;
- separate patrol and scheduled message content/flows;
- removal of the old 75-minute patrol restriction;
- backward-compatible normalization of existing `1.1.0` configuration.

After the implementation commit is pushed:

1. Review the diff and verify the config migration against a copy of production `config.json`.
2. Run `npm ci`, `npm run check`, schedule-generation tests, and isolated patrol/scheduled-send guard tests.
3. Commit/push any required review fixes before production deployment.
4. Stop `whatsapp-scheduler.service`, back up the complete `DATA_DIR`, pull the reviewed commit, and run `npm ci`.
5. Start `whatsapp-scheduler.service` and `tailscale-admin-funnel.service`.
6. Confirm external `/api/health` returns `200` with `"engineVersion":"1.2.0"` and confirm authenticated config round-tripping preserves both message flows.
7. Log into the iOS account again if the API restart invalidates its token, then use **Activity → Retry Queue** for failed patrol entries.

## iOS Shared-Device Safeguards

WatchPoint's shared-device, multi-guard model (see Architecture) includes two device-side safeguards:

- **App lock.** A default-on Face ID/device-passcode gate protects Keychain-backed guard access at launch and whenever WatchPoint returns from the background. It can be disabled in Preferences when a deployment does not require it.
- **Shift-change reconfirmation.** WatchPoint tracks a device-local, per-account confirmation timestamp. After four hours, Patrol shows "Still {guard} on {account}?" with actions to confirm or switch guard, reducing the risk of recording a shift under the previous account.

Implemented on 2026-08-20 in `AppState.swift`, `ContentView.swift`, `PreferencesView.swift`, and `PatrolTab.swift`. The app uses `LocalAuthentication` with device-passcode fallback, locks its content before backgrounded data can be shown again, and keeps confirmation timestamps separate for every Scheduler account. A generic iOS Simulator build completed successfully with Xcode after implementation.

Also recommended as later backend work:

- **Persist session tokens server-side** (not just in memory) so guards aren't logged out mid-shift by an unrelated engine restart or deploy — this already caused one dead-end-UI bug (see git history).
- **WhatsApp pairing-code login** (`client.requestPairingCode`) as the real fix for "can't scan a QR on the same phone you're reading it on," instead of the current QR-only flow.
- **Invite-link account creation**: a single-use, time-limited token generated server-side that, opened in WatchPoint via a deep link, creates a new guard's account automatically instead of typing a name/password into "Add Guard" — best paired with pairing-code login above so the whole onboarding flow works from one device.
