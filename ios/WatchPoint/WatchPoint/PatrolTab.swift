//
//  PatrolTab.swift
//  WatchPoint
//
//  Home tab: primary guard interface during active shifts.
//  - Live shift status & Start/Stop patrol
//  - Interactive checkpoint map with radius editing
//  - Checkpoint list with real-time distance and test arrival trigger
//  - Message spacing & delivery cooldown countdown
//

import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// Tracks the fixed reference point a radius drag started from.
private struct RadiusDragState {
    let checkpointId: String
    let handleStartScreenPoint: CGPoint
}

/// Full-screen placement avoids gesture conflicts with the vertical scroll view.
private struct CheckpointPlacementView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition

    let checkpoints: [Checkpoint]
    let onPlace: (CLLocationCoordinate2D) -> Void

    init(
        initialPosition: MapCameraPosition,
        checkpoints: [Checkpoint],
        onPlace: @escaping (CLLocationCoordinate2D) -> Void
    ) {
        _position = State(initialValue: initialPosition)
        self.checkpoints = checkpoints
        self.onPlace = onPlace
    }

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                GeometryReader { geometry in
                    ZStack {
                        Map(position: $position, interactionModes: .all) {
                            UserAnnotation()
                            ForEach(checkpoints) { checkpoint in
                                Marker(
                                    checkpoint.name,
                                    coordinate: CLLocationCoordinate2D(
                                        latitude: checkpoint.latitude,
                                        longitude: checkpoint.longitude
                                    )
                                )
                                .tint(.green)
                            }
                        }
                        .mapControls {
                            MapUserLocationButton()
                            MapCompass()
                            MapScaleView()
                        }

                        // Center Crosshair
                        VStack(spacing: 0) {
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.2))
                                    .frame(width: 54, height: 54)

                                Image(systemName: "plus")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.green.gradient, in: Circle())
                                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                                    .shadow(color: Color.black.opacity(0.2), radius: 4)
                            }
                            Spacer()
                        }
                        .allowsHitTesting(false)

                        // Bottom Confirmation Action
                        VStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Text("Pan map to align center crosshair")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button {
                                    let centerPoint = CGPoint(
                                        x: geometry.size.width / 2,
                                        y: geometry.size.height / 2
                                    )
                                    guard let coordinate = proxy.convert(centerPoint, from: .local) else { return }
                                    Haptics.notification(.success)
                                    onPlace(coordinate)
                                    dismiss()
                                } label: {
                                    Label("Place Checkpoint Here", systemImage: "mappin.and.ellipse")
                                        .fontWeight(.semibold)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 48)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .padding(16)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .padding(16)
                        }
                    }
                }
            }
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.impact(.light)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Main Patrol Tab

struct PatrolTab: View {
    @ObservedObject var appState: AppState
    @Environment(\.openURL) private var openURL
    @Binding var selectedTab: AppTab

