//
//  AppState.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import Combine
import CoreLocation
import Foundation
import SwiftUI

@MainActor
final class AppState: NSObject, ObservableObject, CLLocationManagerDelegate {
    @AppStorage("webhookURL") var webhookURL = productionPatrolWebhookURL
    @AppStorage("schedulerAdminBaseURL") var schedulerAdminBaseURL = productionSchedulerAdminURL
    @AppStorage("selectedAdminAccountId") var selectedAdminAccountId = "main"
    @AppStorage("guardName") var guardName = "navjot"
    @AppStorage("accuracyThresholdMeters") var accuracyThresholdMeters = 50.0
    @AppStorage("checkpointCooldownMinutes") var checkpointCooldownMinutes = 12.0
    @AppStorage("shiftIsActive") var shiftIsActive = false

    @Published var checkpoints: [Checkpoint] = []
    @Published var history: [PatrolEvent] = []
    @Published var adminAccounts: [SchedulerAccount] = []
    @Published var whatsAppState: WhatsAppAdminState?
    @Published var patrolConfig: PatrolConfig?
    @Published var isConfigLoading = false
    @Published var logs: [SchedulerLogEntry] = []
    @Published var currentLocation: CLLocation?
    @Published var locationAuthorization: CLAuthorizationStatus = .notDetermined
    @Published var isAdminLoading = false
    @Published var isRetrying = false
    @Published var alertMessage: String?

    private let locationManager = CLLocationManager()
    private var insideState: [String: Bool] = [:]
    private var lastSentAtByCheckpoint: [String: Date] = [:]

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 10
        locationAuthorization = locationManager.authorizationStatus

