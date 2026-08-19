//
//  ContentView.swift
//  WatchPoint
//
//  Created by Navjot Singh on 2026-08-10.
//
//  3 top-level tabs, organized by how often a guard actually uses them
//  rather than by API concern: Patrol (home, everyday field use), Activity
//  (everyday, but secondary to Patrol), and Account (rare, config-time --
//  WhatsApp session, message/schedule, preferences, all pushed from one
//  hub instead of each being a permanent tab).
//

import SwiftUI

enum AppTab: Hashable {
    case patrol, activity, account
}

struct ContentView: View {
    @StateObject private var appState = AppState()
    @State private var selectedTab: AppTab = .patrol

    var body: some View {
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
            // Land first-time/logged-out users on Account to connect
            // WhatsApp first, rather than dropping them on an empty map.
            // Decided once at launch; the user is free to switch tabs
            // afterward without being forced back.
            if appState.adminToken.isEmpty {
                selectedTab = .account
            }
        }
        .task {
            if !appState.adminToken.isEmpty {
                await appState.fetchAdminAccounts()
                await appState.selectAccount(appState.selectedAdminAccountId)
            }
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

#Preview {
    ContentView()
}
