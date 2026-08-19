//
//  HostStatusView.swift
//  WatchPoint
//
//  Full detail about the single Scheduler API backend with a semantic
//  health check. Built
//  after diagnosing a real admin-Funnel TLS outage by hand with `curl`;
//  this makes that kind of check available in-app instead of the guard
//  only seeing a cryptic system alert ("a TLS error caused the secure
//  connection to fail") with no way to tell what's actually wrong.
//

import SwiftUI

/// Result of pinging a URL just to prove it's reachable over HTTPS -- not a
/// semantic health check. Any HTTP response (even a 404/405) counts as
/// reachable, since the goal is distinguishing "network/TLS is broken" from
/// "the app-level request was rejected."
private struct ReachabilityResult {
    let ok: Bool
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
            Section("This Account") {
                LabeledContent("Guard", value: appState.guardName)
                LabeledContent("Account", value: currentAccountName)
                LabeledContent("WhatsApp Status", value: appState.whatsAppState?.status ?? "unknown")
                LabeledContent("Chats Loaded", value: "\(appState.whatsAppState?.chats.count ?? 0)")
            }

            Section {
                LabeledContent("URL", value: appState.schedulerAdminBaseURL)
                resultRow(adminResult)
            } header: {
                Text("Admin API")
            } footer: {
                Text("The iOS UI uses this API for accounts, WhatsApp, schedules, checkpoints, patrol state, GPS arrivals, and history.")
            }

            Section {
                Button {
                    Task { await runChecks() }
                } label: {
                    if isChecking {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    } else {
                        Text("Check Now")
                            .frame(maxWidth: .infinity)
                    }
                }
                .disabled(isChecking)
            }

            Section {
                if let health = engineHealth {
                    LabeledContent("Status", value: health.status.capitalized)
                    LabeledContent("Engine", value: health.engineVersion)
                    LabeledContent("Node", value: health.nodeVersion)
                    LabeledContent("Uptime", value: uptimeLabel(health.uptimeSeconds))
                    LabeledContent("WhatsApp Accounts", value: "\(health.connectedAccounts) / \(health.totalAccounts) connected")
                    LabeledContent("Active Logins", value: "\(health.activeSessions)")
                } else {
                    Text("Engine diagnostics are unavailable until the Admin API health check succeeds.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Engine Diagnostics")
            }
        }
        .navigationTitle("Host & Connection")
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
            HStack {
                Image(systemName: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.ok ? .green : .red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.detail)
                        .font(.subheadline)
                    Text(subtitle(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            HStack {
                ProgressView()
                Text("Checking…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for result: ReachabilityResult) -> String {
        var parts: [String] = []
        if let ms = result.roundTripMs { parts.append("\(ms) ms") }
        parts.append("checked \(result.checkedAt.formatted(date: .omitted, time: .shortened))")
        return parts.joined(separator: " · ")
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
                return (ReachabilityResult(ok: false, detail: "Invalid URL", roundTripMs: nil, checkedAt: Date()), nil)
            }
            let api = SchedulerAdminAPI(
                baseURL: baseURL,
                accountId: appState.selectedAdminAccountId,
                token: ""
            )
            let health = try await api.health()
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            return (
                ReachabilityResult(ok: health.status == "ok", detail: "API \(health.status)", roundTripMs: elapsedMs, checkedAt: Date()),
                health
            )
        } catch {
            return (ReachabilityResult(ok: false, detail: error.localizedDescription, roundTripMs: nil, checkedAt: Date()), nil)
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
