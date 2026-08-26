//
//  SetupView.swift
//  WatchPoint
//
//  Message & schedule config: read-only overview with a 4-step wizard
//  (days -> shift -> message -> review) and live WhatsApp bubble preview.
//

import SwiftUI

enum SetupStep: Int, CaseIterable {
    case days, shift, message, review

    var title: String {
        switch self {
        case .days: return "Active Shift Days"
        case .shift: return "Shift Schedule"
        case .message: return "Automated Message"
        case .review: return "Review & Enable"
        }
    }
}

struct SetupView: View {
    @ObservedObject var appState: AppState
    @State private var step: SetupStep = .days
    @State private var isEditing = false
    @State private var draftConfig: PatrolConfig?
    @State private var showSavedConfirmation = false

    var body: some View {
        Group {
            if let config = Binding($appState.patrolConfig) {
                if isEditing, let draft = Binding($draftConfig) {
                    wizard(config: draft)
                } else {
                    overview(config: config)
                }
            } else if appState.isConfigLoading {
                ProgressView("Loading schedule configuration…")
            } else {
                ContentUnavailableView(
                    "Not Connected",
                    systemImage: "wifi.slash",
                    description: Text("Connect a WhatsApp session first.")
                )
            }
        }
        .navigationTitle("Automatic Message & Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if appState.patrolConfig == nil, !appState.adminToken.isEmpty {
                await appState.fetchConfig()
            }
        }
        .alert("Saved", isPresented: $showSavedConfirmation) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("Your automatic message and schedule have been saved successfully.")
        }
    }

    // MARK: - Read-Only Overview

    private func overview(config: Binding<PatrolConfig>) -> some View {
        Form {
            Section("Current Routine") {
                LabeledContent("Destination", value: config.wrappedValue.groupName.isEmpty ? "Not set" : config.wrappedValue.groupName)
                LabeledContent("Active Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift Timing", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
            }

            Section("Message Preview") {
                WhatsAppBubblePreview(
                    message: config.wrappedValue.message,
                    chatName: config.wrappedValue.groupName.isEmpty ? "Security Ops" : config.wrappedValue.groupName
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section {
                Toggle("Automatic Scheduled Sending", isOn: config.schedule.enabled)
                    .onChange(of: config.wrappedValue.schedule.enabled) { _, _ in
                        Haptics.impact(.light)
                        Task { await appState.saveConfig() }
                    }
            } footer: {
                Text("When enabled, the engine dispatches this message automatically across your active shift window.")
            }

            Section {
                Button {
                    Haptics.impact(.medium)
                    openEditor(with: config.wrappedValue)
                } label: {
                    Label("Edit Setup Wizard", systemImage: "pencil")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Wizard

    private func wizard(config: Binding<PatrolConfig>) -> some View {
        VStack(spacing: 0) {
            // Step Progress Bar
            VStack(spacing: 8) {
                HStack {
                    ForEach(SetupStep.allCases, id: \.self) { s in
                        Capsule()
                            .fill(s.rawValue <= step.rawValue ? Color.green : Color(.separator).opacity(0.3))
                            .frame(height: 4)
                    }
                }
                Text("Step \(step.rawValue + 1) of \(SetupStep.allCases.count): \(step.title)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepContent(config: config)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)

            Divider()

            // Navigation Bar Controls
            HStack(spacing: 12) {
                Button("Back") {
                    Haptics.selection()
                    step = SetupStep(rawValue: step.rawValue - 1) ?? .days
                }
                .buttonStyle(.bordered)
                .disabled(step == .days)

                Spacer()

                if step == .review {
                    Button {
                        Haptics.impact(.medium)
                        Task {
                            guard let draftConfig else { return }
                            let previousConfig = appState.patrolConfig
                            appState.patrolConfig = draftConfig
                            let saved = await appState.saveConfig()
                            if saved {
                                Haptics.notification(.success)
                                showSavedConfirmation = true
                                closeEditor()
                            } else {
                                Haptics.notification(.error)
                                appState.patrolConfig = previousConfig
                            }
                        }
                    } label: {
                        if appState.isConfigLoading {
                            ProgressView().tint(.white)
                        } else {
                            Label("Save & Finish", systemImage: "checkmark.circle.fill")
                                .fontWeight(.bold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(appState.isConfigLoading)
                } else {
                    Button("Next Step") {
                        Haptics.selection()
                        step = SetupStep(rawValue: step.rawValue + 1) ?? .review
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground))
        }
        .keyboardDoneButton()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    Haptics.impact(.light)
                    closeEditor()
                }
            }
        }
    }

    private func openEditor(with config: PatrolConfig) {
        draftConfig = config
        step = .days
        isEditing = true
    }

    private func closeEditor() {
        isEditing = false
        draftConfig = nil
        step = .days
    }

    @ViewBuilder
    private func stepContent(config: Binding<PatrolConfig>) -> some View {
        switch step {
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

    // MARK: - Wizard Steps

    private func daysStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Select Shift Days")
                .font(.title3.weight(.bold))
            Text("Choose the recurring days of the week when messages should be active.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            weekdayToggleRow(config: config)

            Divider().padding(.vertical, 4)

            Text("One-Time Custom Dates")
                .font(.headline)
            Text("Add single extra dates that aren't part of your regular recurring schedule.")
                .font(.caption)
                .foregroundStyle(.secondary)

            oneTimeDatesEditor(config: config)
        }
    }

    private func shiftStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shift Timing")
                .font(.title3.weight(.bold))
            Text("Messages are sent naturally throughout this shift window.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                shiftCard(
                    emoji: "☀️",
                    title: "Day Shift",
                    time: "8:00 AM – 8:00 PM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 8 && config.wrappedValue.schedule.shiftEndHour == 20
                ) {
                    Haptics.selection()
                    config.schedule.shiftStartHour.wrappedValue = 8
                    config.schedule.shiftEndHour.wrappedValue = 20
                }

                shiftCard(
                    emoji: "🌙",
                    title: "Night Shift",
                    time: "8:00 PM – 8:00 AM",
                    isSelected: config.wrappedValue.schedule.shiftStartHour == 20 && config.wrappedValue.schedule.shiftEndHour == 8
                ) {
                    Haptics.selection()
                    config.schedule.shiftStartHour.wrappedValue = 20
                    config.schedule.shiftEndHour.wrappedValue = 8
                }
            }
        }
    }

    private func shiftCard(emoji: String, title: String, time: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Text(emoji).font(.system(size: 40))
                Text(title).font(.headline.weight(.bold))
                Text(time).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(18)
            .background(isSelected ? Color.green.opacity(0.12) : Color(.secondarySystemGroupedBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.green : Color(.separator).opacity(0.4), lineWidth: isSelected ? 2 : 0.8)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func messageStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scheduled Message Content")
                .font(.title3.weight(.bold))
            Text("This text is dispatched automatically during shifts. Checkpoint GPS arrivals use their own separate Patrol Arrival Message.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: config.message)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(8)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color(.separator).opacity(0.4), lineWidth: 0.8)
                )

            WhatsAppBubblePreview(
                message: config.wrappedValue.message,
                chatName: config.wrappedValue.groupName.isEmpty ? "Security Ops" : config.wrappedValue.groupName
            )
        }
    }

    private func reviewStep(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Review Schedule")
                .font(.title3.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Destination Chat", value: config.wrappedValue.groupName)
                LabeledContent("Active Days", value: dayList(config.wrappedValue.schedule.activeShiftDays))
                LabeledContent("Shift Window", value: "\(config.wrappedValue.schedule.shiftStartHour):00 – \(config.wrappedValue.schedule.shiftEndHour):00")
            }
            .panel()

            Toggle("Enable Automated Routine", isOn: config.schedule.enabled)
                .fontWeight(.medium)

            DisclosureGroup("Advanced Timing Parameters") {
                VStack(spacing: 8) {
                    Stepper(
                        "Earliest first send: \(config.schedule.firstSendMinuteMin.wrappedValue)m after shift start",
                        value: config.schedule.firstSendMinuteMin, in: 0...59
                    )
                    Stepper(
                        "Latest first send: \(config.schedule.firstSendMinuteMax.wrappedValue)m after shift start",
                        value: config.schedule.firstSendMinuteMax, in: 0...59
                    )
                    Stepper(
                        "Shortest send gap: \(config.schedule.minSendIntervalMinutes.wrappedValue) min",
                        value: config.schedule.minSendIntervalMinutes, in: 75...240, step: 5
                    )
                    Stepper(
                        "Longest send gap: \(config.schedule.maxSendIntervalMinutes.wrappedValue) min",
                        value: config.schedule.maxSendIntervalMinutes, in: 75...240, step: 5
                    )
                }
                .font(.footnote)
                .padding(.top, 6)
            }
        }
    }

    private func dayList(_ days: [Int]) -> String {
        guard !days.isEmpty else { return "None selected" }
        let names = weekdayLabels.filter { days.contains($0.value) }.map(\.short)
        return names.joined(separator: ", ")
    }

    private func weekdayToggleRow(config: Binding<PatrolConfig>) -> some View {
        HStack(spacing: 6) {
            ForEach(weekdayLabels, id: \.value) { day in
                let isOn = config.wrappedValue.schedule.activeShiftDays.contains(day.value)
                Button {
                    Haptics.selection()
                    if isOn {
                        config.schedule.activeShiftDays.wrappedValue.removeAll { $0 == day.value }
                    } else {
                        config.schedule.activeShiftDays.wrappedValue.append(day.value)
                    }
                } label: {
                    Text(day.short)
                        .font(.subheadline.weight(isOn ? .bold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isOn ? Color.green : Color(.tertiarySystemGroupedBackground))
                        .foregroundStyle(isOn ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
    }

    private func oneTimeDatesEditor(config: Binding<PatrolConfig>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(config.wrappedValue.schedule.extraShiftDates, id: \.self) { date in
                HStack {
                    Label(date, systemImage: "calendar")
                    Spacer()
                    Button(role: .destructive) {
                        Haptics.impact(.light)
                        config.schedule.extraShiftDates.wrappedValue.removeAll { $0 == date }
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .padding(10)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }

            Button {
                Haptics.impact(.light)
                let today = isoDateString(Date())
                if !config.wrappedValue.schedule.extraShiftDates.contains(today) {
                    config.schedule.extraShiftDates.wrappedValue.append(today)
                    config.schedule.extraShiftDates.wrappedValue.sort()
                }
            } label: {
                Label("Add Today (\(isoDateString(Date())))", systemImage: "plus.circle.fill")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.top, 4)
        }
    }

    private func isoDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "America/Toronto")
        return formatter.string(from: date)
    }
}
