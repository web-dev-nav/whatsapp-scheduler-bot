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

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var adminPassword = ""
    @State private var selectedCheckpointId: String?
    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.1394, longitude: -80.2644),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )

    var body: some View {
        TabView {
            patrolView
                .tabItem { Label("Patrol", systemImage: "shield.lefthalf.filled") }
            checkpointsView
                .tabItem { Label("Checkpoints", systemImage: "map") }
            historyView
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            connectWhatsAppView
                .tabItem { Label("Connect", systemImage: "qrcode.viewfinder") }
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

    private var selectedCheckpoint: Checkpoint? {
        if let selectedCheckpointId,
           let selected = appState.checkpoints.first(where: { $0.id == selectedCheckpointId }) {
            return selected
        }
        return appState.checkpoints.first
    }

    private var patrolView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.shiftIsActive ? "Patrol Active" : "Patrol Stopped")
                                    .font(.title2.weight(.semibold))
                                Text(appState.shiftIsActive ? "Detecting checkpoint arrivals." : "Start patrol to enable location detection.")
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
                            Label(appState.shiftIsActive ? "Stop Patrol" : "Start Patrol", systemImage: appState.shiftIsActive ? "stop.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .tint(appState.shiftIsActive ? .red : .green)
                    }
                    .panel()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Manual Trigger", systemImage: "paperplane.fill")
                            .font(.headline)

                        if appState.checkpoints.isEmpty {
                            ContentUnavailableView("No Checkpoints", systemImage: "mappin.slash", description: Text("Add checkpoints before sending."))
                        } else {
                            Picker("Checkpoint", selection: checkpointSelection) {
                                ForEach(appState.checkpoints) { checkpoint in
                                    Text(checkpoint.name).tag(Optional(checkpoint.id))
                                }
                            }
                            .pickerStyle(.menu)

                            Button {
                                guard let selectedCheckpoint else { return }
                                Task { await appState.manualTrigger(selectedCheckpoint) }
                            } label: {
                                Label("Send Arrival", systemImage: "location.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .panel()

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Last Event", systemImage: "list.bullet.rectangle")
                            .font(.headline)
                        if let event = appState.history.first {
                            EventRow(event: event)
                        } else {
                            Text("No patrol events yet.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .panel()
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Patrol")
            .task {
                await appState.retryQueuedEvents()
            }
        }
    }

    private var checkpointsView: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MapReader { proxy in
                    Map(position: $mapPosition) {
                        UserAnnotation()
                        ForEach(appState.checkpoints) { checkpoint in
                            Marker(checkpoint.name, coordinate: CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude))
                                .tint(checkpoint.isActive ? .green : .gray)
                            MapCircle(center: CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude), radius: checkpoint.radiusMeters)
                                .foregroundStyle(.green.opacity(0.18))
                                .stroke(.green, lineWidth: 2)
                        }
                    }
                    .mapControls {
                        MapUserLocationButton()
                        MapCompass()
                        MapScaleView()
                    }
                    .onTapGesture { point in
                        if let coordinate = proxy.convert(point, from: .local) {
                            appState.addCheckpoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        }
                    }
                }
                .frame(minHeight: 330)

                List {
                    Section("Checkpoints") {
                        ForEach($appState.checkpoints) { $checkpoint in
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Active", isOn: $checkpoint.isActive)
                                TextField("Name", text: $checkpoint.name)
                                TextField("Checkpoint ID", text: $checkpoint.id)
                                    .textInputAutocapitalization(.never)
                                HStack {
                                    TextField("Latitude", value: $checkpoint.latitude, format: .number)
                                        .keyboardType(.decimalPad)
                                    TextField("Longitude", value: $checkpoint.longitude, format: .number)
                                        .keyboardType(.decimalPad)
                                }
                                Stepper("Radius \(Int(checkpoint.radiusMeters)) m", value: $checkpoint.radiusMeters, in: 10...1000, step: 10)
                                TextField("Notes", text: $checkpoint.notes, axis: .vertical)
                            }
                            .padding(.vertical, 6)
                        }
                        .onDelete { offsets in
                            for index in offsets {
                                appState.deleteCheckpoint(appState.checkpoints[index])
                            }
                        }

                        if appState.checkpoints.isEmpty {
                            Text("Tap the map to create a checkpoint.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.addCheckpoint()
                    } label: {
                        Label("Use Location", systemImage: "location")
                    }
                }
            }
            .onAppear {
                appState.requestLocationAccess()
                if let location = appState.currentLocation {
                    mapPosition = .region(
                        MKCoordinateRegion(
                            center: location.coordinate,
                            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        )
                    )
                }
            }
            .onDisappear { appState.saveCheckpoints() }
            .navigationTitle("Checkpoints")
        }
    }

    private var historyView: some View {
        NavigationStack {
            List {
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
                    .padding(.vertical, 6)
                }
            }
            .overlay {
                if appState.history.isEmpty {
                    ContentUnavailableView("No History", systemImage: "clock", description: Text("Queued, sent, and failed events appear here."))
                }
            }
            .toolbar {
                Button {
                    Task { await appState.retryQueuedEvents() }
                } label: {
                    Label("Retry Queue", systemImage: "arrow.clockwise")
                }
            }
            .navigationTitle("History")
        }
    }

    private var connectWhatsAppView: some View {
        NavigationStack {
            Form {
                Section("Scheduler Admin") {
                    TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    Picker("Account", selection: $appState.selectedAdminAccountId) {
                        if appState.adminAccounts.isEmpty {
                            Text("main").tag("main")
                        }
                        ForEach(appState.adminAccounts) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    SecureField("Account password", text: $adminPassword)
                    Button {
                        Task { await appState.loginAdmin(password: adminPassword) }
                    } label: {
                        Label("Connect Account", systemImage: "lock.open")
                    }
                    .disabled(adminPassword.count < 4 || appState.isAdminLoading)
                }

                Section("WhatsApp Engine") {
                    WhatsAppConnectionRow(state: appState.whatsAppState)

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

                    Button {
                        Task { await appState.refreshWhatsAppStatus() }
                    } label: {
                        Label("Refresh Status", systemImage: "arrow.clockwise")
                    }
                    .disabled(appState.isAdminLoading || appState.adminToken.isEmpty)

                    Button(role: .destructive) {
                        Task { await appState.logoutWhatsApp() }
                    } label: {
                        Label("Logout Session", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(appState.isAdminLoading || appState.adminToken.isEmpty)

                    if let state = appState.whatsAppState {
                        LabeledContent("Chats loaded", value: "\(state.chats.count)")
                        if let error = state.error, !error.isEmpty {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .task {
                await appState.fetchAdminAccounts()
                if !appState.adminToken.isEmpty {
                    await appState.refreshWhatsAppStatus()
                }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, !appState.adminToken.isEmpty else { continue }
                    await appState.refreshWhatsAppStatus()
                    if appState.whatsAppState?.status == "ready" {
                        break
                    }
                }
            }
            .navigationTitle("Connect WhatsApp")
        }
    }

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Guard") {
                    TextField("Guard name", text: $appState.guardName)
                        .textInputAutocapitalization(.never)
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

                Section("Appointments") {
                    ForEach($appState.appointments) { $appointment in
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Use this shift", isOn: $appointment.isActive)
                            TextField("Shift title", text: $appointment.title)
                            DatePicker("Starts", selection: $appointment.startsAt)
                            DatePicker("Ends", selection: $appointment.endsAt)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            appState.deleteAppointment(appState.appointments[index])
                        }
                    }
                    Button {
                        appState.addAppointment()
                    } label: {
                        Label("Add Shift Appointment", systemImage: "plus")
                    }
                }
            }
            .onDisappear { appState.saveAppointments() }
            .navigationTitle("Settings")
        }
    }

    private var checkpointSelection: Binding<String?> {
        Binding(
            get: { selectedCheckpoint?.id },
            set: { selectedCheckpointId = $0 }
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
