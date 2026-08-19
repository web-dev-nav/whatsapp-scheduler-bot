//
//  PreferencesView.swift
//  WatchPoint
//
//  The Admin API URL stays device-local so the app knows where to connect.
//  Patrol behavior settings are account-scoped server data.
//

import SwiftUI

struct PreferencesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Scheduler Admin") {
                TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Text("The engine's admin API, used for login, QR, and schedule editing.")
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
        }
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Preferences")
        .onDisappear { Task { _ = await appState.savePatrolState() } }
    }
}
