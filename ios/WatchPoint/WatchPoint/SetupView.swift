//
//  SetupView.swift
//  WatchPoint
//
//  Message + schedule config: a read-only overview with an "Edit Setup"
//  button that enters a 5-step wizard (chat -> days -> shift -> message ->
//  review), matching the browser's step-by-step flow. Pushed from the
//  Account hub as "Message & Schedule" -- no NavigationStack of its own
//  since it's a pushed destination, not a tab root.
//

import SwiftUI

enum SetupStep: Int, CaseIterable {
    case chat, days, shift, message, review

    var title: String {
        switch self {
        case .chat: return "Who gets the messages?"
        case .days: return "Which days?"
        case .shift: return "Day or night shift?"
        case .message: return "What should it say?"
        case .review: return "Review & turn on"
        }
    }
}

struct SetupView: View {
    @ObservedObject var appState: AppState
    @State private var step: SetupStep = .chat
    @State private var isEditing = false
    @State private var showSavedConfirmation = false

    var body: some View {
        Group {
            if let config = Binding($appState.patrolConfig) {
                if isEditing {
                    wizard(config: config)
                } else {
                    overview(config: config)
                }
            } else if appState.isConfigLoading {
                ProgressView("Loading setup…")
            } else {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "wifi.slash",
                    description: Text("Connect a WhatsApp session first.")
                )
            }
        }
        .navigationTitle("Message & Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.patrolConfig == nil, !appState.adminToken.isEmpty {
                await appState.fetchConfig()
            }
        }
        .alert("Saved", isPresented: $showSavedConfirmation) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your message and schedule have been saved.")
        }
    }

    /// Read-only summary of the current setup with a single "Edit Setup"
    /// button, so returning users land on an overview instead of always
    /// being dropped back into step 1 of the wizard.
    private func overview(config: Binding<PatrolConfig>) -> some View {
        Form {
            Section("Current Setup") {
                LabeledContent("Chat", value: config.wrappedValue.groupName.isEmpty ? "Not set" : config.wrappedValue.groupName)
                LabeledContent("Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
                LabeledContent("Message", value: config.wrappedValue.message.isEmpty ? "Not set" : config.wrappedValue.message)
                    .lineLimit(3)
            }

            Section {
                Toggle("Automatic sending", isOn: config.schedule.enabled)
                    .onChange(of: config.wrappedValue.schedule.enabled) { _, _ in
                        Task { await appState.saveConfig() }
                    }
            }

            Section {
                Button {
                    step = .chat
                    isEditing = true
                } label: {
                    Label("Edit Setup", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func wizard(config: Binding<PatrolConfig>) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                ProgressView(value: Double(step.rawValue + 1), total: Double(SetupStep.allCases.count))
                Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(step.title)
                        .font(.title2.weight(.semibold))
                    stepContent(config: config)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            Divider()

            HStack {
                Button("Back") {
                    step = SetupStep(rawValue: step.rawValue - 1) ?? .chat
                }
                .disabled(step == .chat)

                Spacer()

                if step == .review {
                    Button {
                        Task {
                            let saved = await appState.saveConfig()
                            if saved {
                                showSavedConfirmation = true
                                isEditing = false
                            }
                        }
                    } label: {
                        if appState.isConfigLoading {
                            ProgressView()
                        } else {
                            Label("Save & Done", systemImage: "checkmark.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.isConfigLoading)
                } else {
                    Button("Next") {
                        step = SetupStep(rawValue: step.rawValue + 1) ?? .review
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { isEditing = false }
            }
        }
    }

    @ViewBuilder
    private func stepContent(config: Binding<PatrolConfig>) -> some View {
        switch step {
        case .chat:
            chatStep(config: config)
        case .days:
            daysStep(config: config)
        case .shift:
            shiftStep(config: config)
        case .message:
            messageStep(config: config)
        case .review:
            reviewStep(config: config)
        }
    }

    private func chatStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick the WhatsApp group or chat the patrol updates should go to.")
                .foregroundStyle(.secondary)

            if appState.whatsAppState?.chats.isEmpty ?? true {
                Text("No chats loaded yet. Connect WhatsApp first.")
                    .foregroundStyle(.secondary)
            } else {
                Picker("WhatsApp group or chat", selection: config.groupName) {
                    ForEach(appState.whatsAppState?.chats ?? []) { chat in
                        Text(chat.name).tag(chat.name)
                    }
                }
                .pickerStyle(.wheel)
            }
        }
    }

    private func daysStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose the days a shift starts. This repeats every week.")
                .foregroundStyle(.secondary)
            weekdayToggleRow(config: config)

            Divider()

            Text("One-time dates")
                .font(.headline)
            Text("Add a single extra shift that isn't part of your weekly routine.")
                .font(.caption)
                .foregroundStyle(.secondary)
            oneTimeDatesEditor(config: config)
        }
    }

    private func shiftStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("We'll spread the messages naturally across these hours.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                shiftCard(
                    emoji: "☀️", title: "Day", time: "8:00 AM – 8:00 PM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 8 && config.wrappedValue.schedule.shiftEndHour == 20
                ) {
                    config.schedule.shiftStartHour.wrappedValue = 8
                    config.schedule.shiftEndHour.wrappedValue = 20
                }
                shiftCard(
                    emoji: "🌙", title: "Night", time: "8:00 PM – 8:00 AM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 20 && config.wrappedValue.schedule.shiftEndHour == 8
                ) {
                    config.schedule.shiftStartHour.wrappedValue = 20
                    config.schedule.shiftEndHour.wrappedValue = 8
                }
            }
        }
    }

    private func shiftCard(emoji: String, title: String, time: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(emoji).font(.system(size: 36))
                Text(title).font(.headline)
                Text(time).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func messageStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("This exact message is sent each time. Keep it natural.")
                .foregroundStyle(.secondary)
            TextEditor(text: config.message)
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
        }
    }

    private func reviewStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Chat", value: config.wrappedValue.groupName)
                LabeledContent("Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
                LabeledContent("Message", value: config.wrappedValue.message)
                    .lineLimit(3)
            }
            .panel()

            Toggle("Send automatically", isOn: config.schedule.enabled)

            DisclosureGroup("Fine-Tune Timing (Optional)") {
                Stepper(
                    "First message earliest: \(config.schedule.firstSendMinuteMin.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMin, in: 0...59
                )
                Stepper(
                    "First message latest: \(config.schedule.firstSendMinuteMax.wrappedValue) min",
                    value: config.schedule.firstSendMinuteMax, in: 0...59
                )
                Stepper(
                    "Shortest gap: \(config.schedule.minSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.minSendIntervalMinutes, in: 75...240, step: 5
                )
                Stepper(
                    "Longest gap: \(config.schedule.maxSendIntervalMinutes.wrappedValue) min",
                    value: config.schedule.maxSendIntervalMinutes, in: 75...240, step: 5
                )
            }
        }
    }

    private func dayList(_ days: [Int]) -> String {
        guard !days.isEmpty else { return "None" }
        let names = weekdayLabels.filter { days.contains($0.value) }.map(\.short)
        return names.joined(separator: ", ")
    }

    private func weekdayToggleRow(config: Binding<PatrolConfig>) -> some View {
        HStack {
            ForEach(weekdayLabels, id: \.value) { day in
                let isOn = config.wrappedValue.schedule.activeShiftDays.contains(day.value)
                Button(day.short) {
                    if isOn {
                        config.schedule.activeShiftDays.wrappedValue.removeAll { $0 == day.value }
                    } else {
                        config.schedule.activeShiftDays.wrappedValue.append(day.value)
                    }
                }
                .buttonStyle(.bordered)
                .tint(isOn ? .accentColor : .secondary)
                .font(.caption)
            }
        }
    }

    private func oneTimeDatesEditor(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(config.wrappedValue.schedule.extraShiftDates, id: \.self) { date in
                HStack {
                    Text(date)
                    Spacer()
                    Button(role: .destructive) {
                        config.schedule.extraShiftDates.wrappedValue.removeAll { $0 == date }
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            Button {
                let today = isoDateString(Date())
                if !config.wrappedValue.schedule.extraShiftDates.contains(today) {
                    config.schedule.extraShiftDates.wrappedValue.append(today)
                    config.schedule.extraShiftDates.wrappedValue.sort()
                }
            } label: {
                Label("Add One-Time Date (Today)", systemImage: "plus")
            }
        }
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/Toronto")
        return formatter.string(from: date)
    }
}
