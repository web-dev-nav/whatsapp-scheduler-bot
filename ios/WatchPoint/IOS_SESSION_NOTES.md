# WatchPoint iOS — Session Notes

Scope for the session working in `ios/WatchPoint/`. For the full
cross-repo picture (backend/n8n/Tailscale side, owned by a different
session) see `../../WATCHPOINT_PLAN.md` at the repo root — read that first
for the architecture and API contracts this app depends on.

Do not touch `server.js`, `scheduler.js`, n8n, or Tailscale/Docker config
from this session. If iOS work seems to need a backend change, add it to
"Needs from the backend session" below instead of making it yourself.

## Navigation redesign #2 (latest): 3 tabs -> 5, real UX fixes

After the 3-tab consolidation below shipped, the user tried it and reported
concrete bugs, not just a preference: the keyboard never dismissed after
editing a field, login/message-sending/patrol being crammed into one
"Scheduler" form felt worse than separate screens, there was no
confirmation after saving, Activity needed its own page, the schedule
setup needed the browser's step-by-step wizard feel (not one long form),
and there was no way to add/remove WhatsApp sessions from the app at all
(session management existed nowhere in the UI). This was a correction, not
a reversal of the mirroring goal — the earlier 3-tab merge over-corrected
by cramming too much into single forms. `ContentView.swift` was rebuilt
again, this time as five separate top-level view structs (`ConnectTab`,
`SetupTab`, `PatrolTab`, `ActivityTab`, `SettingsTab`) instead of computed
properties on one `ContentView` — needed anyway because the old
single-struct approach hit a real compiler error (`the compiler is unable
to type-check this expression in reasonable time`) once `ConnectTab`'s
body got big; splitting into separate structs with extracted computed
properties both fixes that and keeps each screen's code independently
readable.

- **Connect tab** — now genuinely does WhatsApp session management, which
  didn't exist before at all: a list of all accounts from `GET
  /api/accounts`, tap any row to switch (`AppState.selectAccount`, which
  clears and reloads `whatsAppState`/`patrolConfig`/`logs` for the newly
  selected account so stale data from the previous account never lingers),
  "Add Session" opens a sheet (`AddAccountSheet`) that calls the new `POST
  /api/accounts` via `SchedulerAdminAPI.createAccount(name:password:)`,
  and "Remove This Account" calls the new `DELETE /api/accounts` via
  `SchedulerAdminAPI.deleteAccount()` behind a `confirmationDialog` (can't
  remove `main`, matching the server's own rule in `server.js`). Login/QR
  for the selected session live in the same tab underneath, since that's
  one continuous session-management flow, not a separate concern.
- **Setup tab** — replaced the single scrolling form with an actual 5-step
  wizard (`SetupStep` enum: chat, days, shift, message, review), a
  `ProgressView` + "Step N of 5" header, Back/Next navigation, and the
  config is only PUT to the server on the final "Save & Done" step (same
  as the browser's wizard — edits are local until you finish). On a
  confirmed successful save, an explicit `.alert("Saved", ...)` fires —
  `AppState.saveConfig()` now returns `Bool` (`@discardableResult`) instead
  of silently updating `patrolConfig`, so the view only shows the
  confirmation when the PUT actually succeeded, not optimistically.
- **Activity tab** — split out on its own, showing the scheduler log
  (`GET /api/logs`) and full patrol event history with retry, instead of
  being squeezed into the bottom of another screen.
- **Patrol tab** — trimmed back to just its own job: status/start-stop,
  map, checkpoint list. Restored the "Send Test Arrival" button per
  checkpoint (`AppState.manualTrigger`), which had become dead code after
  an earlier pass dropped its only caller — this is the native equivalent
  of the browser's "Test connection (dry run)" button and is worth having
  for verifying the pipeline without physically driving to a checkpoint.
- **Keyboard dismissal fix** — every screen with text input now has
  `.scrollDismissesKeyboard(.interactively)` (drag-to-dismiss, standard
  since iOS 16) plus a shared `View.keyboardDoneButton()` extension that
  adds an explicit "Done" button in a `.keyboard`-placed toolbar. This is
  the actual fix for "the keypad opened but never closed by itself" — plain
  `Form`/`List` don't dismiss the keyboard on their own in SwiftUI, you
  have to opt in.
- **Settings tab** — unchanged in scope.

Rebuilt after each fix with `xcodebuild ... build`. Hit and fixed two real
compiler errors along the way (both from a fresh build, not assumed):
`ConnectTab`'s original monolithic `body` timed out the type-checker
(fixed by extracting `accountsSection`/`selectedSessionSection`/etc. into
separate computed properties — same fix pattern Swift always needs for
"reasonable time" errors), and `.foregroundStyle(.accentColor)` failed
because bare `.accentColor` doesn't resolve against the `ShapeStyle`
protocol the way it does against `Color` (fixed by writing
`Color.accentColor` explicitly). Final build: `BUILD SUCCEEDED`, zero
warnings in changed files.

## Navigation redesign #1 (superseded): 6 tabs -> 3, mirroring the browser

The user flagged that the app's original 6-tab layout (Patrol,
Checkpoints, History, Connect, Schedule, Settings) didn't match their
mental model of the browser at all, and asked for something simpler that
mirrors the two flows the browser actually has: (1) connect WhatsApp, pick
a chat, write the message, set the schedule, and (2) mark GPS checkpoints
and run a live patrol that auto-sends on arrival. Rebuilt `ContentView.swift`
around that:

- **Scheduler tab** (was: Connect + Schedule, merged into one flow) —
  account picker + QR login/logout at the top (`connectionSection`), then
  once WhatsApp is `ready`: chat picker, message editor, schedule fields
  (weekly days, day/night shift, `DisclosureGroup("Fine-Tune Timing")` for
  the less-common numeric knobs), a Save button, and an Activity section
  fed by the new `GET /api/logs` (`SchedulerLogEntry`/`LogsResponse` in
  `WatchPointModels.swift`, `logs()` in `SchedulerAdminAPI.swift`,
  `fetchLogs()` in `AppState.swift`). This is a single scrollable `Form`,
  not the browser's multi-step wizard — a wizard is a mobile-web pattern
  for a *website*; a native settings-style form is the simpler
  equivalent, not a lesser one.
- **Patrol tab** (was: Patrol + Checkpoints + History, merged into one
  flow) — status card with Start/Stop, the MapKit checkpoint editor
  (tap-to-add, name + radius per row, delete), and a "Recent Arrivals"
  panel showing the last 5 events with a retry button. Full history was
  dropped as a separate tab; only the last 5 events show now (there's no
  separate History screen anymore).
- **Settings tab** — unchanged in purpose, but now the *only* place
  holding things the browser has no equivalent for at all: guard name,
  admin base URL, n8n webhook URL, geofence cooldown/accuracy. Moved the
  admin base URL field here from the old Connect tab since account
  switching itself now lives in the Scheduler tab's connection section.
- **Removed entirely: `PatrolAppointment` / "Appointments."** This was
  dead UI — grepped the whole app and confirmed nothing ever read
  `appointments` to gate `shiftIsActive`, checkpoint evaluation, or
  anything else. It duplicated the real schedule (now editable in the
  Scheduler tab) without being wired to any actual behavior, and the
  browser has no equivalent concept at all. Removed the model, the
  `AppState` CRUD methods, and the Settings section. This directly served
  the "make it simpler" ask by cutting a feature that only added
  confusion.
- **Simplified `Checkpoint` model**: dropped `notes` and `isActive`
  fields. The browser's checkpoint shape (`public/patrol.js`) is just
  name/lat/lng/radiusMeters — nothing else — and the new checkpoint list
  UI only exposes name + radius (matching `patrol.html`'s `cp-item`
  layout exactly: name, radius, delete). A checkpoint being in the list is
  what makes it active now, same as the browser; there's no more
  independent active/inactive toggle a guard could forget to flip back on.

Rebuilt after each change with `xcodebuild -project WatchPoint.xcodeproj
-scheme WatchPoint -destination 'generic/platform=iOS Simulator' build` →
`BUILD SUCCEEDED` every time, zero warnings in the changed files.

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

## Resolved: public admin URL now live

The backend session confirmed the engine's admin API is exposed via
Tailscale Funnel at `https://hp-server.tailed5092.ts.net:10000` (→
`127.0.0.1:3000`, returning 200), with 24h session token expiry and login
rate-limiting already in place before it went public. `WatchPointModels.swift`'s
`developmentSchedulerAdminURL` was renamed to `productionSchedulerAdminURL`
and updated to that value; `AppState.swift`'s default `schedulerAdminBaseURL`
now points at it. Rebuilt with `xcodebuild` — `BUILD SUCCEEDED`.

