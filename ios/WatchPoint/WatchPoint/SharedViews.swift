//
//  SharedViews.swift
//  WatchPoint
//
//  Small subviews, helpers, design components, and haptics shared across screens.
//

import SwiftUI
import UIKit

// MARK: - Haptic Feedback Engine

enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(type)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.prepare()
        generator.selectionChanged()
    }
}

// MARK: - Live Pulsing Indicator

struct LivePulseIndicator: View {
    var color: Color = .green
    var size: CGFloat = 10

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(isPulsing ? 1.35 : 0.8)
                .opacity(isPulsing ? 0.0 : 0.8)
                .animation(
                    Animation.easeInOut(duration: 1.4).repeatForever(autoreverses: false),
                    value: isPulsing
                )

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.6), radius: 3, x: 0, y: 0)
        }
        .onAppear {
            isPulsing = true
        }
    }
}

// MARK: - Status Badge Pill

struct StatusBadge: View {
    let title: String
    var icon: String? = nil
    var color: Color = .green

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
            }
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: Capsule())
    }
}

// MARK: - Settings Icon Badge

struct SettingsIconBadge: View {
    let systemName: String
    var backgroundColor: Color = .accentColor
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(backgroundColor.gradient)
                .frame(width: size, height: size)
            Image(systemName: systemName)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - WhatsApp Message Chat Bubble Preview

struct WhatsAppBubblePreview: View {
    @Environment(\.colorScheme) private var colorScheme
    let message: String
    var chatName: String = "Security Ops"
    var isIncoming: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(chatName, systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("WhatsApp Preview")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                if !isIncoming { Spacer(minLength: 32) }

                VStack(alignment: .trailing, spacing: 4) {
                    Text(message.isEmpty ? "No message content set" : message)
                        .font(.subheadline)
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 4) {
                        Text(Date().formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(timeColor)
                        if !isIncoming {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0.33, green: 0.67, blue: 0.93))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.05), radius: 2, y: 1)

                if isIncoming { Spacer(minLength: 32) }
            }
        }
        .padding(12)
        .background(
            colorScheme == .dark
                ? Color(red: 0.07, green: 0.10, blue: 0.12)
                : Color(.tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.separator).opacity(0.35), lineWidth: 0.8)
        )
    }

    private var bubbleBackground: Color {
        if isIncoming {
            return colorScheme == .dark
                ? Color(red: 0.13, green: 0.17, blue: 0.20)
                : Color.white
        } else {
            return colorScheme == .dark
                ? Color(red: 0.0, green: 0.36, blue: 0.29) // WhatsApp dark mode emerald (#005C4B)
                : Color(red: 0.88, green: 0.98, blue: 0.84) // WhatsApp light mode soft green (#E1F8DC)
        }
    }

    private var textColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.94, green: 0.96, blue: 0.97) // Crisp white/off-white in dark mode
        } else {
            return Color(red: 0.07, green: 0.07, blue: 0.07) // Deep readable black in light mode
        }
    }

    private var timeColor: Color {
        if colorScheme == .dark {
            return Color(red: 0.68, green: 0.76, blue: 0.80)
        } else {
            return Color(red: 0.40, green: 0.47, blue: 0.51)
        }
    }
}

// MARK: - Event Row

struct EventRow: View {
    let event: PatrolEvent

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(event.checkpointName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    Text(event.guardName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            StatusBadge(title: event.status.label, color: color)
        }
        .padding(.vertical, 2)
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

// MARK: - WhatsApp Connection Row

struct WhatsAppConnectionRow: View {
    let state: WhatsAppAdminState?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.15))
                    .frame(width: 38, height: 38)
                if isReady {
                    LivePulseIndicator(color: .green, size: 10)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusBadge(title: badgeText, color: color)
        }
        .padding(.vertical, 2)
    }

    private var isReady: Bool {
        state?.status == "ready"
    }

    private var badgeText: String {
        guard let state else { return "Disconnected" }
        switch state.status {
        case "ready": return "Ready"
        case "qr": return "Scan QR"
        case "authenticated": return "Linked"
        case "starting": return "Starting"
        case "logging_out": return "Logging Out"
        default: return state.status.capitalized
        }
    }

    private var title: String {
        guard let state else { return "Admin API Offline" }
        switch state.status {
        case "starting": return "WhatsApp Starting…"
        case "qr": return "Scan QR to Connect"
        case "authenticated": return "Session Authenticated"
        case "ready": return "WhatsApp Connected"
        case "disconnected": return "WhatsApp Disconnected"
        case "error": return "Connection Error"
        case "logging_out": return "Logging Out"
        default: return state.status.capitalized
        }
    }

    private var detail: String {
        guard let state else { return "Enter password and connect the account." }
        if let account = state.account {
            return "\(account.name) • Ready for patrol"
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

// MARK: - Fullscreen QR Modal

struct FullscreenQRView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white)
                        .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 6)

                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(24)
                }
                .frame(maxWidth: 320, maxHeight: 320)
                .padding(.horizontal, 24)

                VStack(spacing: 8) {
                    Text("Scan with WhatsApp")
                        .font(.title3.weight(.bold))
                    Text("Open WhatsApp on your phone → Settings → Linked Devices → Link a Device, then scan this code.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Link WhatsApp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.impact(.light)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - UIImage DataURL Initializer

extension UIImage {
    convenience init?(dataURL: String) {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        guard let data = Data(base64Encoded: base64) else { return nil }
        self.init(data: data)
    }
}

// MARK: - View Layout & Card Modifiers

extension View {
    /// Modern iOS card styling with subtle rounded corners and clean borders.
    func panel() -> some View {
        self
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.02), radius: 3, x: 0, y: 1)
    }

    /// Adds a "Done" button above the keyboard to dismiss any keyboard input easily.
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    Haptics.impact(.light)
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
                .fontWeight(.medium)
            }
        }
    }
}
