//
//  LoginView.swift
//  WatchPoint
//
//  Sign-in / sign-up credentials, then a separate pairing screen until
//  WhatsApp is linked. Unlinked guards cannot open Patrol or Account.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var appState: AppState
    @State private var accountName = ""
    @State private var password = ""
    @State private var isSigningUp = false

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("WatchPoint")
                    .font(.largeTitle.weight(.semibold))
                Text("Enter an account name and password, then Sign In or Sign Up.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Account name", text: $accountName)
                    .textContentType(.username)
                    .textInputAutocapitalization(.words)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                SecureField("Password", text: $password)
                    .textContentType(isSigningUp ? .newPassword : .password)
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))

                Button {
                    Task {
                        await appState.loginAdmin(accountIdentifier: accountName, password: password)
                        if appState.isSignedIn { password = "" }
                    }
                } label: {
                    Label("Sign In", systemImage: "lock.open")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit || appState.isAdminLoading)

                Button {
                    isSigningUp = true
                    Task {
                        let succeeded = await appState.createAccount(
                            name: accountName.trimmingCharacters(in: .whitespacesAndNewlines),
                            password: password
                        )
                        isSigningUp = false
                        if succeeded { password = "" }
                    }
                } label: {
                    Label("Sign Up", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!canSubmit || appState.isAdminLoading)

                if appState.isAdminLoading {
                    ProgressView(isSigningUp ? "Creating account…" : "Signing in…")
                        .frame(maxWidth: .infinity)
                }
            }

            Spacer()
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .task {
            if appState.adminAccounts.isEmpty {
                await appState.fetchAdminAccounts()
            }
        }
    }

    private var canSubmit: Bool {
        accountName.trimmingCharacters(in: .whitespacesAndNewlines).count >= 1 && password.count >= 4
    }
}

struct SignupPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 20) {
            Text("Current Session")
                .font(.title2.weight(.semibold))
            Text("Scan this QR with WhatsApp to finish signup. You cannot use Patrol or Account until WhatsApp is linked.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let error = appState.whatsAppState?.error, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            WhatsAppPairingCard(appState: appState)

            if let url = appState.pairingPageURL {
                ShareLink(item: url) {
                    Label("Share Pairing Link", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    appState.skipAppLockOnce = true
                    openURL(url)
                } label: {
                    Label("Open QR in Browser", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button(role: .destructive) {
                Task { await appState.signOut() }
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Link WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.selectedAdminAccountId) {
            while !Task.isCancelled {
                await appState.refreshWhatsAppStatus()
                if appState.isWhatsAppReady { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

struct WhatsAppPairingCard: View {
    @ObservedObject var appState: AppState
    @State private var showFullscreenQR = false

    var body: some View {
        if let image = pairingImage {
            VStack(spacing: 12) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { showFullscreenQR = true }

                Text("WhatsApp → Settings → Linked Devices → Link a Device, then scan this code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .sheet(isPresented: $showFullscreenQR) {
                FullscreenQRView(image: image)
            }
        } else {
            ProgressView("Waiting for QR code…")
        }
    }

    private var pairingImage: UIImage? {
        guard let qrDataUrl = appState.whatsAppState?.qrDataUrl else { return nil }
        return UIImage(dataURL: qrDataUrl)
    }
}
