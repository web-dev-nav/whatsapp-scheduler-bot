//
//  ActivityTab.swift
//  WatchPoint
//
//  Scheduler log + patrol event history, its own top-level tab. Patrol
//  events are grouped by day and attributed to the guard who sent them
//  (`PatrolEvent.guardName`, captured at send time) -- important once
//  multiple guards share a device and switch accounts. Each event expands
//  to show full delivery detail (coordinates, accuracy, retry history, raw
//  response) that was already being captured but not surfaced.
//

import SwiftUI

struct ActivityTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        NavigationStack {
            List {
                schedulerLogSection
                patrolEventsHeaderSection
                ForEach(groupedHistory, id: \.day) { group in
                    Section(dayLabel(group.day)) {
                        ForEach(group.events) { event in
                            DisclosureGroup {
                                eventDetail(event)
                            } label: {
                                EventRow(event: event)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .refreshable { await appState.fetchLogs() }
            .task { await appState.fetchLogs() }
        }
    }

    private var schedulerLogSection: some View {
        Section {
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
                        if let accountName = log.accountName {
                            Text("\(accountName) · \(log.type.capitalized)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Scheduler Log")
        } footer: {
            Text("Scheduler activity for \(currentAccountName).")
        }
    }

    private var patrolEventsHeaderSection: some View {
        Section {
            HStack {
                Text("Patrol Events")
                    .font(.headline)
                Spacer()
                if appState.isRetrying {
                    ProgressView()
                } else if !appState.history.isEmpty {
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
            }
        }
    }

    private var currentAccountName: String {
        appState.adminAccounts.first(where: { $0.id == appState.selectedAdminAccountId })?.name
            ?? appState.selectedAdminAccountId
    }

    private struct DayGroup {
        let day: Date
        let events: [PatrolEvent]
    }

    private var groupedHistory: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: appState.history) { calendar.startOfDay(for: $0.timestamp) }
        return byDay
            .map { DayGroup(day: $0.key, events: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    @ViewBuilder
    private func eventDetail(_ event: PatrolEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

            if let latitude = event.latitude, let longitude = event.longitude {
                LabeledContent("Location", value: String(format: "%.5f, %.5f", latitude, longitude))
                    .font(.caption)
            }
            if let accuracy = event.accuracyMeters {
                LabeledContent("GPS Accuracy", value: "\(Int(accuracy)) m")
                    .font(.caption)
            }
            LabeledContent("Attempts", value: "\(event.retryCount)")
                .font(.caption)
            if let lastAttemptAt = event.lastAttemptAt {
                LabeledContent("Last Attempt", value: lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }

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