        checkpoints = LocalJSONStore.load("watchpoint.checkpoints") ?? []
        history = LocalJSONStore.load("watchpoint.history") ?? []
        insideState = LocalJSONStore.load("watchpoint.insideState") ?? [:]
        lastSentAtByCheckpoint = LocalJSONStore.load("watchpoint.lastSentAtByCheckpoint") ?? [:]
    }

    var adminToken: String {
        KeychainStore.token(accountId: selectedAdminAccountId)
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
            KeychainStore.clearToken(accountId: selectedAdminAccountId)
        }
        alertMessage = error.localizedDescription
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
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
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

    func startPatrol() {
        shiftIsActive = true
        requestLocationAccess()
        locationManager.startUpdatingLocation()
    }

    func stopPatrol() {
        shiftIsActive = false
        locationManager.stopUpdatingLocation()
        insideState.removeAll()
        saveDedupeState()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorization = manager.authorizationStatus
        if shiftIsActive || locationAuthorization == .authorizedWhenInUse || locationAuthorization == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        currentLocation = location
        guard shiftIsActive else { return }
        evaluateCheckpointEntry(location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        presentError(error)
    }

    /// Returns the new checkpoint's id on success. Returns nil (and adds
    /// nothing) when no explicit coordinate is given and there's no GPS fix
    /// yet -- silently falling back to a hardcoded default coordinate
    /// (previously Waterloo, ON) meant "Drop At My Location" could drop a
    /// checkpoint nowhere near the user with no indication anything was
    /// wrong.
    @discardableResult
    func addCheckpoint(latitude: Double? = nil, longitude: Double? = nil) -> String? {
        let resolvedLatitude = latitude ?? currentLocation?.coordinate.latitude
        let resolvedLongitude = longitude ?? currentLocation?.coordinate.longitude
        guard let resolvedLatitude, let resolvedLongitude else { return nil }

        let next = checkpoints.count + 1
        let id = "checkpoint-\(next)"
        checkpoints.append(
            Checkpoint(
                id: id,
                name: "Checkpoint \(next)",
                latitude: resolvedLatitude,
                longitude: resolvedLongitude,
                radiusMeters: 100
            )
        )
        saveCheckpoints()
        return id
    }

    func deleteCheckpoint(_ checkpoint: Checkpoint) {
        checkpoints.removeAll { $0.id == checkpoint.id }
        insideState.removeValue(forKey: checkpoint.id)
        lastSentAtByCheckpoint.removeValue(forKey: checkpoint.id)
        saveCheckpoints()
        saveDedupeState()
    }

    func saveCheckpoints() {
        LocalJSONStore.save(checkpoints, "watchpoint.checkpoints")
    }

    func manualTrigger(_ checkpoint: Checkpoint) async {
        await enqueueAndSend(makeEvent(checkpoint: checkpoint, location: currentLocation))
    }

    func retryQueuedEvents() async {
        isRetrying = true
        defer { isRetrying = false }

        let retryable = history
            .filter { [.queued, .failed, .engineNotReady].contains($0.status) && $0.retryCount < 5 }
            .sorted { $0.timestamp < $1.timestamp }

        for event in retryable {
            await sendEvent(event)
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

    func loginAdmin(password: String) async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            let response = try await api.login(password: password)
            selectedAdminAccountId = response.account.id
            KeychainStore.setToken(response.token, accountId: response.account.id)
            await refreshWhatsAppStatus()
        } catch {
            presentError(error)
        }
    }

    func createAccount(name: String, password: String) async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }

        isAdminLoading = true
        defer { isAdminLoading = false }

        do {
            let response = try await api.createAccount(name: name, password: password)
            adminAccounts = response.accounts
            KeychainStore.setToken(response.token, accountId: response.account.id)
            await selectAccount(response.account.id)
        } catch {
            presentError(error)
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
            await selectAccount(response.accounts.first?.id ?? "main")
        } catch {
            presentError(error)
        }
    }

    /// Switches the active account and reloads everything scoped to it --
    /// WhatsApp status, schedule config, and logs are all per-account.
    func selectAccount(_ accountId: String) async {
        selectedAdminAccountId = accountId
        whatsAppState = nil
        patrolConfig = nil
        logs = []

        guard !adminToken.isEmpty else { return }
        // Run concurrently -- these are three independent GET requests, no
        // reason to make the user wait for them serially (each has its own
        // 15s timeout, so doing this one-at-a-time can look like a freeze).
        async let status: Void = refreshWhatsAppStatus()
        async let config: Void = fetchConfig()
        async let recentLogs: Void = fetchLogs()
        _ = await (status, config, recentLogs)
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
                KeychainStore.clearToken(accountId: selectedAdminAccountId)
            }
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

    private func evaluateCheckpointEntry(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= accuracyThresholdMeters else {
            return
        }

        for checkpoint in checkpoints {
            let checkpointLocation = CLLocation(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
            let isInside = location.distance(from: checkpointLocation) <= checkpoint.radiusMeters
            let wasInside = insideState[checkpoint.id] ?? false

            if !wasInside && isInside && canSend(checkpoint) {
                Task { await enqueueAndSend(makeEvent(checkpoint: checkpoint, location: location)) }
            }

            insideState[checkpoint.id] = isInside
        }

        saveDedupeState()
    }

    private func canSend(_ checkpoint: Checkpoint) -> Bool {
        guard let lastSentAt = lastSentAtByCheckpoint[checkpoint.id] else { return true }
        return Date().timeIntervalSince(lastSentAt) >= checkpointCooldownMinutes * 60
    }

    private func makeEvent(checkpoint: Checkpoint, location: CLLocation?) -> PatrolEvent {
        let timestamp = Date()
        let payload = PatrolWebhookRequest(
            source: "ios-patrol-app",
            guardName: guardName,
            checkpointId: checkpoint.id,
            checkpointName: checkpoint.name,
            eventType: "arrival",
            timestamp: ISO8601DateFormatter().string(from: timestamp),
            lat: location?.coordinate.latitude ?? checkpoint.latitude,
            lng: location?.coordinate.longitude ?? checkpoint.longitude,
            accuracyMeters: location?.horizontalAccuracy
        )

        return PatrolEvent(
            id: UUID(),
            source: payload.source,
            guardName: payload.guardName,
            checkpointId: payload.checkpointId,
            checkpointName: payload.checkpointName,
            eventType: payload.eventType,
            timestamp: timestamp,
            latitude: payload.lat,
            longitude: payload.lng,
            accuracyMeters: payload.accuracyMeters,
            status: .queued,
            requestPayload: payload,
            webhookReceived: false,
            responseCode: nil,
            schedulerStatusCode: nil,
            responseSummary: nil,
            schedulerReason: nil,
            retryCount: 0,
            lastAttemptAt: nil
        )
    }

    private func enqueueAndSend(_ event: PatrolEvent) async {
        history.insert(event, at: 0)
        saveHistory()
        await sendEvent(event)
    }

    private func sendEvent(_ event: PatrolEvent) async {
        guard let index = history.firstIndex(where: { $0.id == event.id }),
              let url = URL(string: webhookURL) else {
            return
        }

        history[index].status = .sending
        history[index].retryCount += 1
        history[index].lastAttemptAt = Date()
        saveHistory()

        do {
            let (response, statusCode) = try await PatrolService(webhookURL: url).sendPatrolEvent(event.requestPayload)
            apply(response, httpStatusCode: statusCode, eventId: event.id)
        } catch {
            guard let failedIndex = history.firstIndex(where: { $0.id == event.id }) else { return }
            history[failedIndex].status = history[failedIndex].retryCount >= 5 ? .failed : .queued
            history[failedIndex].responseSummary = error.localizedDescription
            saveHistory()
        }
    }

    private func apply(_ response: WebhookResponse, httpStatusCode: Int, eventId: UUID) {
        guard let index = history.firstIndex(where: { $0.id == eventId }) else { return }

        history[index].webhookReceived = true
        history[index].responseCode = httpStatusCode
        history[index].schedulerStatusCode = response.schedulerStatusCode
        history[index].responseSummary = response.message
        history[index].schedulerReason = response.schedulerResponse?.reason

        switch response.schedulerStatusCode {
        case 200:
            history[index].status = .schedulerSucceeded
            if let checkpointId = history[index].checkpointId {
                lastSentAtByCheckpoint[checkpointId] = Date()
            }
        case 409:
            history[index].status = .engineNotReady
        case .some:
            history[index].status = .backendReceived
        case .none:
            history[index].status = response.ok == true ? .backendReceived : .failed
        }

        saveDedupeState()
        saveHistory()
    }

    private func saveHistory() {
        LocalJSONStore.save(Array(history.prefix(200)), "watchpoint.history")
    }

    private func saveDedupeState() {
        LocalJSONStore.save(insideState, "watchpoint.insideState")
        LocalJSONStore.save(lastSentAtByCheckpoint, "watchpoint.lastSentAtByCheckpoint")
    }
}
