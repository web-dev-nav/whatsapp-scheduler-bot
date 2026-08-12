# WatchPoint iOS — Session Notes

Scope for the session working in `ios/WatchPoint/`. For the full
cross-repo picture (backend/n8n/Tailscale side, owned by a different
session) see `../../WATCHPOINT_PLAN.md` at the repo root — read that first
for the architecture and API contracts this app depends on.

Do not touch `server.js`, `scheduler.js`, n8n, or Tailscale/Docker config
from this session. If iOS work seems to need a backend change, add it to
"Needs from the backend session" below instead of making it yourself.

## What changed already (this session, verified building)

Confirmed with a real build: `xcodebuild -project WatchPoint.xcodeproj
-scheme WatchPoint -destination 'generic/platform=iOS Simulator' build` →
`BUILD SUCCEEDED`. (Command Line Tools alone can't run `xcodebuild`; use
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select`
points at Command Line Tools instead of Xcode.app.)

Added a **Schedule** tab so message text and shift timing can be edited
from the phone instead of only from the browser, using the engine's
existing `/api/config` GET/PUT (no backend changes were needed for this):

- `WatchPointModels.swift` — added `PatrolConfig`, `ScheduleConfig`,
  `PatrolSection`, `ServerCheckpoint`, `ConfigResponse`,
  `ConfigUpdateRequest`. These mirror `scheduler.js`'s `DEFAULT_CONFIG`
  shape field-for-field. `PatrolSection.checkpoints` is decoded/encoded but
  never shown in the UI — it belongs to the browser's `patrol.html`
  checkpoint editor. **Important**: config is always round-tripped whole
  (GET the full object, mutate only the edited fields, PUT the full object
  back), matching how `public/patrol.js` already does it. Never construct
  a partial config to PUT — `server.js`'s `normalizeConfig` defaults any
  missing top-level key (e.g. `patrol`) back to empty, which would silently
  delete checkpoints saved from the browser.
- `SchedulerAdminAPI.swift` — added `config()` and `updateConfig(_:)`.
- `AppState.swift` — added `patrolConfig`, `isConfigLoading`,
  `fetchConfig()`, `saveConfig()`.
- `ContentView.swift` — new `scheduleView`: WhatsApp group/chat picker
  (from `whatsAppState.chats`, matched to the engine's `groupName` field by
  **chat name**, not chat ID — that's how `findTargetChat` in `server.js`
  resolves it), message text editor, automatic-sending toggle, weekly
  shift-day picker (`activeShiftDays`, `0` = Sunday per JS `Date.getDay()`
  convention, matches `public/app.js`), day/night shift presets plus custom
  start/end hour steppers, first-message-window steppers, min/max gap
  steppers, and a one-time shift dates list (`extraShiftDates`,
  `yyyy-MM-dd`). Deliberately left out the advanced anti-spam knobs
  (`minMinutesBetweenSends`, `maxSendsPerDay`, `reconnectCooldownMinutes`,
  `staleSendGraceMinutes`) — README doesn't list them as main UI controls,
  and they still round-trip correctly since the whole config is decoded.

No changes were made to checkpoint/geofencing logic, the n8n webhook path,
or `SchedulerAdminAPI`'s existing account/QR/logout methods — those were
already correct.

## Known limitation, not yet fixed

`developmentSchedulerAdminURL` in `WatchPointModels.swift` is still a
LAN-only IP (`http://172.20.10.3:3000`). QR login, the new Schedule tab,
and chat loading all depend on `schedulerAdminBaseURL` being reachable —
today that only works on the home Wi-Fi. This is blocked on the backend
session exposing the engine's admin API on a public Tailscale Funnel port
(see `WATCHPOINT_PLAN.md`, Session A step 3). Don't hardcode a funnel URL
here until that port is confirmed — ask the user if it's not been reported
yet. In the meantime the field is user-editable in Settings, so this can
be tested manually by typing the funnel URL in on-device once it exists.

## Needs from the backend session

- The public URL/port the engine's admin API ends up on, once exposed via
  Tailscale Funnel, so `developmentSchedulerAdminURL` can be updated.
- Confirmation that `/api/config` semantics haven't changed (full-object
  PUT, `groupName` matched by chat name) — if the backend session refactors
  `server.js`, check this file's assumptions still hold.

## Suggested next iOS work

- Wire the Schedule tab's `Picker` selection more defensively: if the
  account's current `groupName` isn't present in the freshly-loaded
  `chats` list (chat renamed/left), the Picker currently shows nothing
  selected — consider surfacing that as a visible warning rather than
  silently leaving `groupName` unchanged until the user picks something.
- Manual on-device verification once a real admin URL is reachable: log in
  → confirm `/api/config` loads → edit message/days/times → save → confirm
  the change shows up in the browser UI's schedule preview.
