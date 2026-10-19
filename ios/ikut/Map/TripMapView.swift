import MapKit
import SwiftUI

/// The live convoy map, following design/project/Map.dc.html: the main route in blue, joining cars'
/// own routes dashed up to where they merge, a numbered marker per car, a trip pill at the top,
/// mode controls on the right and the convoy panel (list, Joining, Report, Stop) at the bottom.
///
/// Push it with the lobby's existing session (never a second one). The Stop button opens the
/// request sheet, an open stop request shows as a card above the panel, and the pill's menu can go
/// back to the lobby, leave or end the trip; leaving and ending call `onExit` to return to Home.
struct TripMapView: View {
    let session: TripSession
    var onExit: () -> Void
    /// Alerts, the notification pre-prompt and the cars listener. Off in the demo.
    private let liveServices: Bool

    @State private var model: TripMapModel
    @State private var alerts = AlertCenter()
    @State private var toast = ReportToastModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraHeading = 0.0
    @State private var panelExpanded = true
    @State private var reportContext: ReportContext?
    @State private var showReport = false
    @State private var askAboutAlerts = false
    @State private var stopState: StopRequestState?
    @State private var stopSheet: StopSheet?
    @State private var stopError: String?
    @State private var stopCardMemory: StopCardMemory?
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var mapMaxX: CGFloat = 0
    @State private var mapHeight: CGFloat = 0
    /// The banner stack's height, and the top of the bottom panel (with any card) against the
    /// map's bottom edge, for `mapInsets`. The panel sits above the home indicator, so its own
    /// height would leave that strip out.
    @State private var topHeight: CGFloat = 0
    @State private var panelMinY: CGFloat = 0
    @State private var mapMaxY: CGFloat = 0
    /// The hazard approach alert being followed: full screen, then a pill until it's passed.
    @State private var approach: TripAlert?
    @State private var showApproach = false
    @State private var passedText: String?
    @AppStorage("ikut.map.askedAboutAlerts") private var askedAboutAlerts = false
    @Environment(\.dismiss) private var dismiss

    /// What the stop sheet is showing.
    private enum StopSheet: Identifiable {
        case request
        case suggest(StopRequestState)

        var id: String {
            switch self {
            case .request: "request"
            case .suggest(let state): "suggest-\(state.eventId)"
            }
        }
    }

    init(session: TripSession, onExit: @escaping () -> Void = {}) {
        self.session = session
        self.onExit = onExit
        liveServices = true
        _model = State(initialValue: TripMapModel(session: session))
    }

    /// For the demo and previews: a model that is fed by hand and no live services.
    init(
        session: TripSession, model: TripMapModel, stopState: StopRequestState? = nil,
        alerts: AlertCenter = AlertCenter(), onExit: @escaping () -> Void = {}
    ) {
        _alerts = State(initialValue: alerts)
        self.session = session
        self.onExit = onExit
        liveServices = false
        _stopState = State(initialValue: stopState)
        _model = State(initialValue: model)
        _camera = State(initialValue: Self.position(for: model.cameraTarget) ?? .automatic)
    }

