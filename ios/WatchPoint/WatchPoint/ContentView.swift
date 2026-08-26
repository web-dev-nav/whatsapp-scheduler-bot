//
//  ContentView.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//
//  3 top-level tabs, organized for real-world guard duty:
//  - Patrol (home, everyday field use & live GPS tracking)
//  - Activity (log & delivery history)
//  - Account (guard profile, WhatsApp session, schedule, and server settings)
//

import SwiftUI

enum AppTab: Hashable {
    case patrol, activity, account
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppState()
    @State private var selectedTab: AppTab = .patrol

    var body: some View {
        Group {
            if appState.isAppLocked {
                AppLockView(appState: appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if !appState.isSignedIn {
                NavigationStack {
                    LoginView(appState: appState)
                }
                .transition(.opacity)
            } else if !appState.isWhatsAppReady {
                NavigationStack {
                    SignupPairingView(appState: appState)
                }
                .transition(.opacity)
            } else {
                unlockedContent
                    .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.isAppLocked)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.isSignedIn)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: appState.isWhatsAppReady)
        .task {
            await appState.bootstrap()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                appState.lockApp()
            case .active:
                appState.refreshGuardReconfirmationRequirement()
                Task {
                    await appState.refreshEngineHealth()
                    try? await Task.sleep(for: .milliseconds(200))
                    await appState.unlockApp()
                }
            default:
                break
            }
        }
        .onChange(of: appState.requiresAdminLogin) { _, requiresLogin in
            if requiresLogin {
                Haptics.notification(.warning)
                selectedTab = .account
            }
        }
        .onChange(of: appState.isSignedIn) { _, signedIn in
            if !signedIn { selectedTab = .patrol }
        }
        .alert("WatchPoint", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
                appState.alertMessage = nil
            }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    private var unlockedContent: some View {
        TabView(selection: $selectedTab) {
            PatrolTab(appState: appState, selectedTab: $selectedTab)
                .tabItem {
                    Label("Patrol", systemImage: appState.shiftIsActive ? "shield.lefthalf.filled.badge.checkmark" : "shield.lefthalf.filled")
                }
                .badge(appState.shiftIsActive ? "LIVE" : nil)
                .tag(AppTab.patrol)

            ActivityTab(appState: appState)
                .tabItem {
                    Label("Activity", systemImage: "clock.arrow.circlepath")
                }
                .badge(failedEventCount > 0 ? "\(failedEventCount)" : nil)
                .tag(AppTab.activity)

            AccountTab(appState: appState)
                .tabItem {
                    Label("Account", systemImage: "person.crop.circle")
                }
                .tag(AppTab.account)
        }
        .tint(.green)
        .onAppear {
            selectedTab = .patrol
        }
    }

    private var failedEventCount: Int {
        appState.history.filter { $0.status == .failed || $0.status == .engineNotReady }.count
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )
    }
}

// MARK: - App Lock Screen

private struct AppLockView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.12))
                        .frame(width: 108, height: 108)

                    Circle()
                        .fill(Color.green.opacity(0.06))
                        .frame(width: 136, height: 136)

                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(Color.green.gradient)
                }

                VStack(spacing: 8) {
                    Text("WatchPoint")
                        .font(.largeTitle.weight(.bold))

                    Text("Authenticate to view guard account & live patrol.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
            }

            if let error = appState.appLockError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error)
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Haptics.impact(.medium)
                    Task { await appState.unlockApp() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "faceid")
                            .font(.title3)
                        Text(appState.isAuthenticatingApp ? "Authenticating…" : "Unlock with Face ID")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(appState.isAuthenticatingApp)

                Button {
                    Haptics.impact(.light)
                    Task { await appState.unlockApp(preferPasscode: true) }
                } label: {
                    Text("Use Device Passcode")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .disabled(appState.isAuthenticatingApp)
            }
            .padding(.horizontal, 8)
        }
        .padding(32)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    ContentView()
}
