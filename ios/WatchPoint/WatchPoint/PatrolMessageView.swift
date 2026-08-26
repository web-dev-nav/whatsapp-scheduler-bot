//
//  PatrolMessageView.swift
//  WatchPoint
//
//  Message editor for GPS checkpoint-arrival sends with live WhatsApp preview bubble.
//

import SwiftUI

struct PatrolMessageView: View {
    @ObservedObject var appState: AppState
    @State private var draftMessage = ""
    @State private var hasLoadedDraft = false
    @State private var showSavedConfirmation = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draftMessage)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(4)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(.separator).opacity(0.4), lineWidth: 0.8)
                    )
            } header: {
                Text("Checkpoint Arrival Message")
            } footer: {
                Text("Sent automatically when an active patrol enters any checkpoint perimeter. Checkpoint and guard names remain in your internal WatchPoint activity.")
            }

            Section("Live Message Preview") {
                WhatsAppBubblePreview(
                    message: draftMessage,
                    chatName: appState.patrolConfig?.groupName.isEmpty == false ? appState.patrolConfig!.groupName : "Security Ops"
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Button {
                    Haptics.impact(.medium)
                    save()
                } label: {
                    if appState.isConfigLoading {
                        ProgressView().tint(.white).frame(maxWidth: .infinity)
                    } else {
                        Label("Save Patrol Message", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
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
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("Your checkpoint-arrival patrol message template has been saved.")
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
                Haptics.notification(.success)
                draftMessage = appState.patrolConfig?.patrol.message ?? trimmedMessage
                showSavedConfirmation = true
            } else {
                Haptics.notification(.error)
                appState.patrolConfig = previousConfig
            }
        }
    }
}
