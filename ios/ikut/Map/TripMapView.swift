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
    /// The trip ended (organizer or server): the owner shows the recap.
    var onEnded: () -> Void = {}
    /// Alerts, the notification pre-prompt and the cars listener. Off in the demo.
    private let liveServices: Bool
    private var stopService: any StopServing = StopService()
    /// The demo can open the card on one of its screens (`IKUT_MAP_DEMO_CARD`); nil in the app.
    private var demoScreen: String?

    @State private var model: TripMapModel
    @State private var alerts = AlertCenter()
    @State private var toast = ReportToastModel()
    @State private var camera: MapCameraPosition = .automatic
    @State private var cameraHeading = 0.0
    /// The convoy list starts folded on every arrival at the map; the driver opens it when they want it.
    @State private var panelExpanded = false
    @State private var reportContext: ReportContext?
    @State private var showReport = false
    /// The ask on screen now; the next one waits for it to be answered (`TripAskPlanner`).
    @State private var ask: TripAsk?
    @State private var screenAwake = ScreenAwake()
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    /// The open stop requests (and a "No answer"), from `StopService.listen`.
    @State private var stopBoard = StopBoard.empty
    /// The stop card is on top of the convoy panel only after a tap on the Pit stop button.
    @State private var stopCardOpen = false
    /// The planned stop whose "who is here" card is open (D25 piece 3b), from the panel's Next stop cell.
    @State private var arrivalStopId: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// What the pill at the top has shown and when, so each question goes quiet after 20 seconds.
    @State private var pillMemory = StopPillMemory()
    @State private var pillNow = Date()
    @State private var driving = DrivingDetector()
    @State private var stopError: String?
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
    @State private var mapMinY: CGFloat = 0
    @State private var mapWidth: CGFloat = 0
    /// The bottom inset the map keeps as safe area: the folded panel's, so the Legal label sits
    /// above it. The rest of what covers the map goes into the camera (`cameraRoom`).
    @State private var legalInset: CGFloat = 0
    /// From the map's own camera, for `MapCameraRoom.latitudePerPointPerMeter`.
    @State private var latitudePerPointPerMeter = 0.0
    /// The hazard approach alert being followed: a pill, the hazard pinging and in view, until it's passed.
    @State private var approach: TripAlert?
    /// The camera mode to go back to once the hazard is passed.
    @State private var modeBeforeApproach: MapMode = .follow
    /// The approach folded the convoy list away; it opens again once the hazard is passed.
    @State private var unfoldAfterApproach = false
    @State private var passedText: String?
    /// Kept screen on while the map is up. `keepAwakeAnswered` is false until the first ask is answered.
    @AppStorage("ikut.map.keepAwake") private var keepAwake = false
    @AppStorage("ikut.map.keepAwakeAnswered") private var keepAwakeAnswered = false
    /// What was asked on the last trip (`TripAskMemory`), so leaving the map and coming back doesn't nag.
    @AppStorage("ikut.map.askedTrip") private var askedTrip = ""
    @Environment(\.dismiss) private var dismiss

    init(session: TripSession, onExit: @escaping () -> Void = {}, onEnded: @escaping () -> Void = {}) {
        self.session = session
        self.onExit = onExit
        self.onEnded = onEnded
        liveServices = true
        _model = State(initialValue: TripMapModel(session: session))
    }

    /// For the demo and previews: a model that is fed by hand and no live services.
    init(
        session: TripSession, model: TripMapModel, stopBoard: StopBoard = .empty,
        alerts: AlertCenter = AlertCenter(), demoCard: String? = nil, demoDriving: Bool = false, demoExpanded: Bool = false,
        stopService: any StopServing = StopService(),
        onExit: @escaping () -> Void = {}
    ) {
        _alerts = State(initialValue: alerts)
        self.session = session
        self.onExit = onExit
        liveServices = false
        self.stopService = stopService
        demoScreen = demoCard
        _stopCardOpen = State(initialValue: demoCard != nil)
        _panelExpanded = State(initialValue: demoExpanded)
        _driving = State(initialValue: DrivingDetector(isDriving: demoDriving))
        _stopBoard = State(initialValue: stopBoard)
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
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { mapWidth = $0 }
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { mapMinY = $0 }
            // The map runs on under the home indicator, past the frame seen here.
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY + $0.safeAreaInsets.bottom } action: {
                mapMaxY = $0
            }
            .overlay(alignment: .topTrailing) {
                // Below whatever is at the top (the trip pill, a banner, the stop pill), with the same gap
                // the stack keeps between its own items. Before the stack is measured: its top
                // padding, the 56 pt pill and the gap.
                MapModeControl(mode: $model.mode)
                    .padding(.top, viewButtonsTop)
                    .padding(.trailing, Spacing.m)
                    .animation(.snappy, value: viewButtonsTop)
            }
            .overlay(alignment: .bottom) {
                // The stop card is one more layer in the same stack: on top of the panel, same inset
                // and radius, opened only by a tap on the Pit stop button.
                bottomStack
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { panelMinY = $0 }
                .frame(maxHeight: maxBottomHeight, alignment: .bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showReport) {
                if let reportContext {
                    ReportSheet(context: reportContext, toast: toast, onReported: { _ in })
                }
            }
            .confirmationDialog("Leave this trip?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Leave trip", role: .destructive) { run { try await session.leave(); onExit() } }
            } message: {
                Text("Your phone stops sharing its location.")
            }
            .confirmationDialog("End the trip for everyone?", isPresented: $confirmEnd, titleVisibility: .visible) {
                // Ending flips session.isEnded, which opens the recap (onEnded).
                Button("End trip", role: .destructive) { run { try await session.endTrip() } }
            } message: {
                Text("Everyone stops sharing their location. This can't be undone.")
            }
            .alert("Get road alerts?", isPresented: asking(.roadAlerts)) {
                Button("Turn on") { answer(.roadAlerts) { _ = await alerts.requestPermission() } }
                Button("Not now", role: .cancel) { answer(.roadAlerts) }
            } message: {
                Text("ikut can warn you about debris, breakdowns and stops ahead, even while the app is in the background.")
            }
            .alert("Road alerts are off", isPresented: asking(.roadAlertsOff)) {
                Button("Open Settings") {
                    answer(.roadAlertsOff) {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            await UIApplication.shared.open(url)
                        }
                    }
                }
                Button("Not now", role: .cancel) { answer(.roadAlertsOff) }
            } message: {
                Text("Turn them on in Settings to hear about debris, breakdowns and stops ahead.")
            }
            .alert("Keep the screen on?", isPresented: asking(.keepScreenOn)) {
                Button("Keep it on") {
                    keepAwake = true
                    keepAwakeAnswered = true
                    answer(.keepScreenOn)
                }
                Button("Not now", role: .cancel) {
                    keepAwake = false
                    keepAwakeAnswered = true
                    answer(.keepScreenOn)
                }
            } message: {
                Text("So the map stays up while you drive. Uses more battery.")
            }
            .onChange(of: session.alwaysExplainerShowing) { _, _ in nextAsk() }
            .onChange(of: ask) { _, now in session.askShowing = now != nil }
            .onChange(of: keepAwake) { _, _ in updateAwake() }
            .onChange(of: scenePhase) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, ended in if ended { onEnded() } }
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .task { await model.convoy.run() }
            .task { await model.hazards.run() }
            .task(id: StopListenKey(carId: model.myCarId, routeLength: model.mainRoute?.length)) {
                guard liveServices, let context = stopContext else { return }
                for await board in StopService.listen(context: context) { stopBoard = board }
            }
            .onChange(of: stopBoard, initial: true) { old, board in
                pillMemory.observe(board.requests, now: Date())
                pillNow = Date()
                // The card closes by itself when the stop closes.
                if stopCardOpen, !old.requests.isEmpty, board.requests.isEmpty { closeStopCard() }
            }
            .task(id: pillTimerKey) { await tickPill() }
            .task { await watchDriving() }
            .task(id: model.isTracker) { if liveServices { await model.runDeviceLocation() } }
            .onChange(of: sessionSignature) { _, _ in if liveServices { model.sync() } }
            .onChange(of: model.cameraTarget) { _, target in move(to: target, animated: true) }
            // The panel folding or a banner coming and going moves the visible middle; recenter on it.
            .onChange(of: mapInsets) { _, insets in
                if !panelExpanded, !stopCardOpen { legalInset = insets.bottom }
                move(to: model.cameraTarget, animated: true)
            }
            .onChange(of: alerts.current?.id) { followApproachIfNeeded() }
            .task(id: approach?.id) { await watchApproach() }
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
                    HazardMapContent(marker: hazard, pinging: hazard.id == approach?.eventId)
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
        // MapKit centers the camera, and fits regions, inside the safe area; `cameraRoom` does the
        // same for the rest of what covers the map, so my car is in the middle of what can be seen.
        .safeAreaPadding(.bottom, legalInset)
        .onMapCameraChange { context in
            cameraHeading = context.camera.heading
            let fullHeight = mapMaxY - mapMinY
            guard fullHeight > 0, context.camera.distance > 0, context.camera.pitch == 0 else { return }
            let measured = latitudePerPointPerMeter
            latitudePerPointPerMeter = context.region.span.latitudeDelta / Double(fullHeight) / context.camera.distance
            if measured == 0 { move(to: model.cameraTarget, animated: true) }
        }
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

    /// The visible strip the camera aims at, inside the frame MapKit fits to (the map less `legalInset`).
    private var cameraRoom: MapCameraRoom {
        MapCameraRoom(
            width: mapWidth, height: max(mapMaxY - mapMinY - legalInset, 0),
            top: mapInsets.top, bottom: max(mapInsets.bottom - legalInset, 0),
            latitudePerPointPerMeter: latitudePerPointPerMeter)
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
        guard let next = Self.position(for: cameraRoom.target(target)) else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.8)) { camera = next }
        } else {
            camera = next
        }
    }

    // MARK: Top

    /// A stop request is announced by the pill at the top (and spoken), never by a banner.
    private var bannerHiding: Set<EventCategory> { [.stopRequest] }

    /// Where the view buttons start: one `Spacing.s` below the last thing showing in the top stack,
    /// the gap the stack keeps between its own items. The stack's height ends with a spacing after
    /// its always-present, zero-height banner slot when nothing shows below it, so that is taken off.
    private var viewButtonsTop: CGFloat {
        guard topHeight > 0 else { return Spacing.xs + 56 + Spacing.s }
        var bannerSlotEmpty = true
        if let alert = alerts.current {
            bannerSlotEmpty = alert.kind != .event || bannerHiding.contains(alert.category) || alert.id == approach?.id
        }
        var toastHidden = false
        if case .hidden = toast.state { toastHidden = true }
        let nothingBelowSlot = bannerSlotEmpty && passedText == nil && toastHidden && stopError == nil
        return nothingBelowSlot ? topHeight : topHeight + Spacing.s
    }

    private var bannerShowing: Bool {
        if approach != nil || passedText != nil || model.catchUp != nil || model.stopApproach != nil { return true }
        guard let alert = alerts.current, alert.kind == .event else { return false }
        return !bannerHiding.contains(alert.category)
    }

    /// A hazard approach alert (one with a distance) brings my car and the hazard into view, with
    /// its pill on top; others stay banners.
    private func followApproachIfNeeded() {
        guard let alert = alerts.current, alert.category == .hazard, alert.distance != nil,
              alert.id != approach?.id else { return }
        approach = alert
        passedText = nil
        focusHazard(alert.eventId)
    }

    /// Frames my car and the hazard, with the convoy list folded so they have the room; remembers
    /// the mode and the list to go back to.
    private func focusHazard(_ eventId: String) {
        if case .hazard = model.mode {} else { modeBeforeApproach = model.mode }
        model.mode = .hazard(id: eventId)
        if panelExpanded {
            unfoldAfterApproach = true
            panelExpanded = false
        }
    }

    /// Back to the mode and the list from before the alert, unless the driver has picked another
    /// mode since.
    private func endHazardFocus() {
        if case .hazard = model.mode { model.mode = modeBeforeApproach }
        if unfoldAfterApproach { panelExpanded = true }
        unfoldAfterApproach = false
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
                    passedText = "Passed the \(label)"
                }
                endHazardFocus()
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.snappy) { passedText = nil }
                return
            }
            if distance == nil, Date().timeIntervalSince(started) > 180 {
                withAnimation(.snappy) { approach = nil }
                endHazardFocus()
                return
            }
        }
    }

    // viewButtonsTop (above) reads what this stack shows and how it spaces it: change one, change the other.
    private var topStack: some View {
        VStack(spacing: Spacing.s) {
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
            if let stopPill, !stopCardOpen {
                StopPillView(pill: stopPill, onButton: pillTapped)
            }
            if let catchUp = model.catchUp { CatchUpPill(alert: catchUp, model: model) }
            // One pill at a time: a hazard 500 m ahead is more urgent than a stop 2 km ahead, which
            // waits underneath (it was already spoken) and comes back once the hazard is passed.
            if let stopApproach = model.stopApproach, approach == nil,
               let kind = model.stops.first(where: { $0.id == stopApproach.eventId })?.kind {
                StopApproachPill(alert: stopApproach, kind: kind, model: model)
            }
            if let approach {
                ApproachPill(alert: approach, model: model) { focusHazard(approach.eventId) }
            }
            AlertBannerView(center: alerts, hiding: bannerHiding, hidingAlertId: approach?.id)
            if let passedText { PassedBanner(text: passedText) }
            ReportToastView(model: toast)
            if let stopError { errorBanner(stopError) }
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.xs)
    }

    private var tripPill: some View {
        HStack(spacing: Spacing.m) {
            Circle()
                .fill(pillDot)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(model.tripName.isEmpty ? "Trip" : model.tripName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                // With the code when it fits, else without; the last resort truncates.
                ViewThatFits(in: .horizontal) {
                    pillSubtitle(withCode: true)
                    pillSubtitle(withCode: false)
                }
                .font(.caption)
                .foregroundStyle(Color.surfaceSecondary)
                .lineLimit(1)
                .accessibilityIdentifier("trip.pill.status")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Back to lobby", systemImage: "chevron.backward") { dismiss() }
                if liveServices {
                    Toggle("Keep screen on", systemImage: "sun.max", isOn: $keepAwake)
                        .onChange(of: keepAwake) { _, _ in keepAwakeAnswered = true }
                }
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
            .tint(GlassSurface.active ? Color.surfaceAccent : nil)
            .disabled(isWorking)
            .accessibilityLabel("Trip menu")
        }
        // Map.dc.html: 6 pt top and bottom, 16 pt before the dot, 4 pt after the 44 pt menu button,
        // so the pill is 56 pt tall in every state.
        .padding(.leading, Spacing.l)
        .padding(.trailing, Spacing.xs)
        .padding(.vertical, Spacing.tight)
        .frame(minHeight: 56)
        .glassSurface(.pill)
    }

    /// The convoy's motion ("On the move", "Arrived", ...), shown first in the pill.
    private var motion: ConvoyFormat.Motion {
        let snapshot = model.convoy.snapshot
        return ConvoyFormat.motion(
            mineArrived: snapshot.hasArrived(model.myCarId), everyoneArrived: snapshot.everyoneArrived,
            frontSpeed: snapshot.etaReference?.speed)
    }

    /// Gray once ended, amber while paused or not sharing, else live green.
    private var pillDot: Color {
        if model.isEnded { return .gray }
        return model.isTracker && !session.isPaused ? MapPalette.live : .orange
    }

    /// "On the move · Sharing location · Code K7M 2QX", the motion in green (or amber when stopped).
    private func pillSubtitle(withCode: Bool) -> Text {
        let parts = ConvoyFormat.tripPillParts(
            motion: motion, ended: model.isEnded, paused: session.isPaused, sharing: model.isTracker,
            code: model.tripCode, withCode: withCode)
        let motionText = model.isEnded ? nil : motion.text
        var text = Text("")
        for (i, part) in parts.enumerated() {
            if i > 0 { text = text + Text(" · ") }
            if i == 0, part == motionText {
                text = text + Text(part).fontWeight(.semibold)
                    .foregroundStyle(motion.isPositive ? Color.ikutPositive : Color.ikutWarning)
            } else {
                text = text + Text(part)
            }
        }
        return text
    }

    // MARK: Stops

    private var stopContext: StopContext? {
        model.stopContext(tripId: session.tripId, userId: session.userId, isOrganizer: session.isOrganizer)
    }

    private struct StopListenKey: Equatable {
        var carId: String?
        var routeLength: Double?
    }

    /// The most the card and panel may take together: the map (already below the status bar) minus
    /// what is on top, as measured (the trip pill, the stop pill when it is up, a banner), so the
    /// stop pill never sits under the expanded panel, at any text size. Never less room than the
    /// usual estimate for a pill alone or with a banner.
    private var maxBottomHeight: CGFloat? {
        guard mapHeight > 0 else { return nil }
        return mapHeight - max(bannerShowing ? 158 : 74, topHeight + Spacing.m)
    }

    private func openStopCard() {
        withAnimation(.snappy) { stopCardOpen = true }
    }

    private func closeStopCard() {
        withAnimation(.snappy) { stopCardOpen = false }
    }

    /// The panel and the stop card. The card slides up over the panel, and the panel, with everything
    /// on it, sinks and fades out in the same moment, so no button stays put under the moving card
    /// (a glass or frosted card is see-through). Closing runs the same way backwards.
    /// At accessibility text sizes the stop pill alone is taller than the room above even a folded panel,
    /// so the panel steps aside while the pill is up (at most 20 seconds) instead of covering its OK.
    private var panelAside: Bool {
        stopCardOpen || arrivalOpen || (typeSize.isAccessibilitySize && stopPill != nil)
    }

    /// The arrival card is up: its stop is still on (a stop skipped while it is open closes it).
    private var arrivalOpen: Bool {
        arrivalStopId.map { StopArrival.target(stopId: $0, in: model.stops) != nil } ?? false
    }

    private var bottomStack: some View {
        ZStack(alignment: .bottom) {
            panel
                .offset(y: panelAside ? 40 : 0)
                .opacity(panelAside ? 0 : 1)
                // Gone in a blink, so it never shows through the card on its way up.
                .animation(.easeOut(duration: 0.12), value: panelAside)
                .allowsHitTesting(!panelAside)
                .accessibilityHidden(panelAside)
            if arrivalOpen, !stopCardOpen, let id = arrivalStopId {
                StopArrivalCard(
                    model: model, stopId: id, frozenNow: nil, isOrganizer: session.isOrganizer,
                    leave: liveServices ? { stopId in await leaveStop(stopId) } : nil
                ) {
                    withAnimation(.snappy) { arrivalStopId = nil }
                }
                .padding(.horizontal, Spacing.s)
                .padding(.bottom, Spacing.s)
                .zIndex(1)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if stopCardOpen, let context = stopContext {
                stopCard(context)
                    // Above the panel for the whole of its exit too, or it would slide away behind it.
                    .zIndex(1)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var panel: some View {
        ConvoyPanel(
            model: model, expanded: $panelExpanded, canReport: model.myCarId != nil,
            stopButton: StopLogic.buttonContent(for: stopBoard),
            onReport: openReport, onStop: openStopCard,
            onNextStop: { id in withAnimation(.snappy) { arrivalStopId = id } })
    }

    /// Leave on the who-is-here card (D25 4a). True once the write is sent (offline it stays queued and the stop
    /// shows as left right away); false when the server refused it.
    private func leaveStop(_ stopId: String) async -> Bool {
        do {
            try await StopLeaveService.leave(tripId: session.tripId, stopId: stopId, userId: session.userId)
            return true
        } catch { return false }
    }

    private func stopCard(_ context: StopContext) -> some View {
        StopCard(
            board: stopBoard, context: context, driving: driving.isDriving, actions: stopActions(context),
            service: stopService, demoScreen: demoScreen,
            onClose: closeStopCard
        )
        .padding(.horizontal, Spacing.s)
        .padding(.bottom, Spacing.s)
    }

    /// Live actions that also tell the pill what happened (a tap on OK is confirmed there for a few seconds).
    private func stopActions(_ context: StopContext) -> StopRequestActions {
        let live = liveServices
            ? StopService.actions(context: context, onError: { _ in showStopError("Could not reach the convoy. Try again in a moment.") })
            : .none
        return StopRequestActions(
            ok: { eventId in
                if let request = stopBoard.requests.first(where: { $0.eventId == eventId }) {
                    pillMemory.noteOK(request, now: Date())
                    pillNow = Date()
                }
                live.ok(eventId)
            },
            close: { eventId, reason in live.close(eventId, reason) })
    }

    /// The pill's one big button: OK, for every car (the lead car and the organizer too).
    private func pillTapped(_ eventId: String) {
        guard let context = stopContext else { return }
        stopActions(context).ok(eventId)
    }

    private var stopPill: StopPill? {
        StopPillPlanner.current(
            requests: stopBoard.requests, memory: pillMemory, now: pillNow,
            distance: { model.convoy.distance(fromMyCarTo: $0) })
    }

    private struct PillTimerKey: Equatable {
        var next: Date?
        var board: StopBoard
        var memory: StopPillMemory
    }

    private var pillTimerKey: PillTimerKey {
        PillTimerKey(
            next: StopPillPlanner.nextChange(requests: stopBoard.requests, memory: pillMemory, now: pillNow),
            board: stopBoard, memory: pillMemory)
    }

    /// Sleeps until the pill's content changes by itself (20 seconds up, a confirmation done), then
    /// re-reads it.
    private func tickPill() async {
        // The demo keeps the pill on screen, so a screenshot can catch it.
        guard liveServices, let next = StopPillPlanner.nextChange(requests: stopBoard.requests, memory: pillMemory, now: Date()) else { return }
        try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) { pillNow = Date() }
    }

    /// Feeds the driving detector once a second from this phone's own speed.
    private func watchDriving() async {
        guard liveServices else { return }
        while !Task.isCancelled {
            driving.feed(speed: model.phoneSpeed(), at: Date())
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.gap)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.9), in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .accessibilityElement(children: .combine)
    }

    private func showStopError(_ error: Error) { showStopError(error.localizedDescription) }

    private func showStopError(_ message: String) {
        stopError = message
        Task {
            try? await Task.sleep(for: .seconds(6))
            stopError = nil
        }
    }

    // MARK: Leave and end

    private var canLeave: Bool { session.isLiveMember }
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
            isTracking: session.isTracking, carId: session.member?.carId, stops: session.stops)
    }

    private struct SessionSignature: Equatable {
        var trip: Trip?
        var car: Car?
        var positions: [String: Position]
        var isTracking: Bool
        var carId: String?
        var stops: [PlannedStop]
    }

    private func appear() {
        followApproachIfNeeded()
        move(to: model.cameraTarget, animated: false)
        guard liveServices else { return }
        model.regionMonitorFactory = { [session] in
            HazardRegionMonitor(
                backend: CLMonitorRegionMonitor(name: "ikutHazards\(session.tripId)"),
                notifier: LocalHazardNotifier(tripId: session.tripId),
                isForeground: { UIApplication.shared.applicationState == .active })
        }
        model.start()
        model.arrivalWriter = { tripId, stopId in try await StopLeaveService.markArrived(tripId: tripId, stopId: stopId) }
        model.startHazardAlerts(announcer: alerts, userId: session.userId)
        // Weak: the model holds `alerts` as its announcer, so a strong capture would keep every map opened.
        alerts.carDistance = { [weak model] in model?.convoy.distance(fromMyCarTo: $0) }
        alerts.start(tripId: session.tripId, myUserId: session.userId, myCarId: session.member?.carId)
        onScreen = true
        updateAwake()
        nextAsk()
    }

    /// Whether `kind` is the ask on screen; the alert closing by itself clears it (the buttons answer first).
    private func asking(_ kind: TripAsk) -> Binding<Bool> {
        Binding(get: { ask == kind }, set: { if !$0, ask == kind { ask = nil } })
    }

    /// Records the answer, runs what it asks for, then shows whichever ask is next.
    private func answer(_ kind: TripAsk, then action: @escaping () async -> Void = {}) {
        askedTrip = TripAskMemory.recording(kind, in: askedTrip, tripId: session.tripId)
        ask = nil
        Task {
            await action()
            // A beat, so the next alert isn't presented while the last is still closing.
            try? await Task.sleep(for: .milliseconds(600))
            nextAsk()
        }
    }

    private func nextAsk() {
        guard liveServices, onScreen, ask == nil else { return }
        Task {
            let access = await NotificationAccess.current()
            guard ask == nil, onScreen else { return }
            let next = TripAskPlanner.next(
                notifications: access, keepAwakeAnswered: keepAwakeAnswered,
                asked: TripAskMemory.asked(in: askedTrip, tripId: session.tripId),
                explainerShowing: session.alwaysExplainerShowing)
            ask = next
        }
    }

    private func updateAwake() {
        guard liveServices else { return }
        screenAwake.update(
            preference: keepAwake, onScreen: onScreen, tripRunning: !session.isEnded,
            appActive: scenePhase == .active)
    }

    private func disappear() {
        onScreen = false
        ask = nil
        session.askShowing = false
        updateAwake()
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
            Divider().padding(.horizontal, Spacing.s)
            button(.fit, symbol: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", label: "Fit whole convoy")
        }
        .frame(width: 44)
        .glassSurface(.control)
        .sensoryFeedback(.selection, trigger: mode)
    }

    private func button(_ target: MapMode, symbol: String, label: String) -> some View {
        Button { mode = target } label: {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(mode == target ? Color.surfaceAccent : Color.primary)
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
                .overlay(alignment: .bottomTrailing) {
                    if marker.hasArrived {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.ikutPositive, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .offset(x: 5, y: 5)
                    }
                }
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
                .foregroundStyle(marker.isMine ? Color.white
                    : marker.isPaused ? Color.secondary : (marker.isStale ? MapPalette.staleChipText : Color.primary))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Spacing.chipX)
                .padding(.vertical, Spacing.xs)
                .background {
                    // My own label is the accent blue so "Me" stands out from the white chips.
                    if marker.isMine { Capsule().fill(MapPalette.accent) } else { Capsule().fill(.regularMaterial) }
                }
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
        var text = marker.isMine ? ConvoyFormat.me : marker.name
        if marker.hasArrived { text += ", arrived" }
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
                    .padding(.horizontal, Spacing.chipX)
                    .padding(.vertical, Spacing.xs)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color(mapHex: colorHex), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chipWidth = $0 }
                    .padding(side == .trailing ? .leading : .trailing, Spacing.xl)
            }
    }
}

