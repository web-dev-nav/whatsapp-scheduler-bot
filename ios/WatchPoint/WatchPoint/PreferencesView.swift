//
//  PreferencesView.swift
//  WatchPoint
//
//  Device-only knobs with no browser equivalent -- pushed from the Account
//  hub. Account/session management lives in WhatsAppSessionView instead;
//  this screen is purely local preferences.
//

import SwiftUI

struct PreferencesView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section("Guard") {
                TextField("Guard name", text: $appState.guardName)
                    .textInputAutocapitalization(.never)
            }

            Section("Scheduler Admin") {
                TextField("Admin base URL", text: $appState.schedulerAdminBaseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Text("The engine's admin API, used for login, QR, and schedule editing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Patrol Send API") {
                TextField("n8n webhook URL", text: $appState.webhookURL, axis: .vertical)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                Text("Checkpoint arrivals go to n8n. They do not call the scheduler directly.")
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
    }
}
