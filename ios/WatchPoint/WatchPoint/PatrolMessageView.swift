//
//  PatrolMessageView.swift
//  WatchPoint
//
//  Separate message editor for GPS checkpoint-arrival sends. Automatic timed
//  messages remain in SetupView so guards cannot accidentally edit both paths.
//

import SwiftUI

struct PatrolMessageView: View {
    @ObservedObject var appState: AppState
    @State private var draftMessage = ""
    @State private var hasLoadedDraft = false
    @State private var showSavedConfirmation = false

    var body: some View {
        Form {
            Section("Checkpoint Arrival Message") {
                TextEditor(text: $draftMessage)
                    .frame(minHeight: 180)

                Text("Sent when an active patrol enters a checkpoint radius. Only this text is sent to WhatsApp; checkpoint and guard names stay in WatchPoint activity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    save()
                } label: {
                    if appState.isConfigLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Save Patrol Message", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.isConfigLoading || draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Patrol Arrival Message")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .scrollDismissesKeyboard(.interactively)
        .task {
            if appState.patrolConfig == nil, !appState.adminToken.isEmpty {
                await appState.fetchConfig()
            }
            loadDraftIfNeeded()
        }
        .onChange(of: appState.patrolConfig) { _, _ in
            loadDraftIfNeeded()
        }
        .alert("Saved", isPresented: $showSavedConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your checkpoint-arrival patrol message has been saved.")
        }
    }

    private func loadDraftIfNeeded() {
        guard !hasLoadedDraft, let config = appState.patrolConfig else { return }
        draftMessage = config.patrol.message.isEmpty ? config.message : config.patrol.message
        hasLoadedDraft = true
    }

    private func save() {
        let trimmedMessage = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty, var config = appState.patrolConfig else { return }

        let previousConfig = config
        config.patrol.message = trimmedMessage
        appState.patrolConfig = config

        Task {
            if await appState.saveConfig() {
                draftMessage = appState.patrolConfig?.patrol.message ?? trimmedMessage
                showSavedConfirmation = true
            } else {
                appState.patrolConfig = previousConfig
            }
        }
    }
}
