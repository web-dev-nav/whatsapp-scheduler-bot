//
//  ContentView.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//
//  3 top-level tabs, organized by how often a guard actually uses them
//  rather than by API concern: Patrol (home, everyday field use), Activity
//  (everyday, but secondary to Patrol), and Account (rare, config-time --
//  WhatsApp session, automatic/patrol messages, schedule, and preferences, all pushed from one
//  hub instead of each being a permanent tab).
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
            } else if !appState.isSignedIn {
                NavigationStack {
                    LoginView(appState: appState)
                }
            } else if !appState.isWhatsAppReady {
                NavigationStack {
                    SignupPairingView(appState: appState)
                }
            } else {
                unlockedContent
            }
        }
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
                    try? await Task.sleep(for: .milliseconds(250))
                    await appState.unlockApp()
                }
            default:
                break
            }
        }
        .onChange(of: appState.requiresAdminLogin) { _, requiresLogin in
            if requiresLogin { selectedTab = .account }
        }
        .onChange(of: appState.isSignedIn) { _, signedIn in
            if !signedIn { selectedTab = .patrol }
        }
        .alert("WatchPoint", isPresented: alertIsPresented) {
            Button("OK", role: .cancel) { appState.alertMessage = nil }
        } message: {
            Text(appState.alertMessage ?? "")
        }
    }

    private var unlockedContent: some View {
        TabView(selection: $selectedTab) {
            PatrolTab(appState: appState, selectedTab: $selectedTab)
                .tabItem { Label("Patrol", systemImage: "shield.lefthalf.filled") }
                .tag(AppTab.patrol)
            ActivityTab(appState: appState)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.activity)
            AccountTab(appState: appState)
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(AppTab.account)
        }
        .onAppear {
            selectedTab = .patrol
        }
    }

    private var alertIsPresented: Binding<Bool> {
        Binding(
            get: { appState.alertMessage != nil },
            set: { if !$0 { appState.alertMessage = nil } }
        )
    }
}

private struct AppLockView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 58))
                .foregroundStyle(.green)
            VStack(spacing: 6) {
                Text("WatchPoint Locked")
                    .font(.title2.weight(.semibold))
                Text("Authenticate to view guard accounts and patrol data.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let error = appState.appLockError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button {
                Task { await appState.unlockApp() }
            } label: {
                Label("Unlock with Face ID", systemImage: "faceid")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isAuthenticatingApp)

            Button {
                Task { await appState.unlockApp(preferPasscode: true) }
            } label: {
                Text("Use Passcode")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.isAuthenticatingApp)
        }
        .padding(32)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

#Preview {
    ContentView()
}
