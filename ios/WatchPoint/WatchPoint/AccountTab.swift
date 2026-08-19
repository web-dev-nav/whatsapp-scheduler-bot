//
//  AccountTab.swift
//  WatchPoint
//
//  Hub for everything a guard only touches rarely: which WhatsApp session
//  is connected, the message/schedule config, and device preferences. Each
//  row pushes a full screen from this tab's single NavigationStack rather
//  than being its own top-level tab -- these are config-time flows, not
//  something used constantly during a shift.
//

import SwiftUI

struct AccountTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        WhatsAppSessionView(appState: appState)
                    } label: {
                        WhatsAppConnectionRow(state: appState.whatsAppState)
                    }
                } header: {
                    Text("WhatsApp Session")
                } footer: {
                    if let account = appState.adminAccounts.first(where: { $0.id == appState.selectedAdminAccountId }) {
                        Text("Currently on \"\(account.name)\" (\(appState.guardName)). Each account is a separate guard: its own WhatsApp login, checkpoints, patrol history, and guard name. Switching accounts switches all of it, and stops any patrol in progress.")
                    }
                }

                Section("Configuration") {
                    NavigationLink("Message & Schedule") {
                        SetupView(appState: appState)
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
            .task {
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
    @State private var showFullscreenQR = false

    var body: some View {
        List {
            accountsSection
            guardNameSection
            selectedSessionSection
        }
        .navigationTitle("WhatsApp Session")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { Task { _ = await appState.savePatrolState() } }
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
            Text("Guards")
        } footer: {
            Text("Each guard is a separate WhatsApp account with its own login, checkpoints, schedule, and history.")
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