    var body: some View {
        map
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                topStack.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxX } action: { mapMaxX = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { mapHeight = $0 }
            // The map runs on under the home indicator, past the frame seen here.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + $0.safeAreaInsets.bottom } action: {
                mapMaxY = $0
            }
            .overlay(alignment: .topTrailing) {
                // The stop card takes over the screen, and the controls would only sit under it or
                // under the banner's close button.
                if !stopCardOpen {
                    MapModeControl(mode: $model.mode)
                        .padding(.top, bannerShowing ? 156 : 76)
                        .padding(.trailing, 12)
                        .animation(.snappy, value: bannerShowing)
                }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    stopCard
                    ConvoyPanel(
                        model: model, expanded: panelBinding, canReport: model.myCarId != nil,
                        nextStop: stopState?.place,
                        onReport: openReport, onStop: { stopSheet = .request })
                        .layoutPriority(1)
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { panelMinY = $0 }
                .frame(maxHeight: maxBottomHeight, alignment: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showReport) {
                if let reportContext {
                    ReportSheet(context: reportContext, toast: toast, onReported: { _ in })
                }
            }
            .sheet(item: $stopSheet) { sheet in
                if let context = stopContext {
                    switch sheet {
                    case .request:
                        RequestStopSheet(context: context)
                    case .suggest(let state):
                        RequestStopSheet(context: context, suggestingFor: state)
                    }
                }
            }
            .confirmationDialog("Leave this trip?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave trip", role: .destructive) { run { try await session.leave(); onExit() } }
            } message: {
                Text("Your phone stops sharing its location.")
            }
            .confirmationDialog("End the trip for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End trip", role: .destructive) { run { try await session.endTrip(); onExit() } }
            } message: {
                Text("Everyone stops sharing their location. This can't be undone.")
            }
            .alert("Get road alerts?", isPresented: $askAboutAlerts) {
                Button("Turn on") { Task { await alerts.requestPermission() } }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("ikut can warn you about debris, breakdowns and stops ahead, even while the app is in the background.")
            }
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .task { await model.convoy.run() }
            .task { await model.hazards.run() }
            .task(id: StopListenKey(carId: model.myCarId, routeLength: model.mainRoute?.length)) {
                guard liveServices, let context = stopContext else { return }
                for await state in StopService.listen(context: context) { stopState = state }
            }
            .task(id: model.isTracker) { if liveServices { await model.runDeviceLocation() } }
            .onChange(of: sessionSignature) { _, _ in if liveServices { model.sync() } }
            .onChange(of: model.cameraTarget) { _, target in move(to: target, animated: true) }
            // The panel folding or a banner coming and going moves the visible middle; recenter on it.
            .onChange(of: mapInsets) { _, _ in move(to: model.cameraTarget, animated: true) }
            .onChange(of: alerts.current?.id) { followApproachIfNeeded() }
            .task(id: approach?.id) { await watchApproach() }
            .fullScreenCover(isPresented: $showApproach) {
                if let approach {
                    ApproachAlertView(alert: approach, model: model) { showApproach = false }
                }
            }
    }

    // MARK: Map

    private var map: some View {
        Map(position: $camera) {
            if model.mainRouteCoordinates.count > 1 {
                MapPolyline(coordinates: model.mainRouteCoordinates)
                    .stroke(MapPalette.routeCasing, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: model.mainRouteCoordinates)
                    .stroke(MapPalette.route, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            }
            ForEach(model.overlays) { overlay in
                let path = overlay.path.map(\.clCoordinate)
                MapPolyline(coordinates: path)
                    .stroke(.white, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: path)
                    .stroke(
                        Color(mapHex: overlay.colorHex),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [6, 6]))
                if let merge = overlay.merge {
                    Annotation("Merge point", coordinate: merge.clCoordinate, anchor: .center) {
                        MergePointView(colorHex: overlay.colorHex, containerWidth: mapMaxX)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(model.hazards.markers) { hazard in
                Annotation(hazard.label, coordinate: hazard.coordinate, anchor: .center) {
                    HazardMapContent(marker: hazard)
                        .accessibilityIdentifier("hazard.marker")
                }
                .annotationTitles(.hidden)
            }
            ForEach(model.markers) { marker in
                Annotation(marker.name, coordinate: marker.coordinate.clCoordinate, anchor: .center) {
                    MapMarkerView(marker: marker, cameraHeading: cameraHeading, containerWidth: mapMaxX)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // MapKit centers the camera, and fits regions, inside the safe area: keeping the banner and
        // panel out of it puts my car in the middle of the map that can actually be seen.
        .safeAreaPadding(.top, mapInsets.top)
        .safeAreaPadding(.bottom, mapInsets.bottom)
        .onMapCameraChange { context in cameraHeading = context.camera.heading }
        // Any pan, pinch or rotate by the user hands the camera back to them.
        .onChange(of: camera.positionedByUser) { _, byUser in
            if byUser { model.mode = MapCameraLogic.mode(afterUserGestureFrom: model.mode) }
        }
    }

    /// What the banner stack and the panel cover, as the map's extra safe area.
    private var mapInsets: EdgeInsets {
        let insets = MapObscuredInsets.insets(
            mapHeight: mapHeight, top: topHeight, bottom: panelMinY > 0 ? mapMaxY - panelMinY : 0)
        return EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: 0)
    }

    private static func position(for target: CameraTarget?) -> MapCameraPosition? {
        switch target {
        case nil:
            return nil
        case .follow(let center, let distance)?:
            return .camera(MapCamera(centerCoordinate: center.clCoordinate, distance: distance))
        case .fit(let region)?:
            return .region(MKCoordinateRegion(
                center: region.center.clCoordinate,
                span: MKCoordinateSpan(latitudeDelta: region.latitudeSpan, longitudeDelta: region.longitudeSpan)))
        }
    }

    private func move(to target: CameraTarget?, animated: Bool) {
        guard let next = Self.position(for: target) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.8)) { camera = next }
        } else {
            camera = next
        }
    }

    // MARK: Top

    private var bannerHiding: Set<EventCategory> { stopState == nil ? [] : [.stopRequest] }

    private var bannerShowing: Bool {
        if approach != nil || passedText != nil { return true }
        guard let alert = alerts.current else { return false }
        return !bannerHiding.contains(alert.category)
    }

    /// A hazard approach alert (one with a distance) takes the full screen; others stay banners.
    private func followApproachIfNeeded() {
        guard let alert = alerts.current, alert.category == .hazard, alert.distance != nil,
              alert.id != approach?.id else { return }
        approach = alert
        passedText = nil
        showApproach = true
    }

    /// Keeps the pill until the hazard is behind, then says so briefly. Gives up after a few
    /// minutes when the distance can't be worked out (e.g. this car hasn't merged).
    private func watchApproach() async {
        guard let alert = approach else { return }
        let started = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let distance = model.approachDistance(eventId: alert.eventId)
            if let distance, distance <= 0 {
                let label = model.hazards.markers.first { $0.id == alert.eventId }?.label.lowercased() ?? "hazard"
                withAnimation(.snappy) {
                    approach = nil
                    showApproach = false
                    passedText = "Passed the \(label)"
                }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.snappy) { passedText = nil }
                return
            }
            if distance == nil, Date().timeIntervalSince(started) > 180 {
                withAnimation(.snappy) { approach = nil }
                return
            }
        }
    }

    private var topStack: some View {
        VStack(spacing: 8) {
            tripPill
            if session.isPaused {
                PausedBanner(session: session, onError: { message in
                    stopError = message
                    Task {
                        try? await Task.sleep(for: .seconds(6))
                        stopError = nil
                    }
                })
            }
            // The stop card says the same thing, so its own banner would only crowd the top.
            if let approach, !showApproach {
                ApproachPill(alert: approach, model: model) { showApproach = true }
            }
            AlertBannerView(center: alerts, hiding: bannerHiding, hidingAlertId: approach?.id)
            if let passedText {
                Label(passedText, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.11).opacity(0.96), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
            ReportToastView(model: toast)
            if let stopError { errorBanner(stopError) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var tripPill: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(model.isEnded ? Color.gray : (model.isTracker ? MapPalette.live : Color.orange))
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.tripName.isEmpty ? "Trip" : model.tripName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(pillSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Back to lobby", systemImage: "chevron.backward") { dismiss() }
                if canEnd {
                    Button("End trip", systemImage: "flag.checkered", role: .destructive) { confirmEnd = true }
                }
                if canLeave {
                    Button("Leave trip", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        confirmLeave = true
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
            }
            .disabled(isWorking)
            .accessibilityLabel("Trip menu")
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }

    private var pillSubtitle: String {
        var parts = [model.isEnded ? "Trip ended" : (model.isTracker ? "Sharing location" : "Not sharing location")]
        if !model.tripCode.isEmpty { parts.append("Code \(model.tripCode)") }
        return parts.joined(separator: " · ")
    }

    // MARK: Stops

    /// The convoy list folds away while the stop card is open, so the card has the room; opening the
    /// list folds the card into its chip.
    private var panelBinding: Binding<Bool> {
        Binding(
            get: { panelExpanded && !stopCardOpen },
            set: { expanded in
                panelExpanded = expanded
                if expanded, stopCardOpen, let state = stopState {
                    var m = StopLogic.nextCardMemory(stopCardMemory, state: state)
                    m.collapsed = true
                    stopCardMemory = m
                }
            })
    }

    private var stopCardOpen: Bool {
        guard let state = stopState else { return false }
        return !StopLogic.nextCardMemory(stopCardMemory, state: state).collapsed
    }

    /// The most the card and panel may take together: the map (already below the status bar) minus
    /// the pill and a banner on top.
    /// The card's voter list scrolls to fit.
    private var maxBottomHeight: CGFloat? {
        guard mapHeight > 0 else { return nil }
        return mapHeight - (bannerShowing ? 150 : 66)
    }

    private var stopContext: StopContext? {
        model.stopContext(tripId: session.tripId, userId: session.userId, isOrganizer: session.isOrganizer)
    }

    private struct StopListenKey: Equatable {
        var carId: String?
        var routeLength: Double?
    }

    @ViewBuilder
    private var stopCard: some View {
        if let state = stopState, let context = stopContext {
            StopRequestOverlay(
                state: state, memory: $stopCardMemory,
                actions: StopService.actions(
                    context: context, state: state,
                    suggestAnother: { stopSheet = .suggest(state) },
                    onError: { showStopError($0) }))
            .padding(.horizontal, 8)
            .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .accessibilityElement(children: .combine)
    }

    private func showStopError(_ error: Error) {
        stopError = error.localizedDescription
        Task {
            try? await Task.sleep(for: .seconds(6))
            stopError = nil
        }
    }

    // MARK: Leave and end

    private var canLeave: Bool { !session.isEnded && !session.membershipLost }
    private var canEnd: Bool { session.isOrganizer && !session.isEnded }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do { try await action() } catch { showStopError(error) }
            isWorking = false
        }
    }

    // MARK: Actions and lifecycle

    private func openReport() {
        guard let context = model.reportContext(authorId: session.userId) else { return }
        reportContext = context
        showReport = true
    }

    /// Sessions fields that change what the map shows.
    private var sessionSignature: SessionSignature {
        SessionSignature(
            trip: session.trip, car: session.car, positions: session.positions,
            isTracking: session.isTracking, carId: session.member?.carId)
    }

    private struct SessionSignature: Equatable {
        var trip: Trip?
        var car: Car?
        var positions: [String: Position]
        var isTracking: Bool
        var carId: String?
    }

    private func appear() {
        move(to: model.cameraTarget, animated: false)
        guard liveServices else { return }
        model.regionMonitorFactory = { [session] in
            HazardRegionMonitor(
                backend: CLMonitorRegionMonitor(name: "ikutHazards\(session.tripId)"),
                notifier: LocalHazardNotifier(tripId: session.tripId),
                isForeground: { UIApplication.shared.applicationState == .active })
        }
        model.start()
        model.startHazardAlerts(announcer: alerts, userId: session.userId)
        alerts.start(tripId: session.tripId, myUserId: session.userId)
        if !askedAboutAlerts {
            askedAboutAlerts = true
            askAboutAlerts = true
        }
    }

    private func disappear() {
        guard liveServices else { return }
        model.stop()
        alerts.stop()
    }
}

// MARK: - Palette

enum MapPalette {
    static let accent = Color(red: 0, green: 113 / 255, blue: 227 / 255)
    static let route = Color(red: 10 / 255, green: 132 / 255, blue: 1)
    static let routeCasing = Color(red: 0, green: 96 / 255, blue: 223 / 255)
    static let live = Color(red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let warning = Color(red: 201 / 255, green: 52 / 255, blue: 0)
    /// Stale-car chip text: the warning red on light, a lighter orange on dark so it stays legible.
    static let staleChipText = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 159 / 255, blue: 10 / 255, alpha: 1)
            : UIColor(red: 176 / 255, green: 40 / 255, blue: 0, alpha: 1)
    })
}

extension Color {
    /// "#RRGGBB" (the `#` is optional); gray when malformed.
    init(mapHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = .gray
            return
        }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Mode control

/// Follow / fit buttons; neither is highlighted in free mode.
struct MapModeControl: View {
    @Binding var mode: MapMode

    var body: some View {
        VStack(spacing: 0) {
            button(.follow, symbol: "location.fill", label: "Follow my car")
            Divider().padding(.horizontal, 8)
            button(.fit, symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", label: "Fit whole convoy")
        }
        .frame(width: 44)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func button(_ target: MapMode, symbol: String, label: String) -> some View {
        Button { mode = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mode == target ? MapPalette.accent : Color.primary)
                .frame(width: 44, height: 46)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }
}

// MARK: - Markers

/// A numbered badge in the car's color, an arrow showing the heading, and a name chip.
/// Stale cars are dimmed and say how long ago they were seen; the designated lead has a small star.
struct MapMarkerView: View {
    var marker: MapMarker
    var cameraHeading: Double
    /// Width of the map, so the chip can flip to the left near the right edge.
    var containerWidth: CGFloat = 0

    @State private var markerX: CGFloat?
    @State private var chipWidth: CGFloat = 120
    private let badge: CGFloat = 32

    var body: some View {
        ZStack {
            if let heading = marker.heading {
                Wedge()
                    .fill(Color(mapHex: marker.colorHex))
                    .overlay(Wedge().stroke(.white, lineWidth: 1.5))
                    .frame(width: 14, height: 10)
                    .frame(width: 58, height: 58, alignment: .top)
                    .rotationEffect(.degrees(MapMarkerBuilder.rotation(heading: heading, cameraHeading: cameraHeading)))
            }
            Text(marker.number.map(String.init) ?? "·")
                .font(.system(.subheadline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: badge, height: badge)
                .background(Color(mapHex: marker.colorHex), in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    if marker.isLead {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0))
                            .frame(width: 14, height: 14)
                            .background(.white, in: Circle())
                            .offset(x: 5, y: -5)
                    }
                }
        }
        .frame(width: 58, height: 58)
        .opacity(marker.isStale ? 0.6 : 1)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { markerX = $0 }
        .overlay(alignment: side == .trailing ? .leading : .trailing) {
            Text(marker.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(marker.isPaused ? Color.secondary : (marker.isStale ? MapPalette.staleChipText : Color.primary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                .padding(side == .trailing ? .leading : .trailing, MapChipPlacement.gap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var side: MapChipPlacement.Side {
        MapChipPlacement.side(markerX: markerX, chipWidth: chipWidth, containerWidth: containerWidth)
    }

    private var accessibilityText: String {
        var text = marker.name
        if marker.isLead { text += ", lead" }
        if marker.isJoining { text += ", joining" }
        if marker.isPaused {
            text += ", sharing paused"
        } else if marker.isStale, let age = marker.ageText {
            text += ", last seen \(age)"
        }
        return text
    }
}

private struct Wedge: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// White dot with the joining car's color where its route meets the main route; the label hangs
/// off to the side so the dot stays on the coordinate. The label is dark-on-material with the
/// car's color as its outline, so it reads in light and dark mode.
struct MergePointView: View {
    var colorHex: String
    var containerWidth: CGFloat = 0

    @State private var dotX: CGFloat?
    @State private var chipWidth: CGFloat = 70

    private var side: MapChipPlacement.Side {
        // The dot is 18 wide, so its chip sits closer than a marker's.
        MapChipPlacement.side(markerX: dotX.map { $0 - 16 }, chipWidth: chipWidth, containerWidth: containerWidth)
    }

    var body: some View {
        Circle()
            .fill(.white)
            .overlay(Circle().strokeBorder(Color(mapHex: colorHex), lineWidth: 3))
            .frame(width: 18, height: 18)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).midX } action: { dotX = $0 }
            .overlay(alignment: side == .trailing ? .leading : .trailing) {
                Text("Merge")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(mapHex: colorHex), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                    .padding(side == .trailing ? .leading : .trailing, 24)
            }
    }
}
