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

// Five focused screens instead of one crowded form: Connect (WhatsApp
// sessions), Setup (a step-by-step wizard for the message/schedule,
// matching the browser's 5-step flow), Patrol (GPS checkpoints + live
// patrol), Activity (scheduler log + patrol events), Settings
// (device-only knobs with no browser equivalent).
struct ContentView: View {
    @StateObject private var appState = AppState()

    var body: some View {
        TabView {
            connectView
                .tabItem { Label("Connect", systemImage: "qrcode.viewfinder") }
            setupView
                .tabItem { Label("Setup", systemImage: "list.number") }
            patrolView
                .tabItem { Label("Patrol", systemImage: "shield.lefthalf.filled") }
            activityView
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
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
}

// MARK: - Connect (WhatsApp session management)

private struct ConnectTab: View {
    @ObservedObject var appState: AppState
    @State private var adminPassword = ""
    @State private var showAddAccount = false
    @State private var showDeleteConfirm = false
    @State private var showFullscreenQR = false

    var body: some View {
        NavigationStack {
            List {
                accountsSection
                selectedSessionSection
            }
            .navigationTitle("Connect")
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)
            .confirmationDialog(
                "Remove this account?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    Task { await appState.deleteSelectedAccount() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This deletes the saved WhatsApp session and schedule for this account. This can't be undone.")
            }
            .sheet(isPresented: $showAddAccount) {
                AddAccountSheet { name, password in
                    await appState.createAccount(name: name, password: password)
                }
            }
            .task {
                await appState.fetchAdminAccounts()
                if !appState.adminToken.isEmpty {
                    await appState.refreshWhatsAppStatus()
                }
            }
            .task(id: pollKey) {
                // Auto-poll status (and any QR code the server generates)
                // until WhatsApp is ready, so scanning the QR "just works"
                // without the user having to keep tapping Refresh.
                guard !appState.adminToken.isEmpty else { return }
                while !Task.isCancelled {
                    await appState.refreshWhatsAppStatus()
                    if appState.whatsAppState?.status == "ready" { break }
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
    }

    /// Restarts the polling task above whenever the selected account
    /// changes, or right after a login completes (token goes from empty to
    /// set) -- both cases need a fresh poll loop.
    private var pollKey: String {
        "\(appState.selectedAdminAccountId)|\(appState.adminToken.isEmpty)"
    }

    private var accountsSection: some View {
        Section("WhatsApp Sessions") {
            ForEach(appState.adminAccounts) { account in
                accountRow(account)
            }

            Button {
                showAddAccount = true
            } label: {
                Label("Add Session", systemImage: "plus.circle")
            }
        }
    }

    private func accountRow(_ account: SchedulerAccount) -> some View {
        Button {
            guard account.id != appState.selectedAdminAccountId else { return }
            Task { await appState.selectAccount(account.id) }
        } label: {
            HStack {
                Text(account.name)
                    .foregroundStyle(.primary)
                Spacer()
                if account.id == appState.selectedAdminAccountId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var selectedSessionSection: some View {
        Section("Selected Session") {
            WhatsAppConnectionRow(state: appState.whatsAppState)

            if appState.adminToken.isEmpty {
                loginFields
            } else {
                connectedControls
            }
        }
    }

    private var loginFields: some View {
        Group {
            SecureField("Account password", text: $adminPassword)
            Button {
                Task { await appState.loginAdmin(password: adminPassword) }
            } label: {
                Label("Connect", systemImage: "lock.open")
            }
            .disabled(adminPassword.count < 4 || appState.isAdminLoading)
        }
    }

    private var connectedControls: some View {
        Group {
            qrCodeView

            Button {
                Task { await appState.refreshWhatsAppStatus() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                Task { await appState.logoutWhatsApp() }
            } label: {
                Label("Log Out This Session", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Remove This Account", systemImage: "trash")
            }
            .disabled(appState.isAdminLoading || appState.selectedAdminAccountId == "main")

            if appState.selectedAdminAccountId == "main" {
                Text("The \"main\" account can't be removed -- it's the engine's default account and other server behavior falls back to it. Log it out instead if you want to unlink WhatsApp from it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let error = appState.whatsAppState?.error, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var qrCodeView: some View {
        if let qrDataUrl = appState.whatsAppState?.qrDataUrl,
           let image = UIImage(dataURL: qrDataUrl) {
            VStack(spacing: 12) {
                Button {
                    showFullscreenQR = true
                } label: {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                Text("You need a **different** phone to scan this -- the one that will actually host this WhatsApp account. You can't scan a code shown on the same screen you're reading it on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Button {
                        showFullscreenQR = true
                    } label: {
                        Label("View Full Screen", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(.bordered)

                    ShareLink(item: Image(uiImage: image), preview: SharePreview("WhatsApp Login QR")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.footnote)
            }
            .sheet(isPresented: $showFullscreenQR) {
                FullscreenQRView(image: image)
            }
        }
    }
}

private struct FullscreenQRView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding()
                Text("Open WhatsApp on a different phone > Settings > Linked Devices > Link a Device, then scan this code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                Spacer()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var password = ""
    @State private var isSubmitting = false
    let onAdd: (String, String) async -> Void

    var body: some View {
        NavigationStack {
            Form {
                TextField("Account name", text: $name)
                    .textInputAutocapitalization(.words)
                SecureField("Password (min 4 characters)", text: $password)

                if isSubmitting {
                    HStack {
                        Spacer()
                        ProgressView("Creating session…")
                        Spacer()
                    }
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Add Session")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSubmitting = true
                        Task {
                            await onAdd(name.trimmingCharacters(in: .whitespaces), password)
                            isSubmitting = false
                            dismiss()
                        }
                    }
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 4)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }
}

// MARK: - Setup (step-by-step wizard: chat -> days -> shift -> message -> review)

private enum SetupStep: Int, CaseIterable {
    case chat, days, shift, message, review

    var title: String {
        switch self {
        case .chat: return "Who gets the messages?"
        case .days: return "Which days?"
        case .shift: return "Day or night shift?"
        case .message: return "What should it say?"
        case .review: return "Review & turn on"
        }
    }
}

private struct SetupTab: View {
    @ObservedObject var appState: AppState
    @State private var step: SetupStep = .chat
    @State private var isEditing = false
    @State private var showSavedConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if let config = Binding($appState.patrolConfig) {
                    if isEditing {
                        wizard(config: config)
                    } else {
                        overview(config: config)
                    }
                } else if appState.isConfigLoading {
                    ProgressView("Loading setup…")
                } else {
                    ContentUnavailableView(
                        "Not Connected",
                        systemImage: "wifi.slash",
                        description: Text("Connect a WhatsApp session on the Connect tab first.")
                    )
                }
            }
            .navigationTitle("Setup")
            .task {
                if appState.patrolConfig == nil, !appState.adminToken.isEmpty {
                    await appState.fetchConfig()
                }
            }
            .alert("Saved", isPresented: $showSavedConfirmation) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your message and schedule have been saved.")
            }
        }
    }

    /// Read-only summary of the current setup with a single "Edit Setup"
    /// button, so returning users land on an overview instead of always
    /// being dropped back into step 1 of the wizard.
    private func overview(config: Binding<PatrolConfig>) -> some View {
        Form {
            Section("Current Setup") {
                LabeledContent("Chat", value: config.wrappedValue.groupName.isEmpty ? "Not set" : config.wrappedValue.groupName)
                LabeledContent("Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
                LabeledContent("Message", value: config.wrappedValue.message.isEmpty ? "Not set" : config.wrappedValue.message)
                    .lineLimit(3)
            }

            Section {
                Toggle("Automatic sending", isOn: config.schedule.enabled)
                    .onChange(of: config.wrappedValue.schedule.enabled) { _, _ in
                        Task { await appState.saveConfig() }
                    }
            }

            Section {
                Button {
                    step = .chat
                    isEditing = true
                } label: {
                    Label("Edit Setup", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func wizard(config: Binding<PatrolConfig>) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(SetupStep.allCases.count))
                Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(step.title)
                        .font(.title2.weight(.semibold))
                    stepContent(config: config)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            Divider()

            HStack {
                Button("Back") {
                    step = SetupStep(rawValue: step.rawValue - 1) ?? .chat
                }
                .disabled(step == .chat)

                Spacer()

                if step == .review {
                    Button {
                        Task {
                            let saved = await appState.saveConfig()
                            if saved {
                                showSavedConfirmation = true
                                isEditing = false
                            }
                        }
                    } label: {
                        if appState.isConfigLoading {
                            ProgressView()
                        } else {
                            Label("Save & Done", systemImage: "checkmark.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isConfigLoading)
                } else {
                    Button("Next") {
                        step = SetupStep(rawValue: step.rawValue + 1) ?? .review
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isEditing = false }
            }
        }
    }

    @ViewBuilder
    private func stepContent(config: Binding<PatrolConfig>) -> some View {
        switch step {
        case .chat:
            chatStep(config: config)
        case .days:
            daysStep(config: config)
        case .shift:
            shiftStep(config: config)
        case .message:
            messageStep(config: config)
        case .review:
            reviewStep(config: config)
        }
    }

    private func chatStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the WhatsApp group or chat the patrol updates should go to.")
                .foregroundStyle(.secondary)

            if appState.whatsAppState?.chats.isEmpty ?? true {
                Text("No chats loaded yet. Connect WhatsApp on the Connect tab first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("WhatsApp group or chat", selection: config.groupName) {
                    ForEach(appState.whatsAppState?.chats ?? []) { chat in
                        Text(chat.name).tag(chat.name)
                    }
                }
                .pickerStyle(.wheel)
            }
        }
    }

    private func daysStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the days a shift starts. This repeats every week.")
                .foregroundStyle(.secondary)
            weekdayToggleRow(config: config)

            Divider()

            Text("One-time dates")
                .font(.headline)
            Text("Add a single extra shift that isn't part of your weekly routine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            oneTimeDatesEditor(config: config)
        }
    }

    private func shiftStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We'll spread the messages naturally across these hours.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                shiftCard(
                    emoji: "☀️", title: "Day", time: "8:00 AM – 8:00 PM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 8 && config.wrappedValue.schedule.shiftEndHour == 20
                ) {
                    config.schedule.shiftStartHour.wrappedValue = 8
                    config.schedule.shiftEndHour.wrappedValue = 20
                }
                shiftCard(
                    emoji: "🌙", title: "Night", time: "8:00 PM – 8:00 AM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 20 && config.wrappedValue.schedule.shiftEndHour == 8
                ) {
                    config.schedule.shiftStartHour.wrappedValue = 20
                    config.schedule.shiftEndHour.wrappedValue = 8
                }
            }
        }
    }

    private func shiftCard(emoji: String, title: String, time: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(emoji).font(.system(size: 36))
                Text(title).font(.headline)
                Text(time).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func messageStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This exact message is sent each time. Keep it natural.")
                .foregroundStyle(.secondary)
            TextEditor(text: config.message)
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
    }

    private func reviewStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Chat", value: config.wrappedValue.groupName)
                LabeledContent("Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
                LabeledContent("Message", value: config.wrappedValue.message)
                    .lineLimit(3)
            }
            .panel()

            Toggle("Send automatically", isOn: config.schedule.enabled)

            DisclosureGroup("Fine-Tune Timing (Optional)") {
                Stepper(
                    "First message earliest: \(config.schedule.firstSendMinuteMin.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMin, in: 0...59
                )
                Stepper(
                    "First message latest: \(config.schedule.firstSendMinuteMax.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMax, in: 0...59
                )
                Stepper(
                    "Shortest gap: \(config.schedule.minSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.minSendIntervalMinutes, in: 75...240, step: 5
                )
                Stepper(
                    "Longest gap: \(config.schedule.maxSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.maxSendIntervalMinutes, in: 75...240, step: 5
                )
            }
        }
    }

    private func dayList(_ days: [Int]) -> String {
        guard !days.isEmpty else { return "None" }
        let names = weekdayLabels.filter { days.contains($0.value) }.map(\.short)
        return names.joined(separator: ", ")
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
}

// MARK: - Patrol (checkpoints + live GPS detection)

/// Tracks the fixed reference point a radius drag started from, so each
/// `.onChanged` can compute an absolute new position (start + cumulative
/// translation) instead of drifting from incremental deltas.
private struct RadiusDragState {
    let checkpointId: String
    let handleStartScreenPoint: CGPoint
}

private struct PatrolTab: View {
    @ObservedObject var appState: AppState
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.1394, longitude: -80.2644),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )
    @State private var hasCenteredOnUser = false
    @State private var lastAddedCheckpointId: String?
    @State private var radiusDrag: RadiusDragState?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusPanel
                    mapPanel
                    listPanel
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Patrol")
            .onAppear { appState.requestLocationAccess() }
            .onDisappear {
                appState.saveCheckpoints()
                appState.stopWatchingLocationIfIdle()
            }
            .onChange(of: appState.currentLocation?.coordinate.latitude) { _, _ in
                // Recenter once, the first time we get a real GPS fix --
                // otherwise the map stays parked on the hardcoded default
                // (Waterloo, ON) and "my location" never actually shows up.
                // CLLocation isn't Equatable, so this keys off latitude
                // (a Double) as a stand-in for "location changed."
                guard !hasCenteredOnUser, let location = appState.currentLocation else { return }
                hasCenteredOnUser = true
                mapPosition = .region(
                    MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
    }

    private var statusPanel: some View {
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

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Checkpoints", systemImage: "map")
                .font(.headline)
            Text("Tap the map to drop a checkpoint. Drag the white handle on a checkpoint's circle to resize it. When you enter a circle during a live patrol, the message from Setup is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MapReader { proxy in
                Map(position: $mapPosition) {
                    UserAnnotation()
                    ForEach(appState.checkpoints) { checkpoint in
                        let center = CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                        Marker(checkpoint.name, coordinate: center)
                            .tint(.green)
                        MapCircle(center: center, radius: checkpoint.radiusMeters)
                            .foregroundStyle(.green.opacity(0.18))
                            .stroke(.green, lineWidth: 2)
                        Annotation("", coordinate: radiusHandleCoordinate(for: checkpoint)) {
                            radiusHandle(for: checkpoint, proxy: proxy)
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        lastAddedCheckpointId = appState.addCheckpoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                lastAddedCheckpointId = appState.addCheckpoint()
            } label: {
                Label("Drop At My Location", systemImage: "location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.currentLocation == nil)

            if appState.currentLocation == nil {
                Label(waitingForLocationMessage, systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(waitingForLocationMessage.contains("Settings") ? .orange : .secondary)
            }

            radiusQuickEditor
        }
        .panel()
    }

    /// A radius control right next to the map for whichever checkpoint was
    /// just placed, so adjusting it doesn't require scrolling down to the
    /// list -- and its live-updating MapCircle above makes the radius
    /// change visible immediately.
    @ViewBuilder
    private var radiusQuickEditor: some View {
        if let index = appState.checkpoints.firstIndex(where: { $0.id == lastAddedCheckpointId }) {
            let checkpoint = appState.checkpoints[index]
            VStack(alignment: .leading, spacing: 6) {
                Text("Radius for \"\(checkpoint.name)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(
                        value: Binding(
                            get: { appState.checkpoints[index].radiusMeters },
                            set: { appState.checkpoints[index].radiusMeters = $0 }
                        ),
                        in: 10...1000,
                        step: 10
                    )
                    Text("\(Int(checkpoint.radiusMeters)) m")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    private var listPanel: some View {
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
                        Button {
                            Task { await appState.manualTrigger(checkpoint) }
                        } label: {
                            Label("Send Test Arrival", systemImage: "paperplane")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
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

    /// A point due east of the checkpoint at distance `radiusMeters` --
    /// where the draggable resize handle sits on the circle's edge. Flat
    /// approximation (fine at the radii this app supports, max 1000m).
    private func radiusHandleCoordinate(for checkpoint: Checkpoint) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(checkpoint.latitude * .pi / 180), 1)
        let deltaLongitude = checkpoint.radiusMeters / metersPerDegreeLongitude
        return CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude + deltaLongitude)
    }

    /// Draggable handle on a checkpoint's circle edge. Dragging moves the
    /// handle; the new radius is the distance from the checkpoint's center
    /// to wherever the handle's screen position lands, converted back to a
    /// coordinate via the map's own projection (MapProxy) rather than a
    /// manual points-per-meter estimate, so it stays correct at any zoom
    /// level.
    private func radiusHandle(for checkpoint: Checkpoint, proxy: MapProxy) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.green, lineWidth: 2))
            .frame(width: 22, height: 22)
            .shadow(radius: 2)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if radiusDrag?.checkpointId != checkpoint.id {
                            guard let startPoint = proxy.convert(radiusHandleCoordinate(for: checkpoint), to: .local) else { return }
                            radiusDrag = RadiusDragState(checkpointId: checkpoint.id, handleStartScreenPoint: startPoint)
                        }
                        guard let drag = radiusDrag, drag.checkpointId == checkpoint.id else { return }

                        let newPoint = CGPoint(
                            x: drag.handleStartScreenPoint.x + value.translation.width,
                            y: drag.handleStartScreenPoint.y + value.translation.height
                        )
                        guard let newCoordinate = proxy.convert(newPoint, from: .local) else { return }

                        let center = CLLocation(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                        let newRadius = center.distance(from: CLLocation(latitude: newCoordinate.latitude, longitude: newCoordinate.longitude))
                        guard let index = appState.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) else { return }
                        appState.checkpoints[index].radiusMeters = min(max(newRadius, 10), 1000)
                    }
                    .onEnded { _ in
                        radiusDrag = nil
                        appState.saveCheckpoints()
                    }
            )
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

    private var waitingForLocationMessage: String {
        switch appState.locationAuthorization {
        case .denied, .restricted:
            return "Location access is off for WatchPoint. Turn it on in Settings > Privacy > Location Services > WatchPoint to place checkpoints."
        case .notDetermined:
            return "Tap \"Drop At My Location\" or reopen this tab to allow location access -- iOS should prompt you."
        default:
            return "Finding your location… this can take a few seconds outdoors, longer indoors."
        }
    }
}

// MARK: - Activity (scheduler log + patrol events, own page)

private struct ActivityTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Scheduler Log") {
                    if appState.logs.isEmpty {
                        Text("No scheduler activity yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.logs) { log in
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

                Section {
                    HStack {
                        Text("Patrol Events")
                            .font(.headline)
                        Spacer()
                        if appState.isRetrying {
                            ProgressView()
                        } else {
                            Button {
                                Task { await appState.retryQueuedEvents() }
                            } label: {
                                Label("Retry Queue", systemImage: "arrow.clockwise")
                            }
                            .font(.caption)
                        }
                    }

                    if appState.history.isEmpty {
                        Text("No patrol events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.history) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                EventRow(event: event)
                                HStack {
                                    Label(event.webhookReceived ? "Webhook received" : "Webhook pending", systemImage: event.webhookReceived ? "checkmark.circle" : "clock")
                                    Spacer()
                                    if let responseCode = event.responseCode {
                                        Text("HTTP \(responseCode)")
                                    }
                                    if let schedulerStatusCode = event.schedulerStatusCode {
                                        Text("Scheduler \(schedulerStatusCode)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let summary = event.responseSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let reason = event.schedulerReason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .refreshable { await appState.fetchLogs() }
            .task { await appState.fetchLogs() }
        }
    }
}

// MARK: - Settings (device-only, no browser equivalent)

private struct SettingsTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
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
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Settings")
        }
    }
}

// MARK: - Shared subviews

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

    /// Adds a "Done" button above the keyboard so text fields/editors can
    /// always be dismissed -- SwiftUI Forms don't do this automatically.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}

private extension ContentView {
    var connectView: some View { ConnectTab(appState: appState) }
    var setupView: some View { SetupTab(appState: appState) }
    var patrolView: some View { PatrolTab(appState: appState) }
    var activityView: some View { ActivityTab(appState: appState) }
    var settingsView: some View { SettingsTab(appState: appState) }
}

#Preview {
    ContentView()
}
