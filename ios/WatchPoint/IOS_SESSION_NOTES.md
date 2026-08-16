# WatchPoint iOS — Session Notes

Scope for the session working in `ios/WatchPoint/`. For the full
cross-repo picture (backend/n8n/Tailscale side, owned by a different
session) see `../../WATCHPOINT_PLAN.md` at the repo root — read that first
for the architecture and API contracts this app depends on.

Do not touch `server.js`, `scheduler.js`, n8n, or Tailscale/Docker config
from this session. If iOS work seems to need a backend change, add it to
"Needs from the backend session" below instead of making it yourself.

## Multi-guard support, detailed duty log, Host & Connection page (latest)

User confirmed the real deployment model: a **shared device** (e.g. a
guard-shack tablet), where different guards log into their own WhatsApp
account and switch between them during a shift -- not one phone per guard.
The server already had the right primitive for this (each `SchedulerAccount`
is a fully independent WhatsApp session + `/api/config`), but the app's
*local* data wasn't scoped per account at all: checkpoints, patrol history,
dedupe state, and guard name all lived under fixed global keys. Guard B
switching to their account would have seen Guard A's checkpoints and
history -- confirmed as the actual bug behind "how would this work between
multiple guards."

- **Per-account local data (`AppState.swift`)**: checkpoints/history/dedupe
  state now save/load under `"<key>.<accountId>"` instead of a fixed key
  (`accountKey(_:)` helper). `guardName` moved off `@AppStorage` (can't be
  keyed dynamically) to a plain `@Published` property persisted the same
  way, with a `didSet` that saves under the *current* account's key.
  `selectAccount(_:)` now calls `loadLocalData(for:)` alongside its existing
  whatsAppState/patrolConfig/logs reload, and force-stops any active patrol
  first (`stopPatrol()`) -- both because continuing a live patrol under a
  different guard's identity mid-shift is unsafe/confusing, and because
  `stopPatrol()`'s dedupe-state save must happen under the *old* account's
  key before switching.
- **One-time migration**: `migrateGlobalLocalDataToAccountIfNeeded()` copies
  the old global-keyed data into whichever account is selected the first
  time it runs (guarded by a `UserDefaults` flag), so existing users don't
  lose their current checkpoints/history. Every other account starts empty,
  correctly, since they're new guards. Old `@AppStorage("guardName")` was a
  raw UserDefaults string (not `LocalJSONStore` JSON `Data` like the other
  three keys) so it's migrated separately.
- **Stayed global on purpose**: admin base URL, webhook URL, GPS accuracy/
  cooldown thresholds -- these describe the device/network, not a guard's
  identity, so one admin can tune them once for the shared device.
- **Guard name field moved** from Preferences (now purely device-level) to
  a new "This Guard" section in `WhatsAppSessionView` (`AccountTab.swift`),
  since it's per-account now. Account hub copy updated throughout to make
  "each account = a separate guard, with everything that implies" explicit
  rather than implied ("Add Session" -> "Add Guard", footer text spelled
  out exactly what switching swaps).
- **Duty log detail (`ActivityTab.swift`)**: patrol events now group by day
  (Today/Yesterday/date headers) and show the sending guard's name on every
  row (`PatrolEvent.guardName`, already captured at send time -- just not
  displayed before). Each event is now a `DisclosureGroup` exposing detail
  that was already being stored but not surfaced: GPS coordinates, accuracy,
  attempt count, last-attempt time, and the raw webhook/scheduler response.
  The scheduler log section is honest about its limit: the server doesn't
  return which account produced a line, so it's labeled with whichever
  account is currently selected rather than pretending to know more.
- **New Host & Connection page** (`HostStatusView.swift`, third row in the
  Account hub): shows the configured admin/webhook URLs plus a live
  reachability check (times a real request, reports HTTP status or the
  specific failure) for each -- this is the in-app version of the `curl`
  diagnosis used earlier this session to find the admin-Funnel TLS outage,
  so a guard doesn't have to see a cryptic system alert with no actionable
  detail. Also shows current account/guard/WhatsApp-status/chat-count in one
  place. Has an honest "not available yet" section for engine version/
  uptime/session count, which needs a backend endpoint (below) -- doesn't
  fake data it doesn't have.

