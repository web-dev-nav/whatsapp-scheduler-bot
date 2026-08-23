//
//  PreferencesView.swift
//  WatchPoint
//
//  Device-local connection settings. Patrol spacing and GPS accuracy live
//  on the Account hub so they sit next to their explanations.
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
                Text("The engine's admin API, used for login, QR pairing, and schedule editing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Server Connection")
    }
}
