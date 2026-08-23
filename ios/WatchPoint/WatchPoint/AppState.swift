//
//  AppState.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Combine
import CoreLocation
import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
final class AppState: NSObject, ObservableObject, CLLocationManagerDelegate {
    // The API base URL, selected account, app-lock preference, and guard
    // confirmation timestamps are device-local connection/security state.
    // Guard identity, patrol settings, checkpoints, session state, dedupe
    // state, and history all live on the Scheduler API.
    @AppStorage("schedulerAdminBaseURL") var schedulerAdminBaseURL = productionSchedulerAdminURL
    @AppStorage("selectedAdminAccountId") var selectedAdminAccountId = "main"
    @AppStorage("watchpoint.appLockEnabled") var appLockEnabled = true
    @Published var accuracyThresholdMeters = 50.0
    @Published var checkpointCooldownMinutes = 12.0
    @Published var shiftIsActive = false
    @Published var guardName: String = ""
    @Published var checkpoints: [Checkpoint] = []
    @Published var history: [PatrolEvent] = []
    @Published var adminAccounts: [SchedulerAccount] = []
    @Published var whatsAppState: WhatsAppAdminState?
    @Published var schedulerHealth: SchedulerHealth?
    @Published var patrolConfig: PatrolConfig?
    @Published var isConfigLoading = false
    @Published var logs: [SchedulerLogEntry] = []
    @Published var currentLocation: CLLocation?
    @Published var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published var isAdminLoading = false
    @Published var isRetrying = false
    @Published var isClearingActivity = false
    @Published var deletingCheckpointIds: Set<String> = []
    @Published var alertMessage: String?
    @Published var apiCompatibilityMessage: String?
    @Published var requiresAdminLogin = false
    @Published var isAppLocked = true
    @Published var isAuthenticatingApp = false
    @Published var appLockError: String?
    @Published var guardReconfirmationRequired = false
    @Published var patrolStatus: PatrolStatusResponse?
    @Published var patrolStatusTimer: Timer?

