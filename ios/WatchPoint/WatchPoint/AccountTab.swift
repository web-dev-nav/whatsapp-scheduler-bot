//
//  AccountTab.swift
//  WatchPoint
//
//  Hub for guard profile, WhatsApp session management, message spacing,
//  GPS accuracy, automatic/patrol messages, and device security.
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
                // Guard Profile & Session Status Section
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.gradient)
                                    .frame(width: 48, height: 48)
                                Text(guardInitials)
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(appState.guardDisplayName)
                                    .font(.headline.weight(.semibold))
                                Text("Account: \(appState.selectedAccountName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            WhatsAppStatusBadge(state: appState.whatsAppState)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Guard Identity Name")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            TextField("Guard name", text: $appState.guardName)
                                .textInputAutocapitalization(.words)
                                .padding(8)
                                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                                .onSubmit {
                                    Haptics.impact(.light)
                                    Task { _ = await appState.savePatrolState() }
                                }
                        }
                    }
                    .padding(.vertical, 4)

                    Button {
                        Haptics.impact(.light)
                        showWhatsAppSession = true
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "qrcode", backgroundColor: .green)
                            Text("Manage WhatsApp Session")
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Button(role: .destructive) {
                        Haptics.impact(.medium)
                        Task { await appState.signOut() }
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "rectangle.portrait.and.arrow.left", backgroundColor: .red)
                            Text("Sign Out Guard")
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Active Guard Profile")
                } footer: {
                    Text("Each guard account maintains its own independent WhatsApp session, checkpoints, and patrol event history.")
                }

                // Security & Privacy
                Section {
                    Toggle(isOn: Binding(
                        get: { appState.appLockEnabled },
                        set: {
                            Haptics.impact(.light)
                            appState.setAppLockEnabled($0)
                        }
                    )) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "faceid", backgroundColor: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Require Face ID / Passcode")
                                Text("Lock app when leaving or returning")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Security & Privacy")
                }

                // GPS Location Accuracy
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "location.fill", backgroundColor: .teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GPS Accuracy Threshold")
                                Text("Max error allowed before sending: \(Int(appState.accuracyThresholdMeters)) m")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Slider(
                            value: $appState.accuracyThresholdMeters,
                            in: 10...100,
                            step: 5
                        )
                        .tint(.teal)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Location Precision")
                } footer: {
                    Text("Max accuracy is the largest GPS radius WatchPoint accepts. A tighter value (smaller meters) prevents false arrivals from weak indoor GPS.")
                }

                // Message Spacing Safeguards
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "timer", backgroundColor: .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Minimum Message Interval")
                                Text(intervalLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Stepper("", value: $minMessageInterval, in: 0...240, step: 5)
                            .labelsHidden()
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "arrow.counterclockwise.circle.fill", backgroundColor: .indigo)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Same-Checkpoint Cooldown")
                                Text(cooldownLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Stepper("", value: $appState.checkpointCooldownMinutes, in: 5...120, step: 5)
                            .labelsHidden()
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("Message Spacing Safeguards")
                } footer: {
                    Text("Minimum interval prevents back-to-back WhatsApp messages so account traffic remains natural. Same-checkpoint cooldown prevents re-triggering the same checkpoint repeatedly.")
                }

                // Message Templates & Destination
                Section("Message Templates & Routing") {
                    NavigationLink {
                        DeliverySettingsView(appState: appState)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "bubble.left.and.bubble.right.fill", backgroundColor: .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Shared Destination Chat")
                                Text(appState.patrolConfig?.groupName.isEmpty == false ? appState.patrolConfig!.groupName : "Not configured")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        SetupView(appState: appState)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "calendar.badge.clock", backgroundColor: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Automatic Message & Schedule")
                                Text("Timed routine shifts")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    NavigationLink {
                        PatrolMessageView(appState: appState)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "figure.walk", backgroundColor: .purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Patrol Arrival Message")
                                Text("GPS checkpoint text template")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                // Server Diagnostics
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Admin Engine Base URL")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(.vertical, 2)

                    NavigationLink {
                        HostStatusView(appState: appState)
                    } label: {
                        HStack(spacing: 12) {
                            SettingsIconBadge(systemName: "network", backgroundColor: .gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Test Server Connection")
                                Text("Ping latency, TLS & engine health")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Server Connection")
                } footer: {
                    Text("WatchPoint connects securely to the Scheduler Engine over Tailscale HTTPS.")
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

    private var guardInitials: String {
        let name = appState.guardDisplayName
        let parts = name.split(separator: " ")
        if let first = parts.first?.first {
            if parts.count > 1, let second = parts.last?.first {
                return "\(first)\(second)".uppercased()
            }
            return "\(first)".uppercased()
        }
        return "G"
    }

    private var intervalLabel: String {
        minMessageInterval == 0
            ? "No extra wait between sends"
            : "\(minMessageInterval) min gap between any two sends"
    }

    private var cooldownLabel: String {
        let minutes = Int(appState.checkpointCooldownMinutes)
        if minutes >= 60 {
            let hours = minutes / 60
            let remainder = minutes % 60
            if remainder == 0 {
                return "\(hours) hr cooldown on same spot"
            }
            return "\(hours)h \(remainder)m cooldown on same spot"
        }
        return "\(minutes) min cooldown on same spot"
    }

    private func loadIntervalIfNeeded() {
        guard !hasLoadedInterval, let config = appState.patrolConfig else { return }
        minMessageInterval = config.delivery?.minMessageIntervalMinutes ?? 0
        hasLoadedInterval = true
    }

    private func persistAccountSettings() async {
        _ = await appState.savePatrolState()
        guard hasLoadedInterval, var config = appState.patrolConfig else { return }
        let currentInterval = config.delivery?.minMessageIntervalMinutes ?? 0
        guard currentInterval != minMessageInterval else { return }
        config.delivery = DeliveryConfig(minMessageIntervalMinutes: minMessageInterval)
        appState.patrolConfig = config
        _ = await appState.saveConfig()
    }
}

// MARK: - Subviews & WhatsApp Status Badge

private struct WhatsAppStatusBadge: View {
    let state: WhatsAppAdminState?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        switch state?.status {
        case "ready": return .green
        case "qr", "authenticated", "starting": return .orange
        default: return .red
        }
    }

    private var statusLabel: String {
        guard let state else { return "Offline" }
        switch state.status {
        case "ready": return "Ready"
        case "qr": return "Scan QR"
        case "authenticated": return "Linked"
        case "starting": return "Starting"
        default: return state.status.capitalized
        }
    }
}

// MARK: - WhatsApp Session Manager View

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
                        Haptics.impact(.light)
                        openURL(url)
                    } label: {
                        Label("Open QR in Safari", systemImage: "safari")
                    }
                }
            }

            if !appState.adminToken.isEmpty {
                sessionActionsSection
                accountRemovalSection
            }
        }
        .navigationTitle("WhatsApp Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Remove \(appState.selectedAccountName)?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Remove Account and Data", role: .destructive) {
                Haptics.impact(.medium)
                Task { await appState.deleteSelectedAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes this guard's WhatsApp session, schedule, checkpoints, and patrol history from the server. This cannot be undone.")
        }
        .confirmationDialog(
            "Log out of WhatsApp?",
            isPresented: $showLogoutConfirm,
            titleVisibility: .visible
        ) {
            Button("Log Out WhatsApp", role: .destructive) {
                Haptics.impact(.medium)
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
                    ZStack {
                        Circle()
                            .fill(sessionColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: sessionIcon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(sessionColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(appState.selectedAccountName)
                            .font(.headline.weight(.semibold))
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
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Current WhatsApp Link")
        }
    }

    private var sessionStatusTitle: String {
        switch appState.whatsAppState?.status {
        case "ready": return "Connected and ready"
        case "qr": return "Waiting for QR pairing"
        case "authenticated": return "WhatsApp authenticated"
        case "starting": return "Starting WhatsApp…"
        case "logging_out": return "Logging out…"
        case "disconnected": return "WhatsApp disconnected"
        case "error": return "Connection error"
        case .some(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Checking connection…"
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
                Haptics.impact(.light)
                Task { await appState.refreshWhatsAppStatus() }
            } label: {
                Label("Refresh Session Status", systemImage: "arrow.clockwise")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                Haptics.impact(.medium)
                showLogoutConfirm = true
            } label: {
                Label("Unlink WhatsApp Session", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .disabled(appState.isAdminLoading)

            Button(role: .destructive) {
                Haptics.impact(.medium)
                Task { await appState.signOut() }
            } label: {
                Label("Sign Out of Guard Account", systemImage: "rectangle.portrait.and.arrow.left")
            }
            .disabled(appState.isAdminLoading)
        } header: {
            Text("Session Actions")
        } footer: {
            Text("Unlink WhatsApp disconnects only this session. Your guard account and patrol data remain safe on the server.")
        }
    }

    private var accountRemovalSection: some View {
        Section {
            Button(role: .destructive) {
                Haptics.impact(.medium)
                showDeleteConfirm = true
            } label: {
                Label("Remove Guard Account", systemImage: "trash")
            }
            .disabled(appState.isAdminLoading || appState.adminAccounts.count <= 1)
        } header: {
            Text("Account Removal")
        } footer: {
            if appState.adminAccounts.count <= 1 {
                Text("The final guard account cannot be removed.")
            } else {
                Text("Permanently deletes this account, WhatsApp session, and history from the server.")
            }
        }
    }
}
