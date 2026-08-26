//
//  HostStatusView.swift
//  WatchPoint
//
//  Scheduler API and engine health diagnostics with round-trip latency checks.
//

import SwiftUI

private struct ReachabilityResult {
    enum Level {
        case healthy, warning, failed
    }

    let level: Level
    let detail: String
    let roundTripMs: Int?
    let checkedAt: Date
}

struct HostStatusView: View {
    @ObservedObject var appState: AppState
    @State private var adminResult: ReachabilityResult?
    @State private var engineHealth: SchedulerHealth?
    @State private var isChecking = false

    var body: some View {
        Form {
            // Version Compatibility Section
            Section("Compatibility & Engine Version") {
                LabeledContent("WatchPoint iOS", value: AppRelease.displayVersion)
                LabeledContent("Minimum iOS Required", value: engineHealth?.minimumIOSVersion ?? "Checking…")
                LabeledContent("Scheduler Engine", value: engineHealth?.engineVersion ?? "Checking…")
                LabeledContent("Required Engine", value: AppRelease.requiredEngineVersion)

                HStack {
                    Label(
                        appState.versionCompatibilityLabel,
                        systemImage: appState.versionCompatibilityLabel == "Up to date"
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(appState.versionCompatibilityLabel == "Up to date" ? .green : .orange)
                    .font(.subheadline.weight(.semibold))
                    Spacer()
                }
            }

            // Active Account Status
            Section("Active Account Details") {
                LabeledContent("Guard Identity", value: appState.guardDisplayName)
                LabeledContent("Account ID", value: currentAccountName)
                LabeledContent("WhatsApp Status", value: appState.whatsAppState?.status ?? "unknown")
                LabeledContent("Chats Loaded", value: "\(appState.whatsAppState?.chats.count ?? 0)")
            }

            // Connection & Ping Latency Section
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Admin Endpoint")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(appState.schedulerAdminBaseURL)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.primary)
                }

                resultRow(adminResult)

                Button {
                    Haptics.impact(.medium)
                    Task { await runChecks() }
                } label: {
                    if isChecking {
                        HStack {
                            Spacer()
                            ProgressView().tint(.white)
                            Spacer()
                        }
                    } else {
                        Label("Ping Server Now", systemImage: "arrow.clockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(isChecking)
            } header: {
                Text("Connection & Latency")
            } footer: {
                Text("WatchPoint uses this endpoint for guard accounts, live GPS arrivals, and patrol synchronization.")
            }

            // Server Diagnostics Metrics
            Section {
                if let health = engineHealth {
                    LabeledContent("Engine Status", value: health.status.uppercased())
                    LabeledContent("Node Runtime", value: health.nodeVersion)
                    LabeledContent("System Uptime", value: uptimeLabel(health.uptimeSeconds))
                    LabeledContent("WhatsApp Accounts", value: "\(health.connectedAccounts) / \(health.totalAccounts) connected")
                    LabeledContent("Active Sessions", value: "\(health.activeSessions)")
                } else {
                    Text("Diagnostics are loaded upon server health check.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Server Health Metrics")
            }
        }
        .navigationTitle("Test Connection")
        .navigationBarTitleDisplayMode(.inline)
        .task { await runChecks() }
    }

    private var currentAccountName: String {
        appState.adminAccounts.first(where: { $0.id == appState.selectedAdminAccountId })?.name
            ?? appState.selectedAdminAccountId
    }

    @ViewBuilder
    private func resultRow(_ result: ReachabilityResult?) -> some View {
        if let result {
            HStack(spacing: 12) {
                Image(systemName: resultIcon(result.level))
                    .font(.title3)
                    .foregroundStyle(resultColor(result.level))

                VStack(alignment: .leading, spacing: 3) {
                    Text(result.detail)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 10) {
                ProgressView()
                Text("Pinging server…")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func resultIcon(_ level: ReachabilityResult.Level) -> String {
        switch level {
        case .healthy: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func resultColor(_ level: ReachabilityResult.Level) -> Color {
        switch level {
        case .healthy: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }

    private func subtitle(for result: ReachabilityResult) -> String {
        var parts: [String] = []
        if let ms = result.roundTripMs { parts.append("\(ms) ms latency") }
        parts.append("Checked at \(result.checkedAt.formatted(date: .omitted, time: .shortened))")
        return parts.joined(separator: " • ")
    }

    private func runChecks() async {
        isChecking = true
        defer { isChecking = false }
        let adminCheck = await checkAdminHealth()
        adminResult = adminCheck.result
        engineHealth = adminCheck.health
    }

    private func checkAdminHealth() async -> (result: ReachabilityResult, health: SchedulerHealth?) {
        let start = Date()
        do {
            guard let baseURL = URL(string: appState.schedulerAdminBaseURL) else {
                return (ReachabilityResult(level: .failed, detail: "Invalid URL", roundTripMs: nil, checkedAt: Date()), nil)
            }
            let api = SchedulerAdminAPI(
                baseURL: baseURL,
                accountId: appState.selectedAdminAccountId,
                token: ""
            )
            let health = try await api.health()
            appState.recordSchedulerHealth(health)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            let isCompatible = AppRelease.isVersion(health.engineVersion, atLeast: AppRelease.requiredEngineVersion)
            return (
                ReachabilityResult(
                    level: health.status != "ok" ? .failed : isCompatible ? .healthy : .warning,
                    detail: isCompatible ? "API Operational (\(health.status))" : "API reachable — server update required",
                    roundTripMs: elapsedMs,
                    checkedAt: Date()
                ),
                health
            )
        } catch {
            return (
                ReachabilityResult(
                    level: .failed,
                    detail: error.localizedDescription,
                    roundTripMs: nil,
                    checkedAt: Date()
                ),
                nil
            )
        }
    }

    private func uptimeLabel(_ totalSeconds: Int) -> String {
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
