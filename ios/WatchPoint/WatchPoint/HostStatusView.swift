//
//  HostStatusView.swift
//  WatchPoint
//
//  Full detail about the backend this app talks to -- the admin API host
//  and the patrol webhook host -- with a live reachability check. Built
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
    @State private var webhookResult: ReachabilityResult?
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
                Text("Used for login, QR status, and schedule editing.")
            }

            Section {
                LabeledContent("URL", value: appState.webhookURL)
                resultRow(webhookResult)
            } header: {
                Text("Patrol Webhook")
            } footer: {
                Text("Checkpoint arrivals go here (n8n), not directly to the admin API. Only accepts POST, so a non-error result here just confirms the host is reachable over HTTPS -- not that a real patrol event would succeed.")
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
                Text("Engine version, uptime, and active-session count aren't available yet -- the admin API doesn't expose a health endpoint. Needs a small backend addition.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        async let admin = check(urlString: apiURL(base: appState.schedulerAdminBaseURL, path: "/api/accounts"))
        async let webhook = check(urlString: appState.webhookURL)
        adminResult = await admin
        webhookResult = await webhook
    }

    private func apiURL(base: String, path: String) -> String {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }

    private func check(urlString: String) async -> ReachabilityResult {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ReachabilityResult(ok: false, detail: "Invalid URL", roundTripMs: nil, checkedAt: Date())
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let start = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            guard let http = response as? HTTPURLResponse else {
                return ReachabilityResult(ok: false, detail: "No HTTP response", roundTripMs: elapsedMs, checkedAt: Date())
            }
            return ReachabilityResult(ok: true, detail: "HTTP \(http.statusCode)", roundTripMs: elapsedMs, checkedAt: Date())
        } catch {
            return ReachabilityResult(ok: false, detail: error.localizedDescription, roundTripMs: nil, checkedAt: Date())
        }
    }
}
