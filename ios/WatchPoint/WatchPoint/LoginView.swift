//
//  LoginView.swift
//  WatchPoint
//
//  Sign in or register via Phone Number and Security PIN.
//  Simpler and easier to remember during guard shifts.
//

import SwiftUI

enum LoginField: Hashable {
    case phoneNumber, pinCode
}

struct LoginView: View {
    @ObservedObject var appState: AppState
    @State private var phoneNumber = ""
    @State private var pinCode = ""
    @State private var isSigningUp = false
    @State private var showPin = false
    @FocusState private var focusedField: LoginField?

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Header Branding with Shield Icon
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 92, height: 92)

                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 46))
                            .foregroundStyle(Color.green.gradient)
                    }
                    .padding(.top, 20)

                    VStack(spacing: 6) {
                        Text("WatchPoint")
                            .font(.system(size: 30, weight: .bold))

                        Text("Guard Patrol & WhatsApp Notification Engine")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                // Phone & PIN Input Card
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Guard Sign In")
                            .font(.headline.weight(.semibold))
                        Text("Enter your phone number and security PIN to access your patrol shift.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)

                    VStack(spacing: 12) {
                        // Phone Number Input
                        HStack(spacing: 12) {
                            Image(systemName: "phone.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 22)

                            TextField("Phone Number (e.g. 555-123-4567)", text: $phoneNumber)
                                .keyboardType(.phonePad)
                                .textContentType(.telephoneNumber)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .phoneNumber)
                                .submitLabel(.next)
                                .onSubmit { focusedField = .pinCode }

                            if !phoneNumber.isEmpty {
                                Button {
                                    phoneNumber = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(focusedField == .phoneNumber ? Color.green : Color(.separator).opacity(0.4), lineWidth: focusedField == .phoneNumber ? 1.5 : 0.8)
                        )

                        // PIN Code Input
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.green)
                                .frame(width: 22)

                            if showPin {
                                TextField("4 to 6-Digit PIN", text: $pinCode)
                                    .keyboardType(.numberPad)
                                    .textContentType(isSigningUp ? .newPassword : .password)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .pinCode)
                                    .submitLabel(.go)
                                    .onSubmit { submitSignIn() }
                            } else {
                                SecureField("4 to 6-Digit PIN", text: $pinCode)
                                    .keyboardType(.numberPad)
                                    .textContentType(isSigningUp ? .newPassword : .password)
                                    .focused($focusedField, equals: .pinCode)
                                    .submitLabel(.go)
                                    .onSubmit { submitSignIn() }
                            }

                            Button {
                                showPin.toggle()
                                Haptics.impact(.light)
                            } label: {
                                Image(systemName: showPin ? "eye.slash.fill" : "eye.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(focusedField == .pinCode ? Color.green : Color(.separator).opacity(0.4), lineWidth: focusedField == .pinCode ? 1.5 : 0.8)
                        )
                    }

                    // Action Buttons
                    VStack(spacing: 12) {
                        Button {
                            submitSignIn()
                        } label: {
                            HStack(spacing: 8) {
                                if appState.isAdminLoading && !isSigningUp {
                                    ProgressView().tint(.white)
                                } else {
                                    Image(systemName: "lock.open.fill")
                                    Text("Sign In with PIN")
                                        .fontWeight(.bold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(!canSubmit || appState.isAdminLoading)

                        Button {
                            submitSignUp()
                        } label: {
                            HStack(spacing: 8) {
                                if appState.isAdminLoading && isSigningUp {
                                    ProgressView()
                                } else {
                                    Image(systemName: "person.badge.plus")
                                    Text("Register New Phone & PIN")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .disabled(!canSubmit || appState.isAdminLoading)
                    }
                    .padding(.top, 6)
                }
                .padding(20)
                .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color(.separator).opacity(0.4), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 2)

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Guard Sign In")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .task {
            if appState.adminAccounts.isEmpty {
                await appState.fetchAdminAccounts()
            }
        }
    }

    private var canSubmit: Bool {
        phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 && pinCode.count >= 4
    }

    private func submitSignIn() {
        guard canSubmit else { return }
        Haptics.impact(.medium)
        focusedField = nil
        let target = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await appState.loginAdmin(accountIdentifier: target, password: pinCode)
            if appState.isSignedIn {
                Haptics.notification(.success)
                pinCode = ""
            } else {
                Haptics.notification(.error)
            }
        }
    }

    private func submitSignUp() {
        guard canSubmit else { return }
        Haptics.impact(.medium)
        isSigningUp = true
        focusedField = nil
        let target = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let succeeded = await appState.createAccount(
                name: target,
                password: pinCode
            )
            isSigningUp = false
            if succeeded {
                Haptics.notification(.success)
                pinCode = ""
            } else {
                Haptics.notification(.error)
            }
        }
    }
}

// MARK: - Signup Pairing View

struct SignupPairingView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @State private var copiedLink = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 34))
                            .foregroundStyle(Color.green.gradient)
                    }
                    .padding(.top, 16)

                    Text("Link WhatsApp Session")
                        .font(.title2.weight(.bold))

                    Text("Scan this QR code with WhatsApp to connect your guard account before starting patrols.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }

                if let error = appState.whatsAppState?.error, !error.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(error)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                // QR Card
                WhatsAppPairingCard(appState: appState)
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)

                // Quick Link Actions
                if let url = appState.pairingPageURL {
                    VStack(spacing: 10) {
                        ShareLink(item: url) {
                            Label("Share Pairing Link", systemImage: "square.and.arrow.up")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            UIPasteboard.general.url = url
                            copiedLink = true
                            Haptics.notification(.success)
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                copiedLink = false
                            }
                        } label: {
                            Label(copiedLink ? "Link Copied!" : "Copy Pairing Link", systemImage: copiedLink ? "checkmark" : "doc.on.doc")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(copiedLink ? .green : .accentColor)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        Button {
                            appState.skipAppLockOnce = true
                            Haptics.impact(.light)
                            openURL(url)
                        } label: {
                            Label("Open QR in Safari", systemImage: "safari")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                Divider().padding(.vertical, 8)

                Button(role: .destructive) {
                    Haptics.impact(.medium)
                    Task { await appState.signOut() }
                } label: {
                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.left")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(24)
        }
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Link WhatsApp")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.selectedAdminAccountId) {
            while !Task.isCancelled {
                await appState.refreshWhatsAppStatus()
                if appState.isWhatsAppReady {
                    Haptics.notification(.success)
                    break
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

// MARK: - WhatsApp Pairing Card Subview

struct WhatsAppPairingCard: View {
    @ObservedObject var appState: AppState
    @State private var showFullscreenQR = false

    var body: some View {
        if let image = pairingImage {
            VStack(spacing: 16) {
                Button {
                    Haptics.impact(.light)
                    showFullscreenQR = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 2)

                        Image(uiImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(14)

                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(8)
                            .background(Color(.secondarySystemBackground).opacity(0.9), in: Circle())
                            .padding(10)
                    }
                    .frame(maxWidth: 240, maxHeight: 240)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                HStack(spacing: 6) {
                    Image(systemName: "hand.tap")
                        .font(.caption)
                    Text("Tap to enlarge • WhatsApp → Linked Devices → Link a Device")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .sheet(isPresented: $showFullscreenQR) {
                FullscreenQRView(image: image)
            }
        } else {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("Generating QR Code from Server…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
        }
    }

    private var pairingImage: UIImage? {
        guard let qrDataUrl = appState.whatsAppState?.qrDataUrl else { return nil }
        return UIImage(dataURL: qrDataUrl)
    }
}