Verified: `xcodebuild ... build` -> `BUILD SUCCEEDED`. Installed on the
booted simulator and confirmed via screenshot: migration correctly carried
the existing guard name into "Main"'s per-account namespace, Host &
Connection row renders in the Account hub, and the updated footer copy
shows. Could not tap through account-switching/duty-log grouping in the
simulator (no Accessibility permission for `osascript`, no `idb`) -- worth a
manual pass with two real test accounts to fully confirm isolation.

## Bug fix: stale session token stuck the WhatsApp Session screen

User reported Delete/Logout/Refresh all popping up "Enter a password" with no
actual password field to enter it in. Root cause, confirmed by reading
`server.js:119-155`: session tokens live in memory only and are wiped by any
engine restart (which is exactly what happened during the admin-Funnel outage
above) or expire after `SESSION_TOKEN_TTL_HOURS`; the server correctly
replies `401 "Enter the password for ..."`, but `AppState` only checked
whether a token was *present* in Keychain, never whether the server still
accepted it. A stale-but-present token left the UI permanently showing the
"connected" controls (Refresh/Logout/Remove) with no path back to the
password field -- every tap just re-surfaced the same dead-end error.

Fixed in `AppState.swift`'s `presentError(_:)` (used by every authorized
call) and `fetchLogs()` (which swallows errors without alerting): on a 401,
clear the Keychain token for the current account before showing the alert,
so the next render's `adminToken.isEmpty` check is true again and the view
falls back to the login field on its own -- no new UI/state needed, just
correcting what "connected" means to check server-side validity, not just
local presence.

Verified: `xcodebuild ... build` -> `BUILD SUCCEEDED`. Confirmed via a live
`curl` against `hp-server:10000` that the account-list fetch now succeeds
end-to-end once the backend session's Funnel-persistence fix
(`tailscale-admin-funnel.service`) landed. Could not tap through the actual
login/refresh/remove flow in this session (no Accessibility permission for
`osascript`, no `idb` installed) -- worth a manual pass to fully confirm.

## Navigation redesign #3: 5 tabs -> 3, proper information architecture

The 5-tab layout (Connect, Setup, Patrol, Activity, Settings) from redesign #2
mirrored how the *code*/API is organized (one screen per admin endpoint)
rather than how a guard actually uses the app in the field: patrol execution
is the everyday, primary flow; WhatsApp session, schedule, and device
preferences are rare, config-time flows that don't deserve permanent
bottom-bar real estate. Confirmed against Apple's own tab-bar guidance and
how real guard-tour apps (Guard1/TrackTik-style) are structured before
changing anything, rather than restructuring on a hunch.

Restructured to 3 top-level tabs via a new `AppTab` enum:

- **Patrol** (home, default tab) — status hero (Start/Stop, live state, now
  also "Sending as {account}" and a WhatsApp-not-ready banner with a "Fix"
  button that jumps to Account), map, checkpoint list. Same underlying logic
  as before (radius drag, tap-to-add, etc. all untouched) — only the shell
  and status panel changed.
