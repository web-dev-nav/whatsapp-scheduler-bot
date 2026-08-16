# WatchPoint / Scheduler Integration Plan

Shared plan for two Claude Code sessions working in parallel on this repo:

- **Session A — Backend + Infra + n8n** (works in this repo root, plus the home
  server's Docker/Tailscale config)
- **Session B — iOS** (works in `ios/WatchPoint`)

Read this whole file before starting. Do not duplicate the other session's
work. If you need something the other session owns, add it to "Open
questions" at the bottom instead of guessing.

## Goal

Replace the browser UI (`public/`) with the WatchPoint iOS app for day-to-day
use: QR login, account switching, WhatsApp group selection, message/schedule
editing, and checkpoint/radius definition all happen from the phone. The
Node engine (`server.js`) stays the *only* thing that holds the WhatsApp Web
session and the *only* thing that ever calls `sendPatrolMessageNow`. The iOS
app never sends a WhatsApp message itself — it only edits config or asks the
engine to check in.

## Current state (verified in code, 2026-08-12)

- Engine (`server.js`) already exposes a full JSON API used today by the
  browser UI:
  - `GET/POST /api/accounts`, `POST /api/accounts/auth`, `POST
    /api/accounts/password`, `DELETE /api/accounts`
  - `GET /api/whatsapp` (status + `qrDataUrl` + chat list), `POST
    /api/whatsapp/logout`
  - `GET /api/config`, `PUT /api/config` (message text, shift days/times,
    schedule), `POST /api/config/preview`
  - `GET /api/logs`
  - `POST /api/patrol/trigger` (guarded by `PATROL_TOKEN` or account auth;
    also a second, token-only variant near line 1236 guarded by
    `PATROL_TRIGGER_TOKEN` — **these two `/api/patrol/trigger` handlers
    look like duplicate/overlapping routes, first one wins since it's
    checked first. Session A should confirm which is intended and remove
    the dead one.**
  - Account auth: per-account password (pbkdf2, salted, timing-safe
    compare), session token returned on login, checked via
    `X-Account-Auth` header (`server.js:111-144`). **Tokens never expire**
    and there is **no rate limiting** on `/api/accounts/auth` — acceptable
    on a LAN-only, unexposed engine; not acceptable once this port is
    reachable from the public internet.
  - Checkpoints (lat/lng/radius) are **not** stored server-side anywhere.
    The engine only ever receives a free-text `checkpointName` at trigger
    time. This is intentional/consistent — checkpoint storage is a
    client-side (UI-layer) concern in both the browser (`patrol.html`) and
    WatchPoint (`LocalJSONStore`). Do not add server-side checkpoint
    storage as part of this plan.
  - **Multi-guard model, as of 2026-08-16**: each `SchedulerAccount` *is* a
    guard — its own WhatsApp login, `/api/config` (message/schedule), and
    (as of the iOS-side change below) its own device-local checkpoints,
    patrol history, and guard name. WatchPoint is designed for a **shared
    device** (e.g. a guard-shack tablet) where multiple guards log into
    their own account and switch between them; switching accounts swaps
    every guard-specific thing at once and force-stops any active patrol.
    Device-level settings (admin base URL, webhook URL, GPS accuracy/
    cooldown thresholds) intentionally stay global/shared across accounts,
    since they describe the device and network, not a guard's identity.
- WatchPoint iOS app (`ios/WatchPoint/WatchPoint/`) already implements:
  - `SchedulerAdminAPI.swift` — matches the engine's account/whatsapp API
    contract exactly (login, poll `/api/whatsapp` every 4s in
    `ContentView.swift`, render `qrDataUrl`, logout). **No changes needed
    here for QR login to work** — the only blocker is reachability (see
    below).
  - `AppState.swift` — GPS geofencing, checkpoint CRUD, event history with
    retry, all POSTing arrival events to `webhookURL`
    (`WatchPointModels.swift:10`, currently
    `https://hp-server.tailed5092.ts.net/webhook/patrol-test`, i.e. n8n —
    **not** the engine directly).
  - `schedulerAdminBaseURL` (`AppState.swift:16`) defaults to
    `developmentSchedulerAdminURL = "http://172.20.10.3:3000"`
    (`WatchPointModels.swift:11`) — a LAN-only IP. This is why QR login
    "doesn't work" off the home Wi-Fi: the request can't reach the
    container at all, not an auth or code problem.
  - **Missing in iOS**: no screens/API calls yet for `/api/config` (message
    text, shift days, shift times) or chat/group selection from
    `whatsAppState.chats`. Today WatchPoint only does account
    login/QR/logout + checkpoints/geofencing — it does not yet let you
    edit the message or schedule from the phone.
- n8n (Docker container, exposed via Tailscale Funnel at
  `https://hp-server.tailed5092.ts.net/`) currently only runs the stub
  workflow in `patrol-test-workflow.json`: `Webhook → Respond OK`. It does
  **not** forward to the engine yet.
- Engine is on Docker but is **not** exposed publicly — only reachable on
  the home LAN today.

## Target architecture

Two separate paths, deliberately kept apart:

```
Admin/config path (QR login, account switch, message/schedule editing,
chat selection):
   WatchPoint (iOS) --HTTPS, direct--> Engine admin API (own Tailscale
   Funnel port)

Patrol arrival path (geofence -> WhatsApp send):
   WatchPoint (iOS) --HTTPS--> n8n webhook (existing Funnel URL)
   --HTTP Request node--> Engine /api/patrol/trigger --whatsapp-web.js-->
   WhatsApp group
```

Rationale: the admin path needs low-latency 4-second polling for QR status,
which the engine's existing Swift client already does — proxying that
through n8n workflows would be slow to build and slower to keep in sync
every time the engine API changes. The patrol path stays on n8n because
that's genuinely n8n's job (logging, future dedupe) and it keeps the
public attack surface for "can this cause a WhatsApp send" narrow (just
`/api/patrol/trigger`, token-gated), separate from the full admin API.

## Session A — Backend + Infra + n8n

Work in this repo (`server.js`, `.env`) and on the home server's Docker /
Tailscale config. Do not touch `ios/`.

1. **Resolve the duplicate `/api/patrol/trigger` handlers** (`server.js`
   around lines 1199 and 1236). Read both fully, figure out which one is
   dead code (the second is unreachable since the first `pathname ===
   '/api/patrol/trigger'` check always fires first), decide which guard
   logic (`PATROL_TOKEN` vs `PATROL_TRIGGER_TOKEN`) is the one actually
   documented in `README.md`, and remove the other. Flag this to the user
   before deleting if it's unclear which is intentional — don't guess.
2. **Harden account auth before exposing it publicly:**
   - Add expiry to session tokens in `accountSessions` (`server.js:111`) —
     e.g. reject tokens older than N hours in `requireAccountAuth`.
   - Add basic rate limiting / backoff on `POST /api/accounts/auth` (e.g.
     a simple in-memory attempt counter per account/IP) since this becomes
     a password-guessing target once public.
   - Do not change the account password hashing scheme — pbkdf2 + salt +
     timing-safe compare is fine.
3. **Expose the engine on a second Tailscale Funnel port**, separate from
   n8n's existing one. Tailscale Funnel supports multiple concurrent
   ports on one node. Example:
   ```bash
   tailscale funnel --bg 3000
   ```
   Confirm with the user which port to standardize on before running
   this — it's a change to the public attack surface of their home
   server, treat it as a confirm-first infra action, not something to run
   silently.
4. **Build the n8n bridge**: edit `patrol-test-workflow.json` (or edit
   live in the n8n UI, then re-export it into this repo for the record) to
   add an HTTP Request node between `Patrol Test Webhook` and `Respond OK`:
   - Method: POST
   - URL: `http://<engine-container-name-or-127.0.0.1>:3000/api/patrol/trigger?account=main` (use the Docker network container name if n8n and the engine share a Docker network — confirm the actual container/network name from the user's `docker-compose.yml`, which is not in this repo)
   - Body: `{"source": "n8n-iphone-shortcuts", "checkpointName": "{{ $json.body.checkpointName }}"}`
   - Pass through `guardName` from the request body too if present, since
     `PatrolWebhookRequest` on the iOS side already sends it.
5. Update `README.md`/`DEPLOY.md` once the above is live so they reflect
   reality (funnel port, hardened auth) instead of the LAN-only setup they
   currently describe.

## Session B — iOS (`ios/WatchPoint`)

Work only in `ios/WatchPoint/`. Do not touch `server.js` or n8n. Wait for
Session A to confirm the funnel port before wiring the base URL — ask the
user if Session A hasn't reported it yet, don't guess a port number.

1. Update `developmentSchedulerAdminURL` (`WatchPointModels.swift:11`) to
   the public funnel URL Session A sets up (e.g.
   `https://hp-server.tailed5092.ts.net:<port>`), or better, make it
   user-editable in Settings only (the "Connect" tab already has a
   `TextField("Admin base URL", ...)` bound to
   `$appState.schedulerAdminBaseURL` — just fix the default constant so a
   fresh install works over the internet, not just on the home LAN).
2. Verify the existing QR login flow end-to-end once Session A's funnel is
   live: Connect tab → enter account password → QR renders → scan → status
   flips to `ready`. No code changes should be needed here per the
   existing `SchedulerAdminAPI.swift`/`ContentView.swift` — this step is
   verification, not new development.
3. **New work**: add a screen (new tab or a section under Settings) for
   editing `/api/config` — message text, shift type/days, shift start/end
   times — matching what `README.md`'s "Main UI Controls" section
   describes for the browser UI. Add the corresponding methods to
   `SchedulerAdminAPI.swift` (`GET/PUT /api/config`, both already exist
   server-side, need Swift request/response types and calls).
4. **New work**: add WhatsApp group/chat selection to the config screen,
   using `whatsAppState.chats` (`WhatsAppAdminChat` — already decoded from
   `/api/whatsapp`) as the picker source, saved into the config payload's
   target-chat field (check the exact field name in the config JSON
   returned by `GET /api/config` before assuming — read
   `loadConfigFromPath`/`normalizeConfig` in `scheduler.js` first).
5. Keep `webhookURL` (the n8n patrol URL) untouched — that path is already
   correct and is Session A's territory if it needs to change.

## Definition of done

- [ ] iOS Connect tab can log in and show a live QR code from outside the
      home LAN (e.g. over cellular).
- [ ] Scanning the QR flips WhatsApp status to `ready` in the app.
- [ ] iOS can view and save message text + schedule via the new config
      screen, and it's reflected in the engine's `config.json` / browser UI.
- [ ] A real checkpoint arrival in WatchPoint results in a WhatsApp message
      being sent, visible in both n8n's execution log and the engine's
      Scheduler Log.
- [ ] `/api/patrol/trigger` duplicate route resolved, one clear guard
      mechanism documented in `README.md`.
- [ ] Account session tokens expire; `/api/accounts/auth` is rate-limited.

## Open questions (do not guess — ask the user)

- Which Docker network/container name does n8n use to reach the engine
  internally? (needed for the n8n HTTP Request node URL)
- Which port should the engine's admin Funnel listener use?
- Is `PATROL_TOKEN` or `PATROL_TRIGGER_TOKEN` the one actually meant to
  guard `/api/patrol/trigger`, given the two overlapping route handlers in
  `server.js`?
- Session token expiry window (e.g. 24h? 7d?) — user preference.

## Backend asks from the iOS session (2026-08-16)

Not implemented here — the iOS session doesn't touch `server.js`. Both are
additive/low-risk. Full copy-pasteable prompt for these lives in
`ios/WatchPoint/IOS_SESSION_NOTES.md` under "Needs from the backend session."

- **`GET /api/health`** — engine version, Node version, uptime, server time,
  and active-account/connected-session counts. Powers the iOS Host &
  Connection page's "Engine Diagnostics" section, which today just says
  this isn't available.
- **Structured `/api/logs` fields** — `accountId`/`accountName`, a `level`
  (info/warn/error), and where applicable a WhatsApp `messageId` or sent
  message preview, alongside the existing flattened `message`/`label`
  strings. Powers a more detailed duty log (who/what/how) than the current
  message string allows.
