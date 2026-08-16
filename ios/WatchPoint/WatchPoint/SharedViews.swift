//
//  SharedViews.swift
//  WatchPoint
//
//  Small subviews and helpers shared across multiple tabs/screens.
//

import SwiftUI
import UIKit

struct EventRow: View {
    let event: PatrolEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.checkpointName)
                    .font(.subheadline.weight(.semibold))
                Text(event.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(event.status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var icon: String {
        switch event.status {
        case .schedulerSucceeded: return "checkmark.circle.fill"
        case .engineNotReady: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .queued: return "tray.full.fill"
        case .sending: return "paperplane.fill"
        case .backendReceived: return "checkmark.seal.fill"
        }
    }

    private var color: Color {
        switch event.status {
        case .schedulerSucceeded: return .green
        case .engineNotReady: return .orange
        case .failed: return .red
        case .queued: return .blue
        case .sending: return .purple
        case .backendReceived: return .teal
        }
    }
}

struct WhatsAppConnectionRow: View {
    let state: WhatsAppAdminState?

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var title: String {
        guard let state else { return "Not connected to admin API" }
        switch state.status {
        case "starting": return "WhatsApp starting"
        case "qr": return "Scan QR to log in"
        case "authenticated": return "Authenticated"
        case "ready": return "WhatsApp ready"
        case "disconnected": return "Disconnected"
        case "error": return "Error"
        case "logging_out": return "Logging out"
        default: return state.status
        }
    }

    private var detail: String {
        guard let state else { return "Enter password and connect the account." }
        if let account = state.account {
            return "\(account.name) - \(state.status)"
        }
        return state.status
    }

    private var color: Color {
        switch state?.status {
        case "ready": return .green
        case "qr", "authenticated", "starting", "logging_out": return .orange
        case nil: return .secondary
        default: return .red
        }
    }
}

extension UIImage {
    convenience init?(dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}

extension View {
    func panel() -> some View {
        self
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Adds a "Done" button above the keyboard so text fields/editors can
    /// always be dismissed -- SwiftUI Forms don't do this automatically.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
    }
}
