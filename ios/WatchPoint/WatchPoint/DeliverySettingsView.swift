//
//  DeliverySettingsView.swift
//  WatchPoint
//
//  Shared WhatsApp destination for automatic and patrol-arrival messages.
//  Features chat picker and live WhatsApp bubble preview.
//

import SwiftUI

struct DeliverySettingsView: View {
    @ObservedObject var appState: AppState
    @State private var selectedGroup = ""
    @State private var hasLoadedDraft = false
    @State private var showSavedConfirmation = false

    var body: some View {
        Form {
            Section {
                if let chats = appState.whatsAppState?.chats, !chats.isEmpty {
                    Picker("Destination", selection: $selectedGroup) {
                        if !selectedGroup.isEmpty, !chats.contains(where: { $0.name == selectedGroup }) {
                            Text(selectedGroup).tag(selectedGroup)
                        }
                        ForEach(chats) { chat in
                            HStack {
                                Image(systemName: chat.isGroup ? "person.3.fill" : "person.fill")
                                Text(chat.name)
                            }
                            .tag(chat.name)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } else {
                    TextField("WhatsApp group or chat name", text: $selectedGroup)
                    Text("Connect WhatsApp and refresh its session to select from available chats.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("WhatsApp Destination Chat")
            } footer: {
                Text("Both scheduled automatic messages and checkpoint arrival alerts are dispatched to this destination.")
            }

            Section("Destination Preview") {
                WhatsAppBubblePreview(
                    message: appState.patrolConfig?.message ?? "Guard on duty at checkpoint.",
                    chatName: selectedGroup.isEmpty ? "Security Ops" : selectedGroup
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
                        Label("Save Destination", systemImage: "checkmark.circle.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
                .disabled(appState.isConfigLoading || selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("Shared Destination Chat")
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
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("The shared WhatsApp destination has been saved successfully.")
        }
    }

    private func loadDraftIfNeeded() {
        guard !hasLoadedDraft, let config = appState.patrolConfig else { return }
        selectedGroup = config.groupName
        hasLoadedDraft = true
    }

    private func save() {
        guard var config = appState.patrolConfig else { return }
        let previousConfig = config
        config.groupName = selectedGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.patrolConfig = config

        Task {
            if await appState.saveConfig() {
                Haptics.notification(.success)
                showSavedConfirmation = true
            } else {
                Haptics.notification(.error)
                appState.patrolConfig = previousConfig
            }
        }
    }
}
