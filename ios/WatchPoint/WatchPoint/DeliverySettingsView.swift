//
//  DeliverySettingsView.swift
//  WatchPoint
//
//  Account-scoped controls shared by automatic and patrol-arrival messages.
//

import SwiftUI

struct DeliverySettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedGroup = ""
    @State private var minimumInterval = 0
    @State private var hasLoadedDraft = false
    @State private var showSavedConfirmation = false

    var body: some View {
        Form {
            Section("WhatsApp Destination") {
                if let chats = appState.whatsAppState?.chats, !chats.isEmpty {
                    Picker("Group or chat", selection: $selectedGroup) {
                        if !selectedGroup.isEmpty, !chats.contains(where: { $0.name == selectedGroup }) {
                            Text(selectedGroup).tag(selectedGroup)
                        }
                        ForEach(chats) { chat in
                            Text(chat.name).tag(chat.name)
                        }
                    }
                } else {
                    TextField("WhatsApp group or chat", text: $selectedGroup)
                    Text("Connect WhatsApp and refresh its session to select from available chats.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("Both automatic messages and checkpoint-arrival messages are sent here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Message Interval") {
                Stepper(intervalLabel, value: $minimumInterval, in: 0...240)
                Text("This is the minimum wait between any two outgoing messages for this account. Zero allows different checkpoints to send immediately. A checkpoint still keeps its separate re-entry cooldown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    save()
                } label: {
                    if appState.isConfigLoading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Save Shared Settings", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.isConfigLoading || selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Shared Delivery Settings")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .task {
            if !appState.adminToken.isEmpty {
                async let config: Void = appState.fetchConfig()
                async let status: Void = appState.refreshWhatsAppStatus()
                _ = await (config, status)
            }
            loadDraftIfNeeded()
        }
        .onChange(of: appState.patrolConfig) { _, _ in loadDraftIfNeeded() }
        .alert("Saved", isPresented: $showSavedConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The shared WhatsApp destination and message interval have been saved.")
        }
    }

    private var intervalLabel: String {
        minimumInterval == 0 ? "Minimum interval: No wait" : "Minimum interval: \(minimumInterval) min"
    }

    private func loadDraftIfNeeded() {
        guard !hasLoadedDraft, let config = appState.patrolConfig else { return }
        selectedGroup = config.groupName
        minimumInterval = config.delivery?.minMessageIntervalMinutes ?? 0
        hasLoadedDraft = true
    }

    private func save() {
        guard var config = appState.patrolConfig else { return }
        let previousConfig = config
        config.groupName = selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        config.delivery = DeliveryConfig(minMessageIntervalMinutes: minimumInterval)
        appState.patrolConfig = config

        Task {
            if await appState.saveConfig() {
                showSavedConfirmation = true
            } else {
                appState.patrolConfig = previousConfig
            }
        }
    }
}
