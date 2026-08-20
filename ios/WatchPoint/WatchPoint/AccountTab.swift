//
//  AccountTab.swift
//  WatchPoint
//
//  Hub for everything a guard only touches rarely: which WhatsApp session
//  is connected, automatic and patrol-message config, and device preferences. Each
//  row pushes a full screen from this tab's single NavigationStack rather
//  than being its own top-level tab -- these are config-time flows, not
//  something used constantly during a shift.
//

import SwiftUI

struct AccountTab: View {
    @ObservedObject var appState: AppState
    @State private var showWhatsAppSession = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showWhatsAppSession = true
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            WhatsAppConnectionRow(state: appState.whatsAppState)
                            Text("Manage guard accounts, login, pairing, and logout")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("WhatsApp & Guards")
                } footer: {
                    if let account = appState.adminAccounts.first(where: { $0.id == appState.selectedAdminAccountId }) {
                        Text("Currently on \"\(account.name)\" (\(appState.guardName)). Each account is a separate guard: its own WhatsApp login, checkpoints, patrol history, and guard name. Switching accounts switches all of it, and stops any patrol in progress.")
                    }
                }

                Section("Configuration") {
                    NavigationLink("Shared Delivery Settings") {
                        DeliverySettingsView(appState: appState)
                    }
                    NavigationLink("Automatic Message & Schedule") {
                        SetupView(appState: appState)
                    }
                    NavigationLink("Patrol Arrival Message") {
                        PatrolMessageView(appState: appState)
                    }
                    NavigationLink("Host & Connection") {
                        HostStatusView(appState: appState)
                    }
                    NavigationLink("Preferences") {
                        PreferencesView(appState: appState)
                    }
                }
            }
            .navigationTitle("Account")
            .navigationDestination(isPresented: $showWhatsAppSession) {
                WhatsAppSessionView(appState: appState)
            }
            .onChange(of: appState.requiresAdminLogin) { _, requiresLogin in
                if requiresLogin { showWhatsAppSession = true }
            }
            .task {
                if appState.requiresAdminLogin { showWhatsAppSession = true }
                await appState.fetchAdminAccounts()
                if !appState.adminToken.isEmpty {
                    await appState.refreshWhatsAppStatus()
                }
            }
        }
    }
}

// MARK: - WhatsApp session management (pushed from the Account hub)

private struct WhatsAppSessionView: View {
    @ObservedObject var appState: AppState
    @State private var adminPassword = ""
    @State private var showAddAccount = false
    @State private var showDeleteConfirm = false
    @State private var showLogoutConfirm = false
    @State private var showFullscreenQR = false

    var body: some View {
        List {
            currentSessionSection
            if pairingImage != nil {
                pairingSection
            }
            accountsSection
            if !appState.adminToken.isEmpty {
                guardNameSection
                sessionActionsSection
                accountRemovalSection
            }
        }
        .navigationTitle("WhatsApp & Guards")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { Task { _ = await appState.savePatrolState() } }
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
        .sheet(isPresented: $showAddAccount) {
            AddAccountSheet { name, password in
                await appState.createAccount(name: name, password: password)
            }
        }
        .task(id: pollKey) {
            // Auto-poll status (and any QR code the server generates) until
            // WhatsApp is ready, so scanning the QR "just works" without the
            // user having to keep tapping Refresh. Scoped to this screen --
            // it stops the moment the guard navigates back to the Account
            // hub or another tab, since it's a pushed detail view now.
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

    private var pairingImage: UIImage? {
        guard let qrDataUrl = appState.whatsAppState?.qrDataUrl else { return nil }
        return UIImage(dataURL: qrDataUrl)
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

                if appState.adminToken.isEmpty {
                    loginFields
                } else if appState.whatsAppState?.status != "ready", pairingImage == nil {
                    Text("Waiting for the Scheduler API and WhatsApp. This screen refreshes automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
        } footer: {
            Text("The Scheduler account stores this guard's WhatsApp connection and patrol data on the server.")
        }
    }

    private var sessionStatusTitle: String {
        guard !appState.adminToken.isEmpty else { return "Password required" }
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
        if appState.adminToken.isEmpty { return "lock.fill" }
        switch appState.whatsAppState?.status {
        case "ready": return "checkmark.circle.fill"
        case "qr": return "qrcode"
        case "error", "disconnected": return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var sessionColor: Color {
        if appState.adminToken.isEmpty { return .orange }
        switch appState.whatsAppState?.status {
        case "ready": return .green
        case "error", "disconnected": return .red
        default: return .orange
        }
    }

    private var accountsSection: some View {
        Section {
            ForEach(appState.adminAccounts) { account in
                accountRow(account)
            }

            Button {
                showAddAccount = true
            } label: {
                Label("Add Guard", systemImage: "plus.circle")
            }
        } header: {
            Text("Switch Guard")
        } footer: {
            Text("Switching guards stops an active patrol before loading the selected account's data.")
        }
    }

    private func accountRow(_ account: SchedulerAccount) -> some View {
        Button {
            guard account.id != appState.selectedAdminAccountId else { return }
            adminPassword = ""
            Task { await appState.selectAccount(account.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(account.id == appState.selectedAdminAccountId ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .foregroundStyle(.primary)
                    Text(account.id == appState.selectedAdminAccountId ? "Current guard" : "Tap to switch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if account.id == appState.selectedAdminAccountId {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    /// Account-scoped server profile used to attribute every patrol event.
    private var guardNameSection: some View {
        Section {
            TextField("Guard name", text: $appState.guardName)
                .textInputAutocapitalization(.words)
                .onSubmit { Task { _ = await appState.savePatrolState() } }
        } header: {
            Text("This Guard")
        } footer: {
            Text("Shown in the duty log for every patrol event. Saved to this account through the Scheduler API.")
        }
    }

    private var loginFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField("Account password", text: $adminPassword)
                .textContentType(.password)
            Button {
                Task {
                    await appState.loginAdmin(password: adminPassword)
                    if !appState.adminToken.isEmpty { adminPassword = "" }
                }
            } label: {
                Label("Unlock Guard Account", systemImage: "lock.open")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(adminPassword.count < 4 || appState.isAdminLoading)
        }
    }

    private var sessionActionsSection: some View {
        Section("Connection Actions") {
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
                Text("The final account can't be removed. Add another guard account first.")
            } else {
                Text("Removing an account permanently deletes its server-side WhatsApp session and patrol data.")
            }
        }
    }

    private var pairingSection: some View {
        Section {
            if let image = pairingImage {
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

                Text("On the phone with this WhatsApp account, open **Settings → Linked Devices → Link a Device**, then scan this code from another display.")
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
        } header: {
            Text("Pair WhatsApp")
        } footer: {
            Text("The QR code refreshes automatically until WhatsApp reports that the session is ready.")
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
    let onAdd: (String, String) async -> Bool

    var body: some View {
        NavigationStack {
            Form {
                TextField("Account name", text: $name)
                    .textInputAutocapitalization(.words)
                SecureField("Password (min 4 characters)", text: $password)
                Text("This creates a separate WhatsApp login for a new guard. Their checkpoints, schedule, and duty log stay entirely separate from every other account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isSubmitting {
                    HStack {
                        Spacer()
                        ProgressView("Creating session…")
                        Spacer()
                    }
                }
            }
            .keyboardDoneButton()
            .navigationTitle("Add Guard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        isSubmitting = true
                        Task {
                            let succeeded = await onAdd(name.trimmingCharacters(in: .whitespaces), password)
                            isSubmitting = false
                            if succeeded { dismiss() }
                        }
                    }
                    .disabled(isSubmitting || name.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 4)
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }
}
