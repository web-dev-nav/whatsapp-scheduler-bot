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
    @State private var showClearConfirmation = false
    @State private var pendingClearScope: ActivityClearScope = .all
    @State private var selectedFilter: ActivityFilter = .all

    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all
        case schedule
        case patrol

        var id: Self { self }
        var title: String {
            switch self {
            case .all: return "All"
            case .schedule: return "Scheduled"
            case .patrol: return "Patrol"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Activity Type", selection: $selectedFilter) {
                        ForEach(ActivityFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if selectedFilter == .all || selectedFilter == .schedule {
                    messageLogSection(
                        title: "Scheduled Messages",
                        icon: "calendar.badge.clock",
                        emptyMessage: "No scheduled message activity yet.",
                        entries: scheduledLogs
                    )
                }

                if selectedFilter == .all || selectedFilter == .patrol {
                    messageLogSection(
                        title: "Patrol Messages",
                        icon: "figure.walk",
                        emptyMessage: "No patrol message delivery activity yet.",
                        entries: patrolLogs
                    )
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

                if selectedFilter == .all, !systemLogs.isEmpty {
                    messageLogSection(
                        title: "System",
                        icon: "gearshape.2",
                        emptyMessage: "",
                        entries: systemLogs
                    )
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.isClearingActivity {
                        ProgressView()
                    } else {
                        Menu {
                            clearButton(scope: .schedule, disabled: scheduledLogs.isEmpty)
                            clearButton(scope: .patrol, disabled: patrolLogs.isEmpty && appState.history.isEmpty)
                            Divider()
                            clearButton(scope: .all, disabled: allActivityIsEmpty)
                        } label: {
                            Label("Clear Activity Log", systemImage: "trash")
                        }
                        .disabled(allActivityIsEmpty)
                    }
                }
            }
            .refreshable {
                async let logs: Void = appState.fetchLogs()
                async let patrol: Void = appState.fetchPatrolState()
                _ = await (logs, patrol)
            }
            .confirmationDialog(
                "Clear \(pendingClearScope.title.lowercased()) for \(currentAccountName)?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear \(pendingClearScope.title)", role: .destructive) {
                    Task { await appState.clearActivityLogs(scope: pendingClearScope) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearConfirmationMessage)
            }
        }
    }

    private func messageLogSection(
        title: String,
        icon: String,
        emptyMessage: String,
        entries: [SchedulerLogEntry]
    ) -> some View {
        Section {
            if entries.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { log in
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
            Label(title, systemImage: icon)
        } footer: {
            Text("Activity for \(currentAccountName).")
        }
    }

    private func clearButton(scope: ActivityClearScope, disabled: Bool) -> some View {
        Button(role: .destructive) {
            pendingClearScope = scope
            showClearConfirmation = true
        } label: {
            Label("Clear \(scope.title)", systemImage: scope == .all ? "trash" : "trash.slash")
        }
        .disabled(disabled)
    }

    private var allActivityIsEmpty: Bool {
        appState.logs.isEmpty && appState.history.isEmpty
    }

    private var scheduledLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "schedule" }
    }

    private var patrolLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "patrol" }
    }

    private var systemLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "system" }
    }

    private func activityCategory(for log: SchedulerLogEntry) -> String {
        if log.category == "schedule" || log.category == "patrol" {
            return log.category!
        }

        // Older engines did not send a category. Keep their in-memory logs
        // readable until the server is restarted on the versioned contract.
        let message = log.message.lowercased()
        if message.contains("location trigger")
            || message.contains("location-triggered")
            || message.contains("patrol message sent") {
            return "patrol"
        }
        if log.type == "scheduled"
            || message.contains("scheduled message")
            || message.contains("scheduler")
            || message.contains("sending patrol message")
            || message.hasPrefix("message sent") {
            return "schedule"
        }
        return "system"
    }

    private var clearConfirmationMessage: String {
        let removalDescription: String
        switch pendingClearScope {
        case .schedule:
            removalDescription = "This removes visible scheduled-message activity only."
        case .patrol:
            removalDescription = "This removes visible patrol delivery logs and checkpoint event history."
        case .all:
            removalDescription = "This removes all visible scheduled, patrol, and system activity."
        }
        return removalDescription
            + " Checkpoints, settings, WhatsApp connection, delivery safeguards, and duplicate-send protection remain unchanged."
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
                Label(event.apiReceived ? "API received" : "API pending", systemImage: event.apiReceived ? "checkmark.circle" : "clock")
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
