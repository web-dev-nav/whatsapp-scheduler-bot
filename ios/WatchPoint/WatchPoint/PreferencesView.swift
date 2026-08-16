//
//  PreferencesView.swift
//  WatchPoint
//
//  Device-level knobs shared by whichever guard is using this device --
//  pushed from the Account hub. Deliberately does NOT include guard name,
//  which is per-account/per-guard and lives in WhatsAppSessionView instead
//  (see AppState.guardName). This screen only holds things that describe
//  the device/network, not a guard's identity.
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
