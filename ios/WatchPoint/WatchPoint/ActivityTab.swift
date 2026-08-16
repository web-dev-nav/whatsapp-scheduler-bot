//
//  ActivityTab.swift
//  WatchPoint
//
//  Scheduler log + patrol event history, its own top-level tab.
//

import SwiftUI

struct ActivityTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                Section("Scheduler Log") {
                    if appState.logs.isEmpty {
                        Text("No scheduler activity yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.logs) { log in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(log.message)
                                    .font(.subheadline)
                                Text(log.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Patrol Events")
                            .font(.headline)
                        Spacer()
                        if appState.isRetrying {
                            ProgressView()
                        } else {
                            Button {
                                Task { await appState.retryQueuedEvents() }
                            } label: {
                                Label("Retry Queue", systemImage: "arrow.clockwise")
                            }
                            .font(.caption)
                        }
                    }

                    if appState.history.isEmpty {
                        Text("No patrol events yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.history) { event in
                            VStack(alignment: .leading, spacing: 8) {
                                EventRow(event: event)
                                HStack {
                                    Label(event.webhookReceived ? "Webhook received" : "Webhook pending", systemImage: event.webhookReceived ? "checkmark.circle" : "clock")
                                    Spacer()
                                    if let responseCode = event.responseCode {
                                        Text("HTTP \(responseCode)")
                                    }
                                    if let schedulerStatusCode = event.schedulerStatusCode {
                                        Text("Scheduler \(schedulerStatusCode)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let summary = event.responseSummary {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if let reason = event.schedulerReason {
                                    Text(reason)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .refreshable { await appState.fetchLogs() }
            .task { await appState.fetchLogs() }
        }
    }
}
