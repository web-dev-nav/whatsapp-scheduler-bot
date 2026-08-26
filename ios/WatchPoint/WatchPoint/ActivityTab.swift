//
//  ActivityTab.swift
//  WatchPoint
//
//  Scheduler logs and patrol event history.
//  - Metric cards (total sends, success rate, pending queue)
//  - Search & category filter (All, Scheduled, Patrol)
//  - Grouped patrol events with expandable delivery diagnostics
//  - Manual retry queue and activity log management
//

import SwiftUI

struct ActivityTab: View {
    @ObservedObject var appState: AppState
    @State private var showClearConfirmation = false
    @State private var pendingClearScope: ActivityClearScope = .all
    @State private var selectedFilter: ActivityFilter = .all
    @State private var searchText = ""

    private enum ActivityFilter: String, CaseIterable, Identifiable {
        case all, schedule, patrol

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
                // Top Metrics Overview
                Section {
                    metricsHeader
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                // Filter Segmented Picker
                Section {
                    Picker("Activity Type", selection: $selectedFilter) {
                        ForEach(ActivityFilter.allCases) { filter in
                            Text(filterBadgeTitle(for: filter)).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: selectedFilter) { _, _ in
                        Haptics.selection()
                    }
                }

                // Scheduled Messages Section
                if (selectedFilter == .all || selectedFilter == .schedule) && shouldShowSection(for: filteredScheduledLogs) {
                    messageLogSection(
                        title: "Scheduled Messages",
                        icon: "calendar.badge.clock",
                        badgeCount: filteredScheduledLogs.count,
                        emptyMessage: "No scheduled message activity matching search.",
                        entries: filteredScheduledLogs
                    )
                }

                // Patrol Logs & Events Section
                if selectedFilter == .all || selectedFilter == .patrol {
                    if !filteredPatrolLogs.isEmpty {
                        messageLogSection(
                            title: "Patrol Engine Activity",
                            icon: "antenna.radiowaves.left.and.right",
                            badgeCount: filteredPatrolLogs.count,
                            emptyMessage: "",
                            entries: filteredPatrolLogs
                        )
                    }

                    patrolEventsHeaderSection

                    if filteredHistory.isEmpty && (selectedFilter == .patrol || !searchText.isEmpty) {
                        Section {
                            ContentUnavailableView(
                                searchText.isEmpty ? "No Patrol Events" : "No Matching Events",
                                systemImage: "figure.walk",
                                description: Text(searchText.isEmpty ? "Patrol checkpoint arrivals will appear here once triggered." : "No events matched '\(searchText)'.")
                            )
                            .padding(.vertical, 8)
                        }
                    } else {
                        ForEach(groupedFilteredHistory, id: \.day) { group in
                            Section {
                                ForEach(group.events) { event in
                                    DisclosureGroup {
                                        eventDetail(event)
                                    } label: {
                                        EventRow(event: event)
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(dayLabel(group.day))
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text("\(group.events.count) events")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // System Logs Section
                if selectedFilter == .all, !filteredSystemLogs.isEmpty {
                    messageLogSection(
                        title: "System Logs",
                        icon: "gearshape.2",
                        badgeCount: filteredSystemLogs.count,
                        emptyMessage: "",
                        entries: filteredSystemLogs
                    )
                }
            }
            .navigationTitle("Activity")
            .searchable(text: $searchText, prompt: "Search events, logs, or guards")
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
                            Image(systemName: "trash")
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
                    Haptics.impact(.medium)
                    Task { await appState.clearActivityLogs(scope: pendingClearScope) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(clearConfirmationMessage)
            }
        }
    }

    // MARK: - Metrics Header

    private var metricsHeader: some View {
        HStack(spacing: 12) {
            metricCard(
                title: "Total Sends",
                value: "\(totalSendsToday)",
                icon: "paperplane.fill",
                color: .green
            )

            metricCard(
                title: "Success Rate",
                value: successRateText,
                icon: "checkmark.circle.fill",
                color: .blue
            )

            metricCard(
                title: "In Queue",
                value: "\(queuedEventCount)",
                icon: "tray.full.fill",
                color: queuedEventCount > 0 ? .orange : .secondary
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Spacer()
            }
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
    }

    // MARK: - Sections & Rows

    private func messageLogSection(
        title: String,
        icon: String,
        badgeCount: Int,
        emptyMessage: String,
        entries: [SchedulerLogEntry]
    ) -> some View {
        Section {
            if entries.isEmpty {
                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.message)
                            .font(.subheadline.weight(.medium))

                        HStack(spacing: 6) {
                            Text(log.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let accountName = log.accountName {
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(accountName)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(badgeCount)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var patrolEventsHeaderSection: some View {
        Section {
            HStack {
                Label("Patrol Arrivals", systemImage: "figure.walk")
                    .font(.headline)
                Spacer()
                if appState.isRetrying {
                    ProgressView()
                } else if queuedEventCount > 0 {
                    Button {
                        Haptics.impact(.medium)
                        Task { await appState.retryQueuedEvents() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Queue (\(queuedEventCount))")
                        }
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
            }
        }
    }

    private func clearButton(scope: ActivityClearScope, disabled: Bool) -> some View {
        Button(role: .destructive) {
            Haptics.impact(.medium)
            pendingClearScope = scope
            showClearConfirmation = true
        } label: {
            Label("Clear \(scope.title)", systemImage: scope == .all ? "trash" : "trash.slash")
        }
        .disabled(disabled)
    }

    // MARK: - Event Detail Expansion

    @ViewBuilder
    private func eventDetail(_ event: PatrolEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusBadge(
                    title: event.apiReceived ? "API Received" : "API Pending",
                    icon: event.apiReceived ? "checkmark.circle" : "clock",
                    color: event.apiReceived ? .green : .orange
                )
                Spacer()
                if let responseCode = event.responseCode {
                    Text("HTTP \(responseCode)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let latitude = event.latitude, let longitude = event.longitude {
                LabeledContent("Coordinates", value: String(format: "%.5f, %.5f", latitude, longitude))
                    .font(.caption)
            }
            if let accuracy = event.accuracyMeters {
                LabeledContent("GPS Accuracy", value: "\(Int(accuracy)) m")
                    .font(.caption)
            }
            LabeledContent("Delivery Retries", value: "\(event.retryCount)")
                .font(.caption)

            if let lastAttemptAt = event.lastAttemptAt {
                LabeledContent("Last Attempt", value: lastAttemptAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }

            if let summary = event.responseSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            if let reason = event.schedulerReason {
                Text(reason)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Filtering & Grouping

    private var scheduledLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "schedule" }
    }

    private var patrolLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "patrol" }
    }

    private var systemLogs: [SchedulerLogEntry] {
        appState.logs.filter { activityCategory(for: $0) == "system" }
    }

    private var filteredScheduledLogs: [SchedulerLogEntry] {
        if searchText.isEmpty { return scheduledLogs }
        return scheduledLogs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredPatrolLogs: [SchedulerLogEntry] {
        if searchText.isEmpty { return patrolLogs }
        return patrolLogs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredSystemLogs: [SchedulerLogEntry] {
        if searchText.isEmpty { return systemLogs }
        return systemLogs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    private var filteredHistory: [PatrolEvent] {
        if searchText.isEmpty { return appState.history }
        return appState.history.filter {
            $0.checkpointName.localizedCaseInsensitiveContains(searchText)
                || $0.guardName.localizedCaseInsensitiveContains(searchText)
                || ($0.responseSummary?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private struct DayGroup {
        let day: Date
        let events: [PatrolEvent]
    }

    private var groupedFilteredHistory: [DayGroup] {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: filteredHistory) { calendar.startOfDay(for: $0.timestamp) }
        return byDay
            .map { DayGroup(day: $0.key, events: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    private func filterBadgeTitle(for filter: ActivityFilter) -> String {
        switch filter {
        case .all: return "All (\(appState.logs.count + appState.history.count))"
        case .schedule: return "Schedule (\(scheduledLogs.count))"
        case .patrol: return "Patrol (\(patrolLogs.count + appState.history.count))"
        }
    }

    private func shouldShowSection(for entries: [SchedulerLogEntry]) -> Bool {
        !entries.isEmpty || (!searchText.isEmpty && selectedFilter == .schedule)
    }

    private var allActivityIsEmpty: Bool {
        appState.logs.isEmpty && appState.history.isEmpty
    }

    private var queuedEventCount: Int {
        appState.history.filter { $0.status == .queued || $0.status == .sending }.count
    }

    private var totalSendsToday: Int {
        let calendar = Calendar.current
        let todayHistory = appState.history.filter { calendar.isDateInToday($0.timestamp) && $0.status == .schedulerSucceeded }.count
        let todayLogs = scheduledLogs.filter { $0.message.lowercased().contains("sent") }.count
        return todayHistory + todayLogs
    }

    private var successRateText: String {
        guard !appState.history.isEmpty else { return "100%" }
        let successful = appState.history.filter { $0.status == .schedulerSucceeded }.count
        let percentage = Int((Double(successful) / Double(appState.history.count)) * 100)
        return "\(percentage)%"
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    private func activityCategory(for log: SchedulerLogEntry) -> String {
        if log.category == "schedule" || log.category == "patrol" {
            return log.category!
        }
        let message = log.message.lowercased()
        if message.contains("location trigger") || message.contains("location-triggered") || message.contains("patrol message sent") {
            return "patrol"
        }
        if log.type == "scheduled" || message.contains("scheduled message") || message.contains("scheduler") || message.contains("sending patrol message") || message.hasPrefix("message sent") {
            return "schedule"
        }
        return "system"
    }

    private var currentAccountName: String {
        appState.adminAccounts.first(where: { $0.id == appState.selectedAdminAccountId })?.name
            ?? appState.selectedAdminAccountId
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
}