    private let locationManager = CLLocationManager()
    private let guardReconfirmationInterval: TimeInterval = 4 * 60 * 60

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationManager.activityType = .fitness
        locationManager.pausesLocationUpdatesAutomatically = false
        locationAuthorization = locationManager.authorizationStatus
        isAppLocked = appLockEnabled
    }

    var adminToken: String {
        KeychainStore.token(accountId: selectedAdminAccountId)
    }

    var selectedAccountName: String {
        adminAccounts.first(where: { $0.id == selectedAdminAccountId })?.name
            ?? whatsAppState?.account?.name
            ?? selectedAdminAccountId
    }

    var guardDisplayName: String {
        let trimmed = guardName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this guard" : trimmed
    }

    var versionCompatibilityLabel: String {
        guard let health = schedulerHealth else { return "Engine not checked" }
        if !AppRelease.isVersion(health.engineVersion, atLeast: AppRelease.requiredEngineVersion) {
            return "Server update required"
        }
        if let minimumIOSVersion = health.minimumIOSVersion,
           !AppRelease.isVersion(AppRelease.version, atLeast: minimumIOSVersion) {
            return "iOS update required"
        }
        return "Up to date"
    }

    func setAppLockEnabled(_ enabled: Bool) {
        appLockEnabled = enabled
        if !enabled {
            isAppLocked = false
            appLockError = nil
        }
    }

    func lockApp() {
        guard appLockEnabled else { return }
        isAppLocked = true
        appLockError = nil
    }

    func unlockApp() async {
        guard appLockEnabled, isAppLocked, !isAuthenticatingApp else { return }

        isAuthenticatingApp = true
        appLockError = nil
        defer { isAuthenticatingApp = false }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            appLockError = policyError?.localizedDescription
                ?? "Face ID or a device passcode must be configured to unlock WatchPoint."
            return
        }

        do {
            if try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock guard accounts and patrol data."
            ) {
                isAppLocked = false
            }
        } catch {
            appLockError = error.localizedDescription
        }
    }

    func refreshGuardReconfirmationRequirement(now: Date = Date()) {
        guard !adminToken.isEmpty else {
            guardReconfirmationRequired = false
            return
        }
        guard let lastConfirmed = UserDefaults.standard.object(
            forKey: guardConfirmationKey(selectedAdminAccountId)
        ) as? Date else {
            guardReconfirmationRequired = true
            return
        }
        guardReconfirmationRequired = now.timeIntervalSince(lastConfirmed) >= guardReconfirmationInterval
    }

    func confirmCurrentGuard(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: guardConfirmationKey(selectedAdminAccountId))
        guardReconfirmationRequired = false
    }

    private func guardConfirmationKey(_ accountId: String) -> String {
        "watchpoint.guardLastConfirmed.\(accountId)"
    }

    /// Shows an alert for a real failure, but swallows cancellation --
    /// switching accounts/tabs quickly cancels in-flight requests as a
    /// matter of course (SwiftUI cancels `.task` when its id changes, and
    /// `selectAccount` supersedes itself when called again before the
    /// previous call finishes). That's expected, not an error, and
    /// surfacing it as "WatchPoint: cancelled" just confused whether
    /// something had actually gone wrong.
    ///
    /// A 401 here means the server rejected our stored session token --
    /// expired (`SESSION_TOKEN_TTL_HOURS`) or wiped by an engine restart,
    /// since `server.js` keeps sessions in memory only. Before this, the app
    /// only checked whether a token was *present* in Keychain, not whether
    /// the server still considered it valid, so a stale token left the UI
    /// stuck showing "connected" controls (Refresh/Logout/Remove) forever --
    /// every tap just re-surfaced the same "Enter the password for ..."
    /// error with no way to actually reach a password field. Clearing the
    /// token here means the next render's `adminToken.isEmpty` check is
    /// true again, so the view falls back to the login field on its own.
    private func presentError(_ error: Error) {
        if error is CancellationError { return }
        if let urlError = error as? URLError, urlError.code == .cancelled { return }
        if case let SchedulerAdminError.http(status, _) = error, status == 401 {
            requireAdminLogin()
            return
        }
        alertMessage = error.localizedDescription
    }

    private func requireAdminLogin() {
        KeychainStore.clearToken(accountId: selectedAdminAccountId)
        requiresAdminLogin = true
    }

    private func presentPatrolCompatibilityError(_ error: Error) -> Bool {
        guard case let SchedulerAdminError.http(status, _) = error,
              status == 404 || status == 405 else {
            return false
        }
        apiCompatibilityMessage = "This Scheduler API is too old for the iOS patrol features. Update and restart the server, then refresh this app."
        return true
    }

    var nearestCheckpoint: (checkpoint: Checkpoint, distance: CLLocationDistance)? {
        guard let currentLocation, !checkpoints.isEmpty else { return nil }
        return checkpoints
            .map { checkpoint in
                (
                    checkpoint,
                    currentLocation.distance(
                        from: CLLocation(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                    )
                )
            }
            .sorted { $0.1 < $1.1 }
            .first
    }

    /// Requests permission if needed, and starts watching location if
    /// already authorized. This runs independently of `shiftIsActive` --
    /// placing a checkpoint at "my location" needs `currentLocation` to be
    /// populated *before* a patrol starts, and starting a patrol requires
    /// at least one checkpoint to already exist, so gating location
    /// updates behind "patrol is active" made it impossible to ever place
    /// the first checkpoint.
    func requestLocationAccess() {
        locationAuthorization = locationManager.authorizationStatus
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            configureBackgroundLocation(forActivePatrol: shiftIsActive)
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    /// Stops location updates when nothing needs them anymore -- called
    /// when leaving the Patrol tab while no patrol is active, so watching
    /// location doesn't run indefinitely just because the tab was opened
    /// once. Does nothing while a patrol is actually running.
    func stopWatchingLocationIfIdle() {
        guard !shiftIsActive else { return }
        locationManager.stopUpdatingLocation()
    }

    func startPatrol() async {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
            alertMessage = "Allow location access, then tap Start Live Patrol again."
            return
        case .denied:
            alertMessage = "Location access is off for WatchPoint. Open iOS Settings and allow location access before starting patrol."
            return
        case .restricted:
            alertMessage = "Location access is restricted on this device, so live patrol cannot start."
            return
        case .authorizedAlways, .authorizedWhenInUse:
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                // Upgrade is requested at the moment the guard starts a
                // feature that clearly needs background location.
                locationManager.requestAlwaysAuthorization()
            }
            break
        @unknown default:
            alertMessage = "WatchPoint could not determine the location permission. Check iOS Settings and try again."
            return
        }

        guard await savePatrolState(active: true) else { return }
        configureBackgroundLocation(forActivePatrol: true)
        locationManager.startUpdatingLocation()
    }

    @discardableResult
    func stopPatrol() async -> Bool {
        guard await savePatrolState(active: false) else { return false }
        configureBackgroundLocation(forActivePatrol: false)
        locationManager.stopUpdatingLocation()
        return true
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
        if locationAuthorization == .authorizedWhenInUse || locationAuthorization == .authorizedAlways {
            configureBackgroundLocation(forActivePatrol: shiftIsActive)
            manager.startUpdatingLocation()
        } else if locationAuthorization == .denied || locationAuthorization == .restricted {
            currentLocation = nil
            manager.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        guard shiftIsActive else { return }
        Task { await submitLocation(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let locationError = error as? CLError {
            switch locationError.code {
            case .denied:
                locationAuthorization = manager.authorizationStatus
                currentLocation = nil
                manager.stopUpdatingLocation()
                return
            case .locationUnknown:
                // This is temporary. Core Location keeps trying and normally
                // produces a valid fix without any action from the user.
                return
            default:
                break
            }
        }
        presentError(error)
    }

    /// Returns the new checkpoint's id on success. Returns nil (and adds
    /// nothing) when no explicit coordinate is given and there's no GPS fix
    /// yet -- silently falling back to a hardcoded default coordinate
    /// (previously Waterloo, ON) meant "Drop At My Location" could drop a
    /// checkpoint nowhere near the user with no indication anything was
    /// wrong.
    @discardableResult
    func addCheckpoint(latitude: Double? = nil, longitude: Double? = nil) async -> String? {
        let resolvedLatitude = latitude ?? currentLocation?.coordinate.latitude
        let resolvedLongitude = longitude ?? currentLocation?.coordinate.longitude
        guard let resolvedLatitude, let resolvedLongitude else { return nil }

        let next = checkpoints.count + 1
        let id = UUID().uuidString.lowercased()
        checkpoints.append(
            Checkpoint(
                id: id,
                name: "Checkpoint \(next)",
                latitude: resolvedLatitude,
                longitude: resolvedLongitude,
                radiusMeters: 100
            )
        )
        if await savePatrolState() { return id }
        checkpoints.removeAll { $0.id == id }
        return nil
    }

    func deleteCheckpoint(_ checkpoint: Checkpoint) async {
        guard deletingCheckpointIds.insert(checkpoint.id).inserted else { return }
        defer { deletingCheckpointIds.remove(checkpoint.id) }

        let previous = checkpoints
        checkpoints.removeAll { $0.id == checkpoint.id }
        if !(await savePatrolState()) {
            checkpoints = previous
        }
    }

    func saveCheckpoints() async {
        _ = await savePatrolState()
    }

    func manualTrigger(_ checkpoint: Checkpoint) async {
        guard let api = adminAPI else { return }
        do {
            let response = try await api.sendPatrolEvent(
                PatrolEventRequest(
                    checkpointId: checkpoint.id,
                    source: "watchpoint-ios-manual",
                    eventType: "arrival",
                    lat: currentLocation?.coordinate.latitude,
                    lng: currentLocation?.coordinate.longitude,
                    accuracyMeters: currentLocation?.horizontalAccuracy
                )
            )
            applyPatrolState(response.state)
        } catch {
            presentError(error)
        }
    }

    func retryQueuedEvents() async {
        isRetrying = true
        defer { isRetrying = false }

        guard let api = adminAPI else { return }
        do {
            let response = try await api.retryPatrolEvents()
            applyPatrolState(response.state)
        } catch {
            presentError(error)
        }
    }

    func fetchAdminAccounts() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            adminAccounts = try await api.accounts()
            if !adminAccounts.contains(where: { $0.id == selectedAdminAccountId }) {
                selectedAdminAccountId = adminAccounts.first?.id ?? "main"
            }
        } catch {
            presentError(error)
        }
    }

    /// One startup owner prevents every TabView child from issuing the same
    /// requests. Health runs alongside account discovery; selected-account
    /// reads then fan out in parallel once account identity is known.
    func bootstrap() async {
        async let health: Void = refreshEngineHealth()
        await fetchAdminAccounts()
        if !adminToken.isEmpty {
            await selectAccount(selectedAdminAccountId, confirmsGuard: false)
        }
        _ = await health
    }

    func refreshEngineHealth() async {
        guard let api = adminAPI else { return }
        do {
            recordSchedulerHealth(try await api.health())
        } catch {
            schedulerHealth = nil
            if case let SchedulerAdminError.http(status, _) = error, status == 404 || status == 405 {
                apiCompatibilityMessage = "This Scheduler API is too old. Engine \(AppRelease.requiredEngineVersion) or newer is required."
            }
        }
    }

    func recordSchedulerHealth(_ health: SchedulerHealth) {
        schedulerHealth = health
        if !AppRelease.isVersion(health.engineVersion, atLeast: AppRelease.requiredEngineVersion) {
            apiCompatibilityMessage = "Scheduler engine \(health.engineVersion) is outdated. Update the server to \(AppRelease.requiredEngineVersion) or newer."
        } else if let minimumIOSVersion = health.minimumIOSVersion,
                  !AppRelease.isVersion(AppRelease.version, atLeast: minimumIOSVersion) {
            apiCompatibilityMessage = "WatchPoint \(AppRelease.version) is outdated. Install iOS version \(minimumIOSVersion) or newer."
        } else {
            apiCompatibilityMessage = nil
        }
    }

    func loginAdmin(password: String) async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            let response = try await api.login(password: password)
            KeychainStore.setToken(response.token, accountId: response.account.id)
            requiresAdminLogin = false
            await selectAccount(response.account.id, confirmsGuard: true)
        } catch {
            presentError(error)
        }
    }

    @discardableResult
    func createAccount(name: String, password: String) async -> Bool {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return false
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            let response = try await api.createAccount(name: name, password: password)
            adminAccounts = response.accounts
            KeychainStore.setToken(response.token, accountId: response.account.id)
            requiresAdminLogin = false
            await selectAccount(response.account.id, confirmsGuard: true)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func deleteSelectedAccount() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            let response = try await api.deleteAccount()
            KeychainStore.clearToken(accountId: selectedAdminAccountId)
            adminAccounts = response.accounts
            await selectAccount(response.accounts.first?.id ?? "main", confirmsGuard: true)
        } catch {
            presentError(error)
        }
    }

    /// Switching accounts stops the old account's server-side patrol before
    /// loading the new account's complete API-backed state.
    func selectAccount(_ accountId: String, confirmsGuard: Bool = true) async {
        let isSwitchingAccounts = accountId != selectedAdminAccountId

        // App unlock recreates the tab hierarchy and refreshes the already
        // selected account. Only a real account change should stop patrol;
        // treating a same-account refresh as a switch stopped every active
        // patrol whenever the app lock appeared.
        if isSwitchingAccounts, shiftIsActive, !adminToken.isEmpty {
            guard await stopPatrol() else { return }
        }
        selectedAdminAccountId = accountId
        if isSwitchingAccounts {
            whatsAppState = nil
            patrolConfig = nil
            logs = []
            guardName = ""
            checkpoints = []
            history = []
            shiftIsActive = false
        }

        guard !adminToken.isEmpty else { return }
        async let status: Void = refreshWhatsAppStatus()
        async let config: Void = fetchConfig()
        async let recentLogs: Void = fetchLogs()
        async let patrol: Void = fetchPatrolState()
        _ = await (status, config, recentLogs, patrol)
        if confirmsGuard {
            confirmCurrentGuard()
        } else {
            refreshGuardReconfirmationRequirement()
        }
    }

    func refreshWhatsAppStatus() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            whatsAppState = try await api.whatsAppStatus()
        } catch {
            presentError(error)
        }
    }

    func fetchConfig() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isConfigLoading = true
        defer { isConfigLoading = false }

        do {
            patrolConfig = try await api.config().config
        } catch {
            presentError(error)
        }
    }

    /// Returns true only on a confirmed successful save, so callers can show
    /// an explicit "Saved" confirmation instead of assuming success.
    @discardableResult
    func saveConfig() async -> Bool {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return false
        }
        guard let patrolConfig else { return false }

        isConfigLoading = true
        defer { isConfigLoading = false }

        do {
            self.patrolConfig = try await api.updateConfig(patrolConfig).config
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func fetchLogs() async {
        guard let api = adminAPI else { return }
        do {
            logs = try await api.logs()
        } catch {
            // Activity log is a nice-to-have; don't surface an alert for it,
            // but still drop a stale token on 401 -- see presentError.
            if case let SchedulerAdminError.http(status, _) = error, status == 401 {
                requireAdminLogin()
            }
        }
    }

    func fetchPatrolStatus() async {
        guard let api = adminAPI else { return }
        do {
            patrolStatus = try await api.patrolStatus()
        } catch {
            if case let SchedulerAdminError.http(status, _) = error, status == 401 {
                requireAdminLogin()
            }
        }
    }

    func startPatrolStatusUpdates() {
        // Fetch immediately, then update every 5 seconds
        Task {
            await fetchPatrolStatus()
        }
        patrolStatusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.fetchPatrolStatus()
            }
        }
    }

    func stopPatrolStatusUpdates() {
        patrolStatusTimer?.invalidate()
        patrolStatusTimer = nil
    }

    @discardableResult
    func clearActivityLogs(scope: ActivityClearScope) async -> Bool {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return false
        }

        isClearingActivity = true
        defer { isClearingActivity = false }

        do {
            let response = try await api.clearActivityLogs(scope: scope)
            logs = response.logs
            applyPatrolState(response.state)
            return response.ok
        } catch {
            if case let SchedulerAdminError.http(status, _) = error,
               status == 404 || status == 405 {
                apiCompatibilityMessage = "Clear Activity requires Scheduler engine \(AppRelease.requiredEngineVersion) or newer. Update and restart the server, then refresh this app."
                alertMessage = apiCompatibilityMessage
                return false
            }
            presentError(error)
            return false
        }
    }

    func fetchPatrolState() async {
        guard let api = adminAPI else { return }
        do {
            let state = try await api.patrolState()
            applyPatrolState(try await migrateLegacyPatrolStateIfNeeded(state, api: api))
            if let schedulerHealth { recordSchedulerHealth(schedulerHealth) }
        } catch {
            if presentPatrolCompatibilityError(error) { return }
            presentError(error)
        }
    }

    private func migrateLegacyPatrolStateIfNeeded(
        _ serverState: PatrolStateResponse,
        api: SchedulerAdminAPI
    ) async throws -> PatrolStateResponse {
        let defaults = UserDefaults.standard
        let migrationKey = "watchpoint.serverPatrolMigrated.\(selectedAdminAccountId)"
        guard !defaults.bool(forKey: migrationKey) else { return serverState }

        func decode<T: Decodable>(_ key: String, as type: T.Type) -> T? {
            guard let data = defaults.data(forKey: "\(key).\(selectedAdminAccountId)") ?? defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }

        let legacyCheckpoints = decode("watchpoint.checkpoints", as: [Checkpoint].self) ?? []
        let legacyHistory = decode("watchpoint.history", as: [PatrolEvent].self) ?? []
        let legacyGuardName = decode("watchpoint.guardName", as: String.self) ?? defaults.string(forKey: "guardName")
        let hasLegacyData = !legacyCheckpoints.isEmpty || !legacyHistory.isEmpty || legacyGuardName != nil
        var result = serverState

        if hasLegacyData {
            result = try await api.importLegacyPatrolState(
                PatrolImportRequest(
                    profile: legacyGuardName.map { GuardProfile(name: $0) },
                    settings: PatrolSettings(
                        accuracyThresholdMeters: defaults.object(forKey: "accuracyThresholdMeters") as? Double ?? 50,
                        checkpointCooldownMinutes: defaults.object(forKey: "checkpointCooldownMinutes") as? Double ?? 12
                    ),
                    checkpoints: legacyCheckpoints,
                    history: legacyHistory
                )
            )
        }

        for key in ["watchpoint.checkpoints", "watchpoint.history", "watchpoint.insideState", "watchpoint.lastSentAtByCheckpoint", "watchpoint.guardName"] {
            defaults.removeObject(forKey: "\(key).\(selectedAdminAccountId)")
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: "guardName")
        defaults.set(true, forKey: migrationKey)
        return result
    }

    @discardableResult
    func savePatrolState(active: Bool? = nil) async -> Bool {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return false
        }

        let requestedSession = PatrolSession(active: active ?? shiftIsActive, updatedAt: nil)
        do {
            let response = try await api.updatePatrolState(
                PatrolStateUpdateRequest(
                    profile: GuardProfile(name: guardName),
                    settings: PatrolSettings(
                        accuracyThresholdMeters: accuracyThresholdMeters,
                        checkpointCooldownMinutes: checkpointCooldownMinutes
                    ),
                    checkpoints: checkpoints,
                    session: requestedSession
                )
            )
            applyPatrolState(response)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func applyPatrolState(_ state: PatrolStateResponse) {
        guardName = state.profile.name
        accuracyThresholdMeters = state.settings.accuracyThresholdMeters
        checkpointCooldownMinutes = state.settings.checkpointCooldownMinutes
        checkpoints = state.checkpoints
        history = state.history
        shiftIsActive = state.session.active
        configureBackgroundLocation(forActivePatrol: state.session.active)
    }

    private func configureBackgroundLocation(forActivePatrol active: Bool) {
        // The project declares UIBackgroundModes=location. Enabling this
        // only for a live patrol prevents map browsing from becoming
        // continuous background tracking.
        locationManager.allowsBackgroundLocationUpdates = active
        locationManager.showsBackgroundLocationIndicator = active
    }

    private func submitLocation(_ location: CLLocation) async {
        guard let api = adminAPI else { return }
        do {
            let response = try await api.sendLocation(
                PatrolLocationRequest(
                    source: "watchpoint-ios",
                    lat: location.coordinate.latitude,
                    lng: location.coordinate.longitude,
                    accuracyMeters: location.horizontalAccuracy
                )
            )
            applyPatrolState(response.state)
        } catch {
            if case let SchedulerAdminError.http(status, _) = error, status == 409 {
                await fetchPatrolState()
                return
            }
            presentError(error)
        }
    }

    func logoutWhatsApp() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            whatsAppState = try await api.logoutWhatsApp()
        } catch {
            presentError(error)
        }
    }

    private var adminAPI: SchedulerAdminAPI? {
        guard let url = URL(string: schedulerAdminBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return SchedulerAdminAPI(baseURL: url, accountId: selectedAdminAccountId, token: adminToken)
    }

}
