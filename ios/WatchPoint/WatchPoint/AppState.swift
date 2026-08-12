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
    @AppStorage("schedulerAdminBaseURL") var schedulerAdminBaseURL = developmentSchedulerAdminURL
    @AppStorage("selectedAdminAccountId") var selectedAdminAccountId = "main"
    @AppStorage("guardName") var guardName = "navjot"
    @AppStorage("accuracyThresholdMeters") var accuracyThresholdMeters = 50.0
    @AppStorage("checkpointCooldownMinutes") var checkpointCooldownMinutes = 12.0
    @AppStorage("shiftIsActive") var shiftIsActive = false

    @Published var checkpoints: [Checkpoint] = []
    @Published var appointments: [PatrolAppointment] = []
    @Published var history: [PatrolEvent] = []
    @Published var adminAccounts: [SchedulerAccount] = []
    @Published var whatsAppState: WhatsAppAdminState?
    @Published var patrolConfig: PatrolConfig?
    @Published var isConfigLoading = false
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
        appointments = LocalJSONStore.load("watchpoint.appointments") ?? []
        history = LocalJSONStore.load("watchpoint.history") ?? []
        insideState = LocalJSONStore.load("watchpoint.insideState") ?? [:]
        lastSentAtByCheckpoint = LocalJSONStore.load("watchpoint.lastSentAtByCheckpoint") ?? [:]
    }

    var adminToken: String {
        KeychainStore.token(accountId: selectedAdminAccountId)
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

    func requestLocationAccess() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
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
        if shiftIsActive {
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
        alertMessage = error.localizedDescription
    }

    func addCheckpoint(latitude: Double? = nil, longitude: Double? = nil) {
        let next = checkpoints.count + 1
        checkpoints.append(
            Checkpoint(
                id: "checkpoint-\(next)",
                name: "Checkpoint \(next)",
                latitude: latitude ?? currentLocation?.coordinate.latitude ?? 43.1394,
                longitude: longitude ?? currentLocation?.coordinate.longitude ?? -80.2644,
                radiusMeters: 100,
                notes: "",
                isActive: true
            )
        )
        saveCheckpoints()
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

    func addAppointment() {
        let start = Date()
        appointments.append(
            PatrolAppointment(
                id: UUID(),
                title: "Patrol Shift",
                startsAt: start,
                endsAt: Calendar.current.date(byAdding: .hour, value: 8, to: start) ?? start,
                isActive: true
            )
        )
        saveAppointments()
    }

    func deleteAppointment(_ appointment: PatrolAppointment) {
        appointments.removeAll { $0.id == appointment.id }
        saveAppointments()
    }

    func saveAppointments() {
        LocalJSONStore.save(appointments, "watchpoint.appointments")
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
            alertMessage = error.localizedDescription
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
            alertMessage = error.localizedDescription
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
            alertMessage = error.localizedDescription
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
            alertMessage = error.localizedDescription
        }
    }

    func saveConfig() async {
        guard let api = adminAPI else {
            alertMessage = "Scheduler admin URL is invalid."
            return
        }
        guard let patrolConfig else { return }

        isConfigLoading = true
        defer { isConfigLoading = false }

        do {
            self.patrolConfig = try await api.updateConfig(patrolConfig).config
        } catch {
            alertMessage = error.localizedDescription
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
            alertMessage = error.localizedDescription
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

        for checkpoint in checkpoints where checkpoint.isActive {
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
