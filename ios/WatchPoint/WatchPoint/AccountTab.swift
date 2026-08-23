//
//  AccountTab.swift
//  WatchPoint
//
//  Hub for rare config: WhatsApp session, message spacing, GPS accuracy,
//  automatic/patrol messages, and device privacy.
//

import SwiftUI

struct AccountTab: View {
    @ObservedObject var appState: AppState
    @State private var showWhatsAppSession = false
    @State private var minMessageInterval = 0
    @State private var hasLoadedInterval = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        WhatsAppConnectionRow(state: appState.whatsAppState)
                        TextField("Guard name", text: $appState.guardName)
                            .textInputAutocapitalization(.words)
                            .onSubmit { Task { _ = await appState.savePatrolState() } }
                    }

                    Button {
                        showWhatsAppSession = true
                    } label: {
                        Label("Configure WhatsApp", systemImage: "qrcode")
                    }

                    Button(role: .destructive) {
                        Task { await appState.signOut() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.left")
                    }
                } header: {
                    Text("This Guard")
                } footer: {
                    Text("Each guard account has its own WhatsApp session and patrol history. Sign Out returns to the login screen.")
                }

                Section {
                    Toggle(
                        "Require Face ID or Passcode",
                        isOn: Binding(
                            get: { appState.appLockEnabled },
                            set: { appState.setAppLockEnabled($0) }
                        )
                    )
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Locks WatchPoint at launch and whenever the app returns from the background.")
                }

                Section {
                    Stepper(
                        "GPS must be within \(Int(appState.accuracyThresholdMeters)) m",
                        value: $appState.accuracyThresholdMeters,
                        in: 10...100,
                        step: 5
                    )
                } header: {
                    Text("Location Accuracy")
                } footer: {
                    Text("Max accuracy is the largest GPS error WatchPoint will accept before sending. A tighter value (smaller meters) ignores fuzzy indoor fixes so a checkpoint is not marked from too far away.")
                }

                Section {
                    Stepper(intervalLabel, value: $minMessageInterval, in: 0...240)
                    Stepper(
                        "Same-checkpoint cooldown \(Int(appState.checkpointCooldownMinutes)) min",
                        value: $appState.checkpointCooldownMinutes,
                        in: 10...15,
                        step: 1
                    )
                } header: {
                    Text("Message Spacing")
                } footer: {
                    Text("Minimum interval is the wait after any WhatsApp send (patrol or scheduled) before another send is allowed. That gap is what keeps WhatsApp from treating the account like a bulk-messaging service.\n\nSame-checkpoint cooldown is separate: after a guard is messaged at one checkpoint, that same spot will not send again until this many minutes have passed, even if they walk out and back in.")
                }

                Section("Messages") {
                    NavigationLink("Shared Destination Chat") {
                        DeliverySettingsView(appState: appState)
                    }
                    NavigationLink("Automatic Message & Schedule") {
                        SetupView(appState: appState)
                    }
                    NavigationLink("Patrol Arrival Message") {
                        PatrolMessageView(appState: appState)
                    }
                }

                Section {
                    TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    NavigationLink("Test Server Connection") {
                        HostStatusView(appState: appState)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("Test Server Connection pings this URL and shows round-trip time, versions, and whether the engine is reachable.")
                }
            }
            .navigationTitle("Account")
            .navigationDestination(isPresented: $showWhatsAppSession) {
                WhatsAppSessionView(appState: appState)
            }
            .keyboardDoneButton()
            .scrollDismissesKeyboard(.interactively)
            .onDisappear {
                Task { await persistAccountSettings() }
            }
            .onChange(of: appState.requiresAdminLogin) { _, requiresLogin in
                if requiresLogin { showWhatsAppSession = false }
            }
            .task {
                if !appState.adminToken.isEmpty {
                    await appState.fetchConfig()
                    loadIntervalIfNeeded()
                }
            }
            .onChange(of: appState.patrolConfig) { _, _ in
                hasLoadedInterval = false
                loadIntervalIfNeeded()
            }
        }
    }

    private var intervalLabel: String {
        minMessageInterval == 0
            ? "Minimum interval: no extra wait"
            : "Minimum interval: \(minMessageInterval) min between any two sends"
    }

    private func loadIntervalIfNeeded() {
        guard !hasLoadedInterval, let config = appState.patrolConfig else { return }
        minMessageInterval = config.delivery?.minMessageIntervalMinutes ?? 0
        hasLoadedInterval = true
    }

    private func persistAccountSettings() async {
        _ = await appState.savePatrolState()
        guard hasLoadedInterval, var config = appState.patrolConfig else { return }
        config.delivery = DeliveryConfig(minMessageIntervalMinutes: minMessageInterval)
        appState.patrolConfig = config
        _ = await appState.saveConfig()
    }
}