- **Activity** — unchanged, moved as-is.
- **Account** — new hub tab: a `List` whose rows push full-screen
  destinations instead of being separate tabs — WhatsApp Session (old
  Connect tab body, `NavigationStack` removed since it's now pushed),
  Message & Schedule (old Setup tab body, same treatment), and Preferences
  (old Settings tab, trimmed down to device-only knobs now that account
  switching lives under WhatsApp Session instead).

App now lands on Account when logged out (`appState.adminToken.isEmpty`,
checked once in `.onAppear`) instead of dropping a first-time user on an
empty map, and switches to Patrol as the default once a session exists.

Split the monolithic `ContentView.swift` (~1250 lines, had already hit a
real "compiler unable to type-check in reasonable time" error once from
being too big) into one file per screen: `PatrolTab.swift`,
`AccountTab.swift`, `SetupView.swift`, `PreferencesView.swift`,
`ActivityTab.swift`, `SharedViews.swift` (EventRow, WhatsAppConnectionRow,
`UIImage(dataURL:)`, `panel()`/`keyboardDoneButton()` helpers).
`ContentView.swift` is now just the `TabView` shell + `AppTab` enum + default
tab logic. The project uses Xcode's file-system-synchronized groups, so new
files needed no `project.pbxproj` changes.

Pure view-layer restructuring — no changes to `AppState.swift` or
`SchedulerAdminAPI.swift`, all existing state/API calls reused as-is.

Verified with `xcodebuild ... build` → `BUILD SUCCEEDED`. Installed and
launched on a booted iPhone 17 Simulator; screenshot confirmed 3 tabs, the
logged-out-lands-on-Account behavior, and the Account hub rendering
correctly. Could not verify with automated taps (`osascript` lacks
Accessibility permission in this environment) -- pushed-screen navigation
(no double nav bars), the not-ready banner, and Patrol-becomes-default once
connected still need a manual on-device/simulator pass.

While testing, hit an unrelated infra issue: the production admin URL
(`https://hp-server.tailed5092.ts.net:10000`) fails its TLS handshake
(`SSL_ERROR_SYSCALL` — TCP connects, TLS reset) while the host's other
Funnel port (443, n8n) responds fine. This is a backend/Tailscale Funnel
problem on `hp-server`, not an iOS bug -- flagged below, not fixed here per
the "don't touch Tailscale/Docker config" boundary.

## Draggable radius handle on the map

User asked for a way to freely adjust a checkpoint's radius directly on
the map, rather than only via the `Stepper` in the list or the `Slider`
under the map (both still present -- this is additive, for coarse/visual
adjustment, not a replacement for precise numeric entry).

Implementation, since the declarative SwiftUI `Map` API has no built-in
draggable-overlay support: each checkpoint gets an extra `Annotation`
placed at a point due east of its center at distance `radiusMeters`
(`radiusHandleCoordinate(for:)`, flat-earth approximation -- accurate
enough up to the app's 1000m radius cap) rendered as a small white circle
handle. A `DragGesture` on that handle:
1. On the first `.onChanged` of a given drag, captures the handle's
   current on-screen point via `MapProxy.convert(_:to:)` and stores it in
   `RadiusDragState` (keyed by checkpoint id, so a second finger/checkpoint
   doesn't confuse state).
2. Each subsequent `.onChanged` computes `handleStartScreenPoint +
   value.translation` (translation is cumulative from gesture start, not
   per-frame, so this doesn't drift), converts that point back to a
   coordinate via `MapProxy.convert(_:from:)`, and sets
   `radiusMeters = distance(from: checkpoint center)`, clamped 10...1000.
3. `.onEnded` clears the drag state and persists via `saveCheckpoints()`.

Deliberately used `MapProxy`'s coordinate<->point conversion rather than a
manual meters-per-pixel calculation from the map's region span and view
size -- `MapProxy` already accounts for the current zoom/projection
correctly, and the existing tap-to-add-checkpoint code already relied on
the same API (`proxy.convert(point, from: .local)`), so this follows an
established, already-verified-working pattern rather than introducing a
second, parallel math path that could disagree with it.

Verified with `xcodebuild ... build` → `BUILD SUCCEEDED`, no warnings.
Confirmed `MapProxy.convert(_:to:)` (coordinate → point) exists and has
the expected signature by letting the build itself validate it, not by
assuming from memory.

## Bug fixes round 3: location deadlock, spurious "cancelled" alert

Two real, confirmed-from-code bugs reported after round 2 shipped:

- **"WatchPoint: cancelled" popup when switching accounts.** Every
  `AppState` network method's `catch` block did `alertMessage =
  error.localizedDescription`, with no distinction between a real failure
  and a request that was cancelled on purpose. Switching accounts quickly
  (or `.task(id:)` in `ConnectTab` restarting its polling loop when
  `selectedAdminAccountId` changes) cancels in-flight requests as a normal
  matter of course -- `URLError.cancelled`'s `localizedDescription` is
  literally "cancelled," which is exactly what the user saw as
  "WatchPoint: cancelled" (the alert's title is hardcoded to "WatchPoint").
  Added `AppState.presentError(_:)`, which swallows `CancellationError`
  and `URLError.cancelled` instead of surfacing them, and replaced all 9
  call sites (verified by grep, not assumed) with it.
- **Checkpoint placement was fully deadlocked -- "not working at all" was
  accurate.** `locationManager.startUpdatingLocation()` was *only* ever
  called from inside `startPatrol()`. But: "Start Live Patrol" is disabled
  until at least one checkpoint exists: `.disabled(appState.checkpoints.isEmpty)`,
  and (from the previous round's fix) "Drop At My Location" is disabled
  until `currentLocation` is non-nil. Since `currentLocation` only ever
  got set inside `locationManager(_:didUpdateLocations:)`, which only
  fires after `startUpdatingLocation()` is called, which only happens
  inside `startPatrol()`, which requires a checkpoint to already exist --
  there was no way to ever place the first checkpoint. Confirmed this by
  reading `requestLocationAccess()` (only requested *permission*, never
  started updates) and `locationManagerDidChangeAuthorization` (only
  started updates `if shiftIsActive`). Fixed by decoupling "watch my
  location for map/checkpoint purposes" from "patrol is actively running":
  `requestLocationAccess()` now also calls `startUpdatingLocation()`
  whenever already authorized, `locationManagerDidChangeAuthorization`
  starts updates as soon as permission is granted regardless of
  `shiftIsActive`, and a new `stopWatchingLocationIfIdle()` (called from
  `PatrolTab.onDisappear`) stops updates again when leaving the tab if no
  patrol is actually running, so this doesn't run location services
  forever just because the tab was opened once. Also reworded the "waiting
  for GPS" caption (the user said they didn't understand what it meant)
  into three concrete states based on `locationAuthorization`: permission
  denied → tells them to go to Settings; not yet asked → tells them a
  prompt should appear; authorized but no fix yet → "Finding your
  location…".
- **"main" account removal**: asked the user directly rather than guessing
  whether to lift the server-side restriction (crosses into the backend
  session's territory). They chose to keep it protected — no change made,
  none needed. The existing inline explanation ("main can't be removed,
  log it out instead") stands as the intended behavior, not a bug.

Rebuilt with `xcodebuild ... build` → `BUILD SUCCEEDED`, no warnings in
changed files.

## Bug fixes round 2: map radius, QR scannability, Setup overview

- **Map showed no radius circle around the user's actual location.** Root
  cause was two bugs, not one: (1) `AppState.addCheckpoint()` silently
  fell back to a hardcoded coordinate (Waterloo, ON) whenever
  `currentLocation` was nil, so "Drop At My Location" before a GPS fix
  arrived placed a checkpoint nowhere near the user with zero indication
  anything was wrong; (2) the map's camera never recentered onto the
  user's real position -- it stayed on that same hardcoded default region
  forever unless they manually dragged/zoomed. Fixed both:
  `addCheckpoint()` now returns `String?` (`@discardableResult`) and
  returns `nil` without adding anything when no coordinate can be
  resolved; the "Drop At My Location" button is disabled with an inline
  explanation while waiting for a fix; and `PatrolTab` recenters the map
  once, the first time `appState.currentLocation` becomes non-nil (via
  `.onChange(of: appState.currentLocation?.coordinate.latitude)` --
  `CLLocation` itself isn't `Equatable` so this keys off the latitude
  `Double` as a proxy for "location changed").
- **Radius adjustment made more discoverable.** The per-checkpoint radius
  `Stepper` already existed in the list below the map, but requiring a
  scroll away from the map (where the visual feedback actually is) meant
  it was easy to miss. Added a `Slider`-based quick editor directly under
  the map for whichever checkpoint was most recently tapped/dropped
  (`lastAddedCheckpointId`), so the radius circle's live resize is visible
  in the same screenful as the control that changes it.
- **QR code shown on the same device you'd scan with -- the fundamental
  problem.** This is a real UX flaw the redesign inherited from treating
  "Connect" as a single-device flow: WhatsApp linked-device pairing
  requires *two* physical devices (one displaying the QR, one with a
  camera scanning it), but WatchPoint puts the QR on the guard's own
  phone screen, which that same phone's camera obviously can't scan.
  What shipped now is a practical mitigation, not a structural fix: the
  QR is tappable to open a full-screen view (`FullscreenQRView`, easier
  to read from across a room or off a mirrored/AirPlayed display) plus a
  `ShareLink` to send the QR image to a different device via
  AirDrop/Messages, and the caption now explicitly says "you need a
  **different** phone to scan this." **This still requires the guard to
  have physical access to a second device** (a laptop showing the QR big,
  or literally a second phone) at setup time -- normal for the browser
  flow (laptop + phone), awkward for a single-phone WatchPoint user.
  **The actual fix** is supporting WhatsApp's pairing-code linking
  (`client.requestPairingCode(phoneNumber)` in `whatsapp-web.js`, which
  shows an 8-digit code the user types into WhatsApp's own "Link with
  phone number" flow -- no camera needed at all, works fine on one
  device). That needs a new engine endpoint and is backend-session work;
  flagged below.
- **Setup tab now shows an overview + Edit button instead of always
  starting the wizard at step 1.** Added `isEditing` state: by default the
  tab shows a read-only summary (chat/days/shift/message) plus a quick
  "Automatic sending" toggle that saves immediately on change
  (`.onChange` → `saveConfig()`, no need to enter the wizard just to flip
  one switch), and an "Edit Setup" button that enters the 5-step wizard
  starting at step 1. Finishing the wizard ("Save & Done" on a confirmed
  successful save) returns to the overview automatically; a new "Cancel"
  toolbar button in the wizard also returns to the overview without
  finishing. Note: since wizard fields are bound directly to
  `appState.patrolConfig` (no separate draft/staging copy), Cancel does
  *not* revert already-typed edits on the server-side config object --
  only a real save (or navigating away and re-fetching) does. This is
  pre-existing behavior, not a new regression from this change; a real
  draft/rollback would be a bigger change worth doing separately if it
  turns out to matter in practice.
- **"main" account can't be removed -- now explained, not just
  disabled.** This was already intentional (the server's `deleteAccount`
  explicitly rejects removing `id === 'main'`, and other server-side
  fallbacks default to `'main'` when no account is specified), but the
  button was just silently disabled with no explanation, which reads
  identically to a bug. Added inline text explaining why, with "log it
  out instead" as the actual available action. Did not attempt to lift
  this restriction -- that's a backend policy decision, flagged below
  rather than made unilaterally.

Rebuilt after each fix with `xcodebuild ... build` → `BUILD SUCCEEDED`,
zero warnings in changed files.

## Bug fixes + branding

After the 5-tab rework, the user reported the QR login still wasn't
practically usable (nothing refreshed the QR/status automatically), adding
a session froze the app, and asked for the app name and an icon to be set
(both were still Xcode scaffolding defaults).

- **QR login now auto-polls.** `ConnectTab` had a one-shot status fetch on
  first appear and otherwise relied on the user tapping "Refresh Status"
  repeatedly — that's why login "wasn't really possible" in practice: a
  freshly generated QR code, or a status flip to `ready` after scanning,
  would only show up if you happened to tap refresh at the right moment.
  Added a `.task(id: pollKey)` loop that calls `refreshWhatsAppStatus()`
  every 3s until `status == "ready"`, keyed on
  `"\(selectedAdminAccountId)|\(adminToken.isEmpty)"` so it automatically
  restarts on both an account switch and right after login succeeds
  (token flips from empty to set), and stops polling once ready.
- **Add-session freeze, root cause and fix.** `AddAccountSheet` dismissed
  itself immediately on tapping "Add," before the network call even
  started, while `AppState.selectAccount` (called at the end of
  `createAccount`) awaited three admin API calls *serially*
  (`refreshWhatsAppStatus` → `fetchConfig` → `fetchLogs`, each with a 15s
  timeout). With the sheet already gone and no loading indicator anywhere,
  a slow network made the whole app look hung for up to 45s with zero
  feedback. Two fixes: `AppState.selectAccount` now runs those three calls
  concurrently with `async let` (worst case ~15s instead of ~45s), and
  `AddAccountSheet` now stays open with a disabled/spinner "Add" button
  and `.interactiveDismissDisabled(isSubmitting)` until `onAdd` actually
  completes, so the user gets visible progress instead of nothing.
- **App name and icon.** Set `INFOPLIST_KEY_CFBundleDisplayName =
  WatchPoint` explicitly in `WatchPoint.xcodeproj/project.pbxproj` (it was
  previously only implied via `PRODUCT_NAME = "$(TARGET_NAME)"`, which
  happened to also read "WatchPoint" but wasn't an explicit, intentional
  setting). Generated a real app icon since
  `Assets.xcassets/AppIcon.appiconset` had icon slots declared but no
  actual image files — no design tool was available in this environment,
  so it was rendered programmatically: a small Swift/CoreGraphics script
  (not checked into the repo, was a `/tmp` scratch file) draws the
  `shield.lefthalf.filled` SF Symbol in white over a green gradient at
  exactly 1024x1024 with no alpha channel (Apple rejects icons with any
  alpha channel, even fully opaque ones — used a raw `CGContext` with
  `.noneSkipLast` bitmap info to guarantee that, since `NSImage.lockFocus`
  produces Retina-scaled images with alpha by default and `sips` can't
  strip alpha after the fact). Simplified `AppIcon.appiconset/Contents.json`
  down to a single "universal" 1024x1024 entry instead of the default
  light/dark/tinted three-slot scaffold, since only one image was
  provided. Verified in the actual build output: `CFBundleDisplayName` =
  `WatchPoint` and `CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName` =
  `AppIcon` both landed correctly in the compiled `Info.plist`, and
  `AppIcon60x60@2x.png`/`AppIcon76x76@2x~ipad.png` were emplaced into the
  `.app` bundle by `actool`.

Rebuilt after each fix with `xcodebuild ... build` → `BUILD SUCCEEDED`
every time, zero warnings in changed files.

## Navigation redesign #2: 3 tabs -> 5, real UX fixes

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

- **Two additive endpoints for the iOS Host page and duty log** (both
  low-risk, no changes to existing routes). Exact copy-pasteable prompt for
  the backend session:

  > Add two small read-only additions to `server.js`, both additive (no
  > existing route/response shape changes):
  >
  > 1. `GET /api/health` — no auth required (matches `/api/whatsapp`'s
  >    public-read pattern for status-only data). Returns JSON:
  >    `{ ok: true, engineVersion, nodeVersion: process.version, uptimeSeconds: process.uptime(), serverTime: new Date().toISOString(), accounts: { total, connected } }`.
  >    `engineVersion` from this repo's own `package.json` version.
  >    `accounts.total` = length of `readAccounts()`; `accounts.connected` =
  >    count of accounts with an active/ready WhatsApp client.
  > 2. Add optional fields to each entry in `GET /api/logs`'s response:
  >    `accountId` and `accountName` (whichever account produced that log
  >    line), and `level` (`"info" | "warn" | "error"`, inferred from
  >    existing log call sites). Keep the existing `message`/`label`/
  >    `timestamp`/`type`/`id` fields unchanged — these are additions, not
  >    replacements, so the current browser UI and iOS app keep working
  >    unmodified if they ignore the new fields.
  >
  > Context: the iOS WatchPoint app added a Host & Connection diagnostics
  > page and a per-guard duty log, and wants `/api/health` for real engine
  > diagnostics (currently shows "not available yet") and the `/api/logs`
  > fields to attribute log lines to the right guard/account instead of
  > guessing from whichever account is currently selected client-side.

- **Admin Funnel port (10000) TLS handshake is currently broken.**
  `https://hp-server.tailed5092.ts.net:10000` accepts the TCP connection but
  fails the TLS handshake (`SSL_ERROR_SYSCALL`), while the same host's other
  Funnel port (443, n8n) works fine. This means the iOS app currently cannot
  reach the admin API at all ("a TLS error caused the secure connection to
  fail" in-app). Likely `tailscale funnel --bg 10000` needs to be re-armed on
  `hp-server`, or the engine process behind it has died. Needs checking
  directly on the home server -- no shell access to it from this session.
- **WhatsApp pairing-code login** (real fix for the QR-can't-scan-itself
  problem above): a new endpoint that calls
  `client.requestPairingCode(phoneNumber)` (supported by `whatsapp-web.js`)
  and returns the resulting code, so a single-device WatchPoint user can
  type the code into WhatsApp's "Link with phone number" flow instead of
  needing a second device to scan a QR. Needs a phone number input from
  the user and a new `WhatsAppAdminState`-like field for the returned
  code; iOS side is straightforward once the endpoint exists.
- **Should `main` be deletable?** Currently hard-blocked server-side.
  Worth a product decision: if guards are expected to fully replace the
  default account rather than just add more, "main" being permanent could
  be confusing. Not proposing a change myself since other server code
  defaults to `'main'` when no account is specified -- deleting it might
  have wider effects than just this one account-list feature.
- If `server.js`'s `/api/config` semantics change later (full-object PUT,
  `groupName` matched by chat name), check this file's assumptions still
  hold before shipping.

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