#Preview("Markers") {
    func marker(_ id: String, _ number: Int?, _ name: String, _ color: String, heading: Double? = 20,
                stale: Bool = false, age: String? = nil, lead: Bool = false, joining: Bool = false,
                mine: Bool = false, paused: Bool = false, arrived: Bool = false) -> MapMarker {
        MapMarker(
            id: id, number: number, name: name, colorHex: color, coordinate: MapCoordinate(latitude: 4.2, longitude: 101.26),
            heading: heading, isStale: stale, ageText: age, isLead: lead, isJoining: joining, isMine: mine,
            isPaused: paused, hasArrived: arrived)
    }
    let markers = [
        marker("c1", 1, "Aqlan’s Myvi", "#2563EB", lead: true, mine: true),
        marker("c2", 2, "Wyna’s X70", "#D9480F", heading: 200),
        marker("c3", 3, "Hafiz’s Hilux", "#0F766E", heading: 90, joining: true),
        marker("c4", 4, "Daniel’s City", "#7C3AED", stale: true, age: "2 min ago"),
        marker("c5", 5, "Siti’s Bezza", "#CA8A04", heading: nil, stale: true, paused: true),
        marker("c6", 6, "Aisha’s Ativa", "#0891B2", heading: nil, arrived: true),
        marker("c7", nil, "Old car", "#8E8E93", heading: nil),
    ]
    return VStack(alignment: .leading, spacing: Spacing.l) {
        ForEach(markers) { MapMarkerView(marker: $0, cameraHeading: 0, containerWidth: 390) }
        MergePointView(colorHex: "#0F766E", containerWidth: 390)
            .frame(width: 58)
    }
    .padding(Spacing.xl)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(Color(.systemGray5))
}

#Preview("Mode control") {
    HStack(spacing: Spacing.xl) {
        MapModeControl(mode: .constant(.follow))
        MapModeControl(mode: .constant(.fit))
        MapModeControl(mode: .constant(.free))
    }
    .padding(Spacing.xl)
    .background(Color(.systemGray5))
}
