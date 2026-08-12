//
//  ContentView.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

// Three tabs, matching the browser's two pages (Scheduler dashboard,
// GPS Patrol Mode) plus a Settings tab for device-only knobs that have
// no equivalent in the browser (geofence tuning, the n8n webhook URL).
struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var adminPassword = ""
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.1394, longitude: -80.2644),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )

    var body: some View {
        TabView {
            schedulerView
                .tabItem { Label("Scheduler", systemImage: "paperplane.circle") }
            patrolView
                .tabItem { Label("Patrol", systemImage: "shield.lefthalf.filled") }
            settingsView
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert("WatchPoint", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )
    }

    // MARK: - Scheduler
    // Mirrors the browser's single page: connect WhatsApp (QR), then pick
    // the chat, write the message, and set the schedule -- all in one flow.

    private var schedulerView: some View {
        NavigationStack {
            Form {
                connectionSection

                if let config = Binding($appState.patrolConfig), appState.whatsAppState?.status == "ready" {
                    groupSection(config: config)
                    messageSection(config: config)
                    scheduleSection(config: config)
                    saveScheduleSection
                }

                if !appState.logs.isEmpty {
                    activitySection
                }
            }
            .navigationTitle("Scheduler")
            .refreshable { await refreshSchedulerScreen() }
            .task {
                await appState.fetchAdminAccounts()
                if !appState.adminToken.isEmpty {
                    await refreshSchedulerScreen()
                }
            }
        }
    }

    private var connectionSection: some View {
        Section("WhatsApp Account") {
            Picker("Account", selection: $appState.selectedAdminAccountId) {
                if appState.adminAccounts.isEmpty {
                    Text("main").tag("main")
                }
                ForEach(appState.adminAccounts) { account in
                    Text(account.name).tag(account.id)
                }
            }

            WhatsAppConnectionRow(state: appState.whatsAppState)

            if appState.adminToken.isEmpty {
                SecureField("Account password", text: $adminPassword)
                Button {
                    Task {
                        await appState.loginAdmin(password: adminPassword)
                        await refreshSchedulerScreen()
                    }
                } label: {
                    Label("Connect", systemImage: "lock.open")
                }
                .disabled(adminPassword.count < 4 || appState.isAdminLoading)
            } else {
                if let qrDataUrl = appState.whatsAppState?.qrDataUrl,
                   let image = UIImage(dataURL: qrDataUrl) {
                    VStack(spacing: 12) {
                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280)
                            .frame(maxWidth: .infinity)
                        Text("Open WhatsApp > Settings > Linked Devices > Link a Device, then scan this QR.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    Task { await appState.logoutWhatsApp() }
                } label: {
                    Label("Log Out This Account", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .disabled(appState.isAdminLoading)

                if let error = appState.whatsAppState?.error, !error.isEmpty {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func groupSection(config: Binding<PatrolConfig>) -> some View {
        Section("Who Gets The Messages") {
            if appState.whatsAppState?.chats.isEmpty ?? true {
                Text("No chats loaded yet. Pull to refresh once WhatsApp is ready.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("WhatsApp group or chat", selection: config.groupName) {
                    ForEach(appState.whatsAppState?.chats ?? []) { chat in
                        Text(chat.name).tag(chat.name)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private func messageSection(config: Binding<PatrolConfig>) -> some View {
        Section("Message") {
            TextEditor(text: config.message)
                .frame(minHeight: 100)
        }
    }

    private func scheduleSection(config: Binding<PatrolConfig>) -> some View {
        Group {
            Section("Schedule") {
                Toggle("Automatic sending", isOn: config.schedule.enabled)
                weekdayToggleRow(config: config)
            }

            Section("Shift") {
                HStack {
                    Button("Day (8:00–20:00)") {
                        config.schedule.shiftStartHour.wrappedValue = 8
                        config.schedule.shiftEndHour.wrappedValue = 20
                    }
                    Spacer()
                    Button("Night (20:00–8:00)") {
                        config.schedule.shiftStartHour.wrappedValue = 20
                        config.schedule.shiftEndHour.wrappedValue = 8
                    }
                }
                .buttonStyle(.bordered)
                .font(.subheadline)
            }

            DisclosureGroup("Fine-Tune Timing") {
                Stepper(
                    "Shift starts \(config.schedule.shiftStartHour.wrappedValue):00",
                    value: config.schedule.shiftStartHour,
                    in: 0...23
                )
                Stepper(
                    "Shift ends \(config.schedule.shiftEndHour.wrappedValue):00",
                    value: config.schedule.shiftEndHour,
                    in: 0...23
                )
                Stepper(
                    "First message earliest: \(config.schedule.firstSendMinuteMin.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMin,
                    in: 0...59
                )
                Stepper(
                    "First message latest: \(config.schedule.firstSendMinuteMax.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMax,
                    in: 0...59
                )
                Stepper(
                    "Shortest gap: \(config.schedule.minSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.minSendIntervalMinutes,
                    in: 75...240,
                    step: 5
                )
                Stepper(
                    "Longest gap: \(config.schedule.maxSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.maxSendIntervalMinutes,
                    in: 75...240,
                    step: 5
                )
                oneTimeDatesEditor(config: config)
            }
        }
    }

    private var saveScheduleSection: some View {
        Section {
            Button {
                Task { await appState.saveConfig() }
            } label: {
                Label("Save Setup", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isConfigLoading)
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            ForEach(appState.logs.prefix(8)) { log in
                VStack(alignment: .leading, spacing: 2) {
                    Text(log.message)
                        .font(.subheadline)
                    Text(log.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshSchedulerScreen() async {
        await appState.refreshWhatsAppStatus()
        await appState.fetchConfig()
        await appState.fetchLogs()
    }

    private func weekdayToggleRow(config: Binding<PatrolConfig>) -> some View {
        HStack {
            ForEach(weekdayLabels, id: \.value) { day in
                let isOn = config.wrappedValue.schedule.activeShiftDays.contains(day.value)
                Button(day.short) {
                    if isOn {
                        config.schedule.activeShiftDays.wrappedValue.removeAll { $0 == day.value }
                    } else {
                        config.schedule.activeShiftDays.wrappedValue.append(day.value)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? .accentColor : .secondary)
                .font(.caption)
            }
        }
    }

    private func oneTimeDatesEditor(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(config.wrappedValue.schedule.extraShiftDates, id: \.self) { date in
                HStack {
                    Text(date)
                    Spacer()
                    Button(role: .destructive) {
                        config.schedule.extraShiftDates.wrappedValue.removeAll { $0 == date }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            Button {
                let today = isoDateString(Date())
                if !config.wrappedValue.schedule.extraShiftDates.contains(today) {
                    config.schedule.extraShiftDates.wrappedValue.append(today)
                    config.schedule.extraShiftDates.wrappedValue.sort()
                }
            } label: {
                Label("Add One-Time Date (Today)", systemImage: "plus")
            }
        }
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/Toronto")
        return formatter.string(from: date)
    }

    // MARK: - Patrol
    // Mirrors patrol.html: mark checkpoints on the map, start live patrol,
    // and an arrival at a checkpoint sends the configured message.

    private var patrolView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    patrolStatusPanel
                    checkpointMapPanel
                    checkpointListPanel
                    recentActivityPanel
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Patrol")
            .onAppear { appState.requestLocationAccess() }
            .onDisappear { appState.saveCheckpoints() }
            .task { await appState.retryQueuedEvents() }
        }
    }

    private var patrolStatusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.shiftIsActive ? "Patrol Active" : "Patrol Stopped")
                        .font(.title2.weight(.semibold))
                    Text(appState.shiftIsActive ? "Detecting checkpoint arrivals." : "Mark checkpoints below, then start.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: appState.shiftIsActive ? "location.fill" : "location.slash")
                    .font(.title)
                    .foregroundStyle(appState.shiftIsActive ? .green : .secondary)
            }

            LabeledContent("Location Access", value: authorizationLabel(appState.locationAuthorization))
            if let location = appState.currentLocation {
                LabeledContent("GPS Accuracy", value: "\(Int(location.horizontalAccuracy)) m")
            }
            if let nearest = appState.nearestCheckpoint {
                LabeledContent("Nearest", value: nearest.checkpoint.name)
                LabeledContent("Distance", value: "\(Int(nearest.distance)) m")
            }

            Button {
                appState.shiftIsActive ? appState.stopPatrol() : appState.startPatrol()
            } label: {
                Label(appState.shiftIsActive ? "Stop Patrol" : "Start Live Patrol", systemImage: appState.shiftIsActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(appState.shiftIsActive ? .red : .green)
            .disabled(appState.checkpoints.isEmpty)

            if appState.checkpoints.isEmpty {
                Label("Add at least one checkpoint below before starting.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .panel()
    }

    private var checkpointMapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Checkpoints", systemImage: "map")
                .font(.headline)
            Text("Tap the map to drop a checkpoint. When you enter its circle during a live patrol, the message from the Scheduler tab is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MapReader { proxy in
                Map(position: $mapPosition) {
                    UserAnnotation()
                    ForEach(appState.checkpoints) { checkpoint in
                        Marker(checkpoint.name, coordinate: CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude))
                            .tint(.green)
                        MapCircle(center: CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude), radius: checkpoint.radiusMeters)
                            .foregroundStyle(.green.opacity(0.18))
                            .stroke(.green, lineWidth: 2)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        appState.addCheckpoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                appState.addCheckpoint()
            } label: {
                Label("Drop At My Location", systemImage: "location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .panel()
    }

    private var checkpointListPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.checkpoints.isEmpty {
                Text("No checkpoints yet — tap the map above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array($appState.checkpoints.enumerated()), id: \.element.id) { index, $checkpoint in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Name", text: $checkpoint.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(role: .destructive) {
                                appState.deleteCheckpoint(checkpoint)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        Stepper("Radius \(Int(checkpoint.radiusMeters)) m", value: $checkpoint.radiusMeters, in: 10...1000, step: 10)
                    }
                    .padding(.vertical, 6)
                    if index < appState.checkpoints.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .panel()
    }

    private var recentActivityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recent Arrivals", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                Spacer()
                if appState.isRetrying {
                    ProgressView()
                } else {
                    Button {
                        Task { await appState.retryQueuedEvents() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }

            if appState.history.isEmpty {
                Text("No patrol events yet.")
                    .foregroundStyle(.secondary)
            } else {
                let recent = Array(appState.history.prefix(5))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                    EventRow(event: event)
                    if index < recent.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .panel()
    }

    // MARK: - Settings
    // Device-only knobs with no equivalent in the browser: geofence
    // tuning, and where this device sends admin/patrol requests.

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Guard") {
                    TextField("Guard name", text: $appState.guardName)
                        .textInputAutocapitalization(.never)
                }

                Section("Scheduler Admin") {
                    TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Text("The engine's admin API, used for login, QR, and schedule editing.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Patrol Send API") {
                    TextField("n8n webhook URL", text: $appState.webhookURL, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Text("Checkpoint arrivals go to n8n. They do not call the scheduler directly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Location And Dedupe") {
                    Stepper("Cooldown \(Int(appState.checkpointCooldownMinutes)) min", value: $appState.checkpointCooldownMinutes, in: 10...15, step: 1)
                    Stepper("Max accuracy \(Int(appState.accuracyThresholdMeters)) m", value: $appState.accuracyThresholdMeters, in: 10...100, step: 5)
                    Text("Automatic sends only happen on outside-to-inside checkpoint transitions.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When in use"
        @unknown default: return "Unknown"
        }
    }
}

private struct EventRow: View {
    let event: PatrolEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.checkpointName)
                    .font(.subheadline.weight(.semibold))
                Text(event.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(event.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch event.status {
        case .schedulerSucceeded: return "checkmark.circle.fill"
        case .engineNotReady: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .queued: return "tray.full.fill"
        case .sending: return "paperplane.fill"
        case .backendReceived: return "checkmark.seal.fill"
        }
    }

    private var color: Color {
        switch event.status {
        case .schedulerSucceeded: return .green
        case .engineNotReady: return .orange
        case .failed: return .red
        case .queued: return .blue
        case .sending: return .purple
        case .backendReceived: return .teal
        }
    }
}

private struct WhatsAppConnectionRow: View {
    let state: WhatsAppAdminState?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard let state else { return "Not connected to admin API" }
        switch state.status {
        case "starting": return "WhatsApp starting"
        case "qr": return "Scan QR to log in"
        case "authenticated": return "Authenticated"
        case "ready": return "WhatsApp ready"
        case "disconnected": return "Disconnected"
        case "error": return "Error"
        case "logging_out": return "Logging out"
        default: return state.status
        }
    }

    private var detail: String {
        guard let state else { return "Enter password and connect the account." }
        if let account = state.account {
            return "\(account.name) - \(state.status)"
        }
        return state.status
    }

    private var color: Color {
        switch state?.status {
        case "ready": return .green
        case "qr", "authenticated", "starting", "logging_out": return .orange
        case nil: return .secondary
        default: return .red
        }
    }
}

private extension UIImage {
    convenience init?(dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}

private extension View {
    func panel() -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    ContentView()
}