    @State private var mapPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 43.1394, longitude: -80.2644),
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    )
    @State private var hasCenteredOnUser = false
    @State private var lastAddedCheckpointId: String?
    @State private var radiusDrag: RadiusDragState?
    @State private var showCheckpointPlacement = false
    @State private var showStopConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // System alerts / banners
                    if let message = appState.apiCompatibilityMessage {
                        apiCompatibilityBanner(message)
                    }
                    if appState.guardReconfirmationRequired {
                        guardReconfirmationPanel
                    }
                    if !isWhatsAppReady {
                        notReadyBanner
                    }

                    // Hero Shift Status & Controls
                    heroStatusCard

                    // Quick Telemetry Row (GPS, Nearest, Spacing)
                    telemetryRow

                    // Checkpoint Map
                    mapCard

                    // Checkpoints List
                    checkpointsCard
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Patrol")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if appState.shiftIsActive {
                        HStack(spacing: 6) {
                            LivePulseIndicator(color: .green, size: 8)
                            Text("LIVE")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }
            }
            .refreshable {
                async let fetchConfig: Void = appState.fetchConfig()
                async let fetchState: Void = appState.fetchPatrolState()
                async let fetchStatus: Void = appState.fetchPatrolStatus()
                _ = await (fetchConfig, fetchState, fetchStatus)
            }
            .onAppear {
                appState.requestLocationAccess()
                appState.refreshGuardReconfirmationRequirement()
                appState.startPatrolStatusUpdates()
                Task { await appState.fetchConfig() }
            }
            .onDisappear {
                Task { await appState.saveCheckpoints() }
                appState.stopWatchingLocationIfIdle()
                appState.stopPatrolStatusUpdates()
            }
            .onChange(of: appState.currentLocation?.coordinate.latitude) { _, _ in
                guard !hasCenteredOnUser, let location = appState.currentLocation else { return }
                hasCenteredOnUser = true
                mapPosition = .region(
                    MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
            .confirmationDialog(
                "Stop Active Patrol?",
                isPresented: $showStopConfirmation,
                titleVisibility: .visible
            ) {
                Button("Stop Patrol", role: .destructive) {
                    Haptics.impact(.medium)
                    Task { await appState.stopPatrol() }
                }
                Button("Continue Patrol", role: .cancel) {}
            } message: {
                Text("This will stop automated GPS background tracking and checkpoint arrival message triggers.")
            }
            .fullScreenCover(isPresented: $showCheckpointPlacement) {
                CheckpointPlacementView(
                    initialPosition: mapPosition,
                    checkpoints: appState.checkpoints
                ) { coordinate in
                    Task {
                        let checkpointId = await appState.addCheckpoint(
                            latitude: coordinate.latitude,
                            longitude: coordinate.longitude
                        )
                        if checkpointId != nil {
                            lastAddedCheckpointId = checkpointId
                            mapPosition = .region(
                                MKCoordinateRegion(
                                    center: coordinate,
                                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                                )
                            )
                        }
                    }
                }
            }
        }
    }

    private var isWhatsAppReady: Bool {
        appState.whatsAppState?.status == "ready"
    }

    // MARK: - Hero Patrol Status Card

    private var heroStatusCard: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if appState.shiftIsActive {
                            LivePulseIndicator(color: .green, size: 9)
                            Text("PATROL ACTIVE")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.green)
                        } else {
                            Circle()
                                .fill(Color.secondary)
                                .frame(width: 8, height: 8)
                            Text("PATROL STANDBY")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(appState.shiftIsActive ? "Live GPS Tracking Active" : "Ready for Shift")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(appState.shiftIsActive ? "Detecting arrivals • Sending as \(appState.guardDisplayName)" : "\(appState.checkpoints.count) checkpoints configured")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(appState.shiftIsActive ? Color.green.opacity(0.15) : Color(.tertiarySystemGroupedBackground))
                        .frame(width: 52, height: 52)
                    Image(systemName: appState.shiftIsActive ? "location.fill" : "location.slash")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(appState.shiftIsActive ? .green : .secondary)
                }
            }

            // Start / Stop Primary Action Button
            Button {
                Haptics.impact(.medium)
                if appState.shiftIsActive {
                    showStopConfirmation = true
                } else {
                    Task { await appState.startPatrol() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: appState.shiftIsActive ? "stop.fill" : "play.fill")
                        .font(.headline)
                    Text(appState.shiftIsActive ? "End Patrol Shift" : "Start Live Patrol")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.shiftIsActive ? .red : .green)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .disabled(appState.checkpoints.isEmpty && !appState.shiftIsActive)

            if appState.checkpoints.isEmpty && !appState.shiftIsActive {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("Add at least one checkpoint below before starting patrol.")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
            }
        }
        .padding(18)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(appState.shiftIsActive ? Color.green.opacity(0.4) : Color(.separator).opacity(0.3), lineWidth: appState.shiftIsActive ? 1.5 : 0.8)
        )
        .shadow(color: appState.shiftIsActive ? Color.green.opacity(0.08) : Color.black.opacity(0.03), radius: 8, x: 0, y: 3)
    }

    // MARK: - Telemetry Summary Row

    private var telemetryRow: some View {
        HStack(spacing: 10) {
            // GPS Signal Quality
            VStack(alignment: .leading, spacing: 3) {
                Text("GPS Accuracy")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(gpsStatusColor)
                        .frame(width: 7, height: 7)
                    Text(gpsStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(gpsStatusColor)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator).opacity(0.2), lineWidth: 0.8))

            // Nearest Checkpoint
            VStack(alignment: .leading, spacing: 3) {
                Text("Nearest Point")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if let nearest = appState.nearestCheckpoint {
                    Text("\(nearest.checkpoint.name) (\(Int(nearest.distance))m)")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Text("No points")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator).opacity(0.2), lineWidth: 0.8))

            // Delivery Spacing
            VStack(alignment: .leading, spacing: 3) {
                Text("Next Send")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if minutesUntilNextSend <= 0 {
                    Text("Ready Now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                } else {
                    Text(formatCountdown(minutesUntilNextSend))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(.separator).opacity(0.2), lineWidth: 0.8))
        }
    }

    private var gpsStatusColor: Color {
        guard let location = appState.currentLocation else { return .secondary }
        if location.horizontalAccuracy <= 20 { return .green }
        if location.horizontalAccuracy <= appState.accuracyThresholdMeters { return .orange }
        return .red
    }

    private var gpsStatusText: String {
        guard let location = appState.currentLocation else { return "Searching…" }
        return "\(Int(location.horizontalAccuracy)) m"
    }

    // MARK: - Map Card

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Checkpoint Map", systemImage: "map.fill")
                    .font(.headline)
                Spacer()
                Text("\(appState.checkpoints.count) Active")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            MapReader { proxy in
                Map(position: $mapPosition) {
                    UserAnnotation()
                    ForEach(appState.checkpoints) { checkpoint in
                        let center = CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                        Marker(checkpoint.name, coordinate: center)
                            .tint(.green)
                        MapCircle(center: center, radius: checkpoint.radiusMeters)
                            .foregroundStyle(.green.opacity(0.16))
                            .stroke(.green, lineWidth: 2)
                        Annotation("", coordinate: radiusHandleCoordinate(for: checkpoint)) {
                            radiusHandle(for: checkpoint, proxy: proxy)
                        }
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
            }
            .frame(height: 250)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color(.separator).opacity(0.3), lineWidth: 0.8)
            )

            // Add Checkpoint Action Buttons
            HStack(spacing: 10) {
                Button {
                    Haptics.impact(.medium)
                    showCheckpointPlacement = true
                } label: {
                    Label("Add Anywhere", systemImage: "mappin.and.ellipse")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    Haptics.impact(.medium)
                    Task {
                        let newId = await appState.addCheckpoint()
                        if newId != nil {
                            Haptics.notification(.success)
                            lastAddedCheckpointId = newId
                        }
                    }
                } label: {
                    Label("Drop at GPS", systemImage: "location.fill")
                        .fontWeight(.medium)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.bordered)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(appState.currentLocation == nil)
            }

            radiusQuickEditor
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private var radiusQuickEditor: some View {
        if let index = appState.checkpoints.firstIndex(where: { $0.id == lastAddedCheckpointId }) {
            let checkpoint = appState.checkpoints[index]
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Radius for \"\(checkpoint.name)\"")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(checkpoint.radiusMeters)) m")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.green)
                }
                Slider(
                    value: Binding(
                        get: { appState.checkpoints[index].radiusMeters },
                        set: { appState.checkpoints[index].radiusMeters = $0 }
                    ),
                    in: 10...1000,
                    step: 10
                )
                .tint(.green)
            }
            .padding(10)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Checkpoints List Card

    private var checkpointsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Checkpoints List", systemImage: "list.bullet.circle.fill")
                    .font(.headline)
                Spacer()
                Text("\(appState.checkpoints.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if appState.checkpoints.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No checkpoints placed yet.\nTap 'Add Anywhere' or 'Drop at GPS' above.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ForEach($appState.checkpoints) { $checkpoint in
                    checkpointRow(checkpoint: $checkpoint)

                    if checkpoint.id != appState.checkpoints.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(.separator).opacity(0.3), lineWidth: 0.8)
        )
        .shadow(color: Color.black.opacity(0.02), radius: 6, x: 0, y: 2)
    }

    private func checkpointRow(checkpoint: Binding<Checkpoint>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Checkpoint Name", text: checkpoint.name)
                    .font(.subheadline.weight(.semibold))
                    .padding(8)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                Spacer()

                Button(role: .destructive) {
                    Haptics.impact(.medium)
                    lastAddedCheckpointId = lastAddedCheckpointId == checkpoint.wrappedValue.id ? nil : lastAddedCheckpointId
                    Task { await appState.deleteCheckpoint(checkpoint.wrappedValue) }
                } label: {
                    if appState.deletingCheckpointIds.contains(checkpoint.wrappedValue.id) {
                        ProgressView()
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundStyle(.red)
                            .padding(8)
                            .background(Color.red.opacity(0.1), in: Circle())
                    }
                }
                .disabled(appState.deletingCheckpointIds.contains(checkpoint.wrappedValue.id))
            }

            // Radius Stepper and Distance Info
            HStack {
                Stepper(
                    "Radius: \(Int(checkpoint.wrappedValue.radiusMeters)) m",
                    value: checkpoint.radiusMeters,
                    in: 10...1000,
                    step: 10
                )
                .font(.footnote)
            }

            // Manual Send Test Arrival Action
            HStack {
                if let userLoc = appState.currentLocation {
                    let cpLoc = CLLocation(latitude: checkpoint.wrappedValue.latitude, longitude: checkpoint.wrappedValue.longitude)
                    let dist = userLoc.distance(from: cpLoc)
                    Label("\(Int(dist))m away", systemImage: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Haptics.impact(.medium)
                    Task {
                        await appState.manualTrigger(checkpoint.wrappedValue)
                        Haptics.notification(.success)
                    }
                } label: {
                    Label("Send Test Arrival", systemImage: "paperplane.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
                .disabled(appState.deletingCheckpointIds.contains(checkpoint.wrappedValue.id))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Radius Handle Calculation & View

    private func radiusHandleCoordinate(for checkpoint: Checkpoint) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(checkpoint.latitude * .pi / 180), 1)
        let deltaLongitude = checkpoint.radiusMeters / metersPerDegreeLongitude
        return CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude + deltaLongitude)
    }

    private func radiusHandle(for checkpoint: Checkpoint, proxy: MapProxy) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.green, lineWidth: 2.5))
            .frame(width: 24, height: 24)
            .shadow(color: Color.black.opacity(0.18), radius: 3)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if radiusDrag?.checkpointId != checkpoint.id {
                            guard let startPoint = proxy.convert(radiusHandleCoordinate(for: checkpoint), to: .local) else { return }
                            radiusDrag = RadiusDragState(checkpointId: checkpoint.id, handleStartScreenPoint: startPoint)
                        }
                        guard let drag = radiusDrag, drag.checkpointId == checkpoint.id else { return }

                        let newPoint = CGPoint(
                            x: drag.handleStartScreenPoint.x + value.translation.width,
                            y: drag.handleStartScreenPoint.y + value.translation.height
                        )
                        guard let newCoordinate = proxy.convert(newPoint, from: .local) else { return }

                        let center = CLLocation(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                        let newRadius = center.distance(from: CLLocation(latitude: newCoordinate.latitude, longitude: newCoordinate.longitude))
                        guard let index = appState.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) else { return }
                        appState.checkpoints[index].radiusMeters = min(max(newRadius, 10), 1000)
                    }
                    .onEnded { _ in
                        radiusDrag = nil
                        Haptics.impact(.light)
                        Task { await appState.saveCheckpoints() }
                    }
            )
    }

    // MARK: - Banners

    private func apiCompatibilityBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Server Update Required")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Details") { selectedTab = .account }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .panel()
    }

    private var guardReconfirmationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Confirm Guard Identity", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
            Text("Still active as \(appState.guardDisplayName) on \(appState.selectedAccountName)?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Yes, Confirm") {
                    Haptics.impact(.light)
                    appState.confirmCurrentGuard()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button("Sign Out") {
                    Haptics.impact(.medium)
                    Task { await appState.signOut() }
                }
                .buttonStyle(.bordered)
            }
        }
        .panel()
    }

    private var notReadyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("WhatsApp Disconnected")
                    .font(.subheadline.weight(.semibold))
                Text("Arrival messages won't send until WhatsApp is re-linked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Fix") { selectedTab = .account }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .panel()
    }

    // MARK: - Helpers

    private var minIntervalMinutes: Int {
        appState.patrolStatus?.minMessageIntervalMinutes
            ?? appState.patrolConfig?.delivery?.minMessageIntervalMinutes
            ?? 0
    }

    private var minutesUntilNextSend: Double {
        if let status = appState.patrolStatus, status.minMessageIntervalMinutes > 0 {
            return status.minutesUntilAvailable
        }
        guard minIntervalMinutes > 0, let lastSendAt = appState.history
            .filter({ $0.status == .schedulerSucceeded })
            .map(\.timestamp)
            .max() else { return 0 }
        let remaining = (Double(minIntervalMinutes) * 60) - Date().timeIntervalSince(lastSendAt)
        return max(0, remaining / 60)
    }

    private func formatCountdown(_ minutes: Double) -> String {
        if minutes < 1 { return "< 1 min" }
        if minutes < 60 { return "\(Int(ceil(minutes)))m" }
        let hours = Int(minutes / 60)
        let mins = Int(minutes.truncatingRemainder(dividingBy: 60))
        return "\(hours)h \(mins)m"
    }
}
