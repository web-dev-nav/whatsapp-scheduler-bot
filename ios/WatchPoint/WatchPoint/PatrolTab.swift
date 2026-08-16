//
//  PatrolTab.swift
//  WatchPoint
//
//  Home tab: this is where a guard spends nearly all their time during a
//  shift -- status + Start/Stop, the checkpoint map, and the checkpoint
//  list. Everything else (WhatsApp session, schedule, preferences) is one
//  tab away under Account, not competing for space here.
//

import CoreLocation
import MapKit
import SwiftUI

/// Tracks the fixed reference point a radius drag started from, so each
/// `.onChanged` can compute an absolute new position (start + cumulative
/// translation) instead of drifting from incremental deltas.
private struct RadiusDragState {
    let checkpointId: String
    let handleStartScreenPoint: CGPoint
}

struct PatrolTab: View {
    @ObservedObject var appState: AppState
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !isWhatsAppReady {
                        notReadyBanner
                    }
                    statusPanel
                    mapPanel
                    listPanel
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .keyboardDoneButton()
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Patrol")
            .onAppear { appState.requestLocationAccess() }
            .onDisappear {
                appState.saveCheckpoints()
                appState.stopWatchingLocationIfIdle()
            }
            .onChange(of: appState.currentLocation?.coordinate.latitude) { _, _ in
                // Recenter once, the first time we get a real GPS fix --
                // otherwise the map stays parked on the hardcoded default
                // (Waterloo, ON) and "my location" never actually shows up.
                // CLLocation isn't Equatable, so this keys off latitude
                // (a Double) as a stand-in for "location changed."
                guard !hasCenteredOnUser, let location = appState.currentLocation else { return }
                hasCenteredOnUser = true
                mapPosition = .region(
                    MKCoordinateRegion(
                        center: location.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
    }

    private var isWhatsAppReady: Bool {
        appState.whatsAppState?.status == "ready"
    }

    /// Surfaces a real gap: without this, a guard could run a whole patrol
    /// with no indication messages aren't actually going out.
    private var notReadyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("WhatsApp isn't connected")
                    .font(.subheadline.weight(.semibold))
                Text("Checkpoint arrivals won't send a message until this is fixed.")
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

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appState.shiftIsActive ? "Patrol Active" : "Patrol Stopped")
                        .font(.title2.weight(.semibold))
                    if let account = appState.whatsAppState?.account {
                        Text("Sending as \(account.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(appState.shiftIsActive ? "Detecting checkpoint arrivals." : "Mark checkpoints below, then start.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: appState.shiftIsActive ? "location.fill" : "location.slash")
                    .font(.title)
                    .foregroundStyle(appState.shiftIsActive ? .green : .secondary)
            }

            LabeledContent("Location Access", value: authorizationLabel(appState.locationAuthorization))
            if let location = appState.currentLocation {
                LabeledContent("GPS Accuracy", value: "\(Int(location.horizontalAccuracy)) m")
            }
            if let nearest = appState.nearestCheckpoint {
                LabeledContent("Nearest", value: nearest.checkpoint.name)
                LabeledContent("Distance", value: "\(Int(nearest.distance)) m")
            }

            Button {
                appState.shiftIsActive ? appState.stopPatrol() : appState.startPatrol()
            } label: {
                Label(appState.shiftIsActive ? "Stop Patrol" : "Start Live Patrol", systemImage: appState.shiftIsActive ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(appState.shiftIsActive ? .red : .green)
            .disabled(appState.checkpoints.isEmpty)

            if appState.checkpoints.isEmpty {
                Label("Add at least one checkpoint below before starting.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .panel()
    }

    private var mapPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Checkpoints", systemImage: "map")
                .font(.headline)
            Text("Tap the map to drop a checkpoint. Drag the white handle on a checkpoint's circle to resize it. When you enter a circle during a live patrol, the message from Setup is sent.")
                .font(.caption)
                .foregroundStyle(.secondary)

            MapReader { proxy in
                Map(position: $mapPosition) {
                    UserAnnotation()
                    ForEach(appState.checkpoints) { checkpoint in
                        let center = CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude)
                        Marker(checkpoint.name, coordinate: center)
                            .tint(.green)
                        MapCircle(center: center, radius: checkpoint.radiusMeters)
                            .foregroundStyle(.green.opacity(0.18))
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
                .onTapGesture { point in
                    if let coordinate = proxy.convert(point, from: .local) {
                        lastAddedCheckpointId = appState.addCheckpoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    }
                }
            }
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                lastAddedCheckpointId = appState.addCheckpoint()
            } label: {
                Label("Drop At My Location", systemImage: "location")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(appState.currentLocation == nil)

            if appState.currentLocation == nil {
                Label(waitingForLocationMessage, systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(waitingForLocationMessage.contains("Settings") ? .orange : .secondary)
            }

            radiusQuickEditor
        }
        .panel()
    }

    /// A radius control right next to the map for whichever checkpoint was
    /// just placed, so adjusting it doesn't require scrolling down to the
    /// list -- and its live-updating MapCircle above makes the radius
    /// change visible immediately.
    @ViewBuilder
    private var radiusQuickEditor: some View {
        if let index = appState.checkpoints.firstIndex(where: { $0.id == lastAddedCheckpointId }) {
            let checkpoint = appState.checkpoints[index]
            VStack(alignment: .leading, spacing: 6) {
                Text("Radius for \"\(checkpoint.name)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Slider(
                        value: Binding(
                            get: { appState.checkpoints[index].radiusMeters },
                            set: { appState.checkpoints[index].radiusMeters = $0 }
                        ),
                        in: 10...1000,
                        step: 10
                    )
                    Text("\(Int(checkpoint.radiusMeters)) m")
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 60, alignment: .trailing)
                }
            }
        }
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            if appState.checkpoints.isEmpty {
                Text("No checkpoints yet — tap the map above.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array($appState.checkpoints.enumerated()), id: \.element.id) { index, $checkpoint in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Name", text: $checkpoint.name)
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Button(role: .destructive) {
                                appState.deleteCheckpoint(checkpoint)
                            } label: {
                                Image(systemName: "trash")
                            }
                        }
                        Stepper("Radius \(Int(checkpoint.radiusMeters)) m", value: $checkpoint.radiusMeters, in: 10...1000, step: 10)
                        Button {
                            Task { await appState.manualTrigger(checkpoint) }
                        } label: {
                            Label("Send Test Arrival", systemImage: "paperplane")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 6)
                    if index < appState.checkpoints.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .panel()
    }

    /// A point due east of the checkpoint at distance `radiusMeters` --
    /// where the draggable resize handle sits on the circle's edge. Flat
    /// approximation (fine at the radii this app supports, max 1000m).
    private func radiusHandleCoordinate(for checkpoint: Checkpoint) -> CLLocationCoordinate2D {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(checkpoint.latitude * .pi / 180), 1)
        let deltaLongitude = checkpoint.radiusMeters / metersPerDegreeLongitude
        return CLLocationCoordinate2D(latitude: checkpoint.latitude, longitude: checkpoint.longitude + deltaLongitude)
    }

    /// Draggable handle on a checkpoint's circle edge. Dragging moves the
    /// handle; the new radius is the distance from the checkpoint's center
    /// to wherever the handle's screen position lands, converted back to a
    /// coordinate via the map's own projection (MapProxy) rather than a
    /// manual points-per-meter estimate, so it stays correct at any zoom
    /// level.
    private func radiusHandle(for checkpoint: Checkpoint, proxy: MapProxy) -> some View {
        Circle()
            .fill(.white)
            .overlay(Circle().stroke(Color.green, lineWidth: 2))
            .frame(width: 22, height: 22)
            .shadow(radius: 2)
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
                        appState.saveCheckpoints()
                    }
            )
    }

    private func authorizationLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorizedAlways: return "Always"
        case .authorizedWhenInUse: return "When in use"
        @unknown default: return "Unknown"
        }
    }

    private var waitingForLocationMessage: String {
        switch appState.locationAuthorization {
        case .denied, .restricted:
            return "Location access is off for WatchPoint. Turn it on in Settings > Privacy > Location Services > WatchPoint to place checkpoints."
        case .notDetermined:
            return "Tap \"Drop At My Location\" or reopen this tab to allow location access -- iOS should prompt you."
        default:
            return "Finding your location… this can take a few seconds outdoors, longer indoors."
        }
    }
}