struct WhatsAppSessionView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirm = false
    @State private var showLogoutConfirm = false

    var body: some View {
        List {
            currentSessionSection
            WhatsAppPairingCard(appState: appState)
            if let url = appState.pairingPageURL, appState.whatsAppState?.status != "ready" {
                Section {
                    ShareLink(item: url) {
                        Label("Share Pairing Link", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        appState.skipAppLockOnce = true
                        openURL(url)
                    } label: {
                        Label("Open QR in Browser", systemImage: "safari")
                    }
                }
            }
            if !appState.adminToken.isEmpty {
                sessionActionsSection
                accountRemovalSection
            }
        }
        .navigationTitle("WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(appState.selectedAccountName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Account and Data", role: .destructive) {
                Task { await appState.deleteSelectedAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this guard's WhatsApp session, schedule, checkpoints, and patrol history from the server. This can't be undone.")
        }
        .confirmationDialog(
            "Log out of WhatsApp?",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log Out WhatsApp", role: .destructive) {
                Task { await appState.logoutWhatsApp() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This unlinks WhatsApp from \(appState.selectedAccountName). The guard account and its patrol data remain on the server.")
        }
        .task(id: pollKey) {
            guard !appState.adminToken.isEmpty else { return }
            while !Task.isCancelled {
                await appState.refreshWhatsAppStatus()
                if appState.whatsAppState?.status == "ready" { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private var pollKey: String {
        "\(appState.selectedAdminAccountId)|\(appState.adminToken.isEmpty)"
    }

    private var currentSessionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(systemName: sessionIcon)
                        .font(.title2)
                        .foregroundStyle(sessionColor)
                        .frame(width: 42, height: 42)
                        .background(sessionColor.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(appState.selectedAccountName)
                            .font(.headline)
                        Text(sessionStatusTitle)
                            .font(.subheadline)
                            .foregroundStyle(sessionColor)
                    }
                    Spacer()
                    if appState.isAdminLoading {
                        ProgressView()
                    }
                }

                if let error = appState.whatsAppState?.error, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 6)
        } header: {
            Text("Current Session")
        }
    }

    private var sessionStatusTitle: String {
        switch appState.whatsAppState?.status {
        case "ready": return "Connected and ready"
        case "qr": return "Waiting for QR pairing"
        case "authenticated": return "WhatsApp authenticated"
        case "starting": return "Starting WhatsApp"
        case "logging_out": return "Logging out"
        case "disconnected": return "WhatsApp disconnected"
        case "error": return "Connection error"
        case .some(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Checking connection"
        }
    }

    private var sessionIcon: String {
        switch appState.whatsAppState?.status {
        case "ready": return "checkmark.circle.fill"
        case "qr": return "qrcode"
        case "error", "disconnected": return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var sessionColor: Color {
        switch appState.whatsAppState?.status {
        case "ready": return .green
        case "error", "disconnected": return .red
        default: return .orange
        }
    }

    private var sessionActionsSection: some View {
        Section {
            Button {
                Task { await appState.refreshWhatsAppStatus() }
            } label: {
                Label("Refresh Status", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Label("Unlink WhatsApp", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.left")
            }
            .disabled(appState.isAdminLoading)
        } header: {
            Text("Session")
        } footer: {
            Text("Unlink WhatsApp disconnects only this WhatsApp session; your guard account remains. Sign Out returns to the login screen.")
        }
    }

    private var accountRemovalSection: some View {
        Section {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Remove Guard Account", systemImage: "trash")
            }
            .disabled(appState.isAdminLoading || appState.adminAccounts.count <= 1)
        } header: {
            Text("Account Removal")
        } footer: {
            if appState.adminAccounts.count <= 1 {
                Text("The final account can't be removed. Sign up another guard from the login screen first.")
            } else {
                Text("Removing an account permanently deletes its server-side WhatsApp session and patrol data.")
            }
        }
    }
}