Note: `@AppStorage` only applies its default on first read for a fresh key.
Anyone who already ran a build with the old LAN IP saved will keep using
that IP until they change it in Settings → Scheduler Admin → Admin base
URL, or reinstall — this isn't a bug, just how `@AppStorage` defaults work.

Still open: on-device end-to-end verification (login → QR → load
`/api/config` → edit → save → confirm it shows in the browser UI) hasn't
been run yet, since that needs a physical device/simulator session against
the live URL, not just a build check.

## Needs from the backend session

- None outstanding. If `server.js`'s `/api/config` semantics change later
  (full-object PUT, `groupName` matched by chat name), check this file's
  assumptions still hold before shipping.

## Suggested next iOS work

- Wire the Setup wizard's chat `Picker` (step 1) more defensively: if the
  account's current `groupName` isn't present in the freshly-loaded
  `chats` list (chat renamed/left), the `.wheel` picker currently shows
  whatever the raw string value is with no matching row highlighted —
  consider surfacing that as a visible warning rather than letting it look
  like a normal selection.
- Manual on-device verification, covering the current 5-tab nav: Connect
  tab → add a second test session, switch between sessions, confirm
  `whatsAppState`/`patrolConfig`/`logs` actually reload per-account and
  don't leak between accounts → remove the test session → back on the
  original account, run the Setup wizard end to end (all 5 steps, confirm
  the "Saved" alert only appears on real success) → confirm it shows in
  the browser UI's schedule preview → Patrol tab → drop a checkpoint →
  "Send Test Arrival" to confirm the pipeline → Start Live Patrol → walk
  into the radius → confirm a real WhatsApp message sends (exercises the
  n8n bridge the backend session built) → Activity tab → confirm both the
  scheduler log and the patrol event just fired show up.
- Activity tab shows full, unbounded history now (no 5-item cap) — worth
  keeping an eye on performance/scroll if `history` or `logs` grow very
  large over weeks of use; consider pagination or a cap if that becomes a
  real problem, not preemptively.
