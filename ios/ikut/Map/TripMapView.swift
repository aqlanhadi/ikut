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
    /// The car the driver tapped (D34 7b): its marker is ringed and the panel shows its row. It never moves the camera.
    @State private var selectedCar: String?
    /// When a car's marker last took a tap, so the map's own tap handler can tell a tap on a car from one on the map.
    @State private var carTappedAt = Date.distantPast
    /// The convoy list starts folded on every arrival at the map; the driver opens it when they want it.
    @State private var panelExpanded = false
    @State private var reportContext: ReportContext?
    @State private var showReport = false
    /// The ask on screen now; the next one waits for it to be answered (`TripAskPlanner`).
    @State private var ask: TripAsk?
    @State private var screenAwake = ScreenAwake()
    @State private var network = NetworkStatus()
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    /// The open stop requests (and a "No answer"), from `StopService.listen`.
    @State private var stopBoard = StopBoard.empty
    /// The stop card is on top of the convoy panel only after a tap on the Pit stop button.
    @State private var stopCardOpen = false
    /// The planned stop whose "who is here" card is open (D25 piece 3b), from the panel's Next stop cell.
    @State private var arrivalStopId: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the pill at the top has shown and when, so each question goes quiet after 20 seconds.
    @State private var pillMemory = StopPillMemory()
    @State private var pillNow = Date()
    @State private var driving = DrivingDetector()
    @State private var glanceError = GlanceError()
    @State private var confirmLeave = false
    @State private var confirmEnd = false
    @State private var isWorking = false
    @State private var mapMaxX: CGFloat = 0
    @State private var mapHeight: CGFloat = 0
    /// The banner stack's height, for `mapInsets`; the sheet's own height comes from `sheetHeights`.
    @State private var topHeight: CGFloat = 0
    /// Apple's convoy sheet: on screen (it reports its own appear and dismiss), stepping aside for an exit,
    /// the action that waits for it to go, and the panel's measured heights (nil until each layout is seen).
    @State private var panelUp = false
    @State private var visible = false
    @State private var leaving = false
    @State private var afterPanel: (() -> Void)?
    @State private var foldedContent: CGFloat?
    @State private var unfoldedContent: CGFloat?
    @State private var cardContent: CGFloat?
    /// The pinned bar's own height and the sheet's bottom safe area (the home indicator's), measured.
    @State private var barContent: CGFloat?
    /// When the stop card last closed, so the system's re-pick of a detent after it is not read as a fold.
    @State private var cardClosedAt: Date?
    @State private var sheetSafeBottom: CGFloat = 34
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
    /// Kept screen on while the map is up. Until `keepAwakeAnswered` (the person chose, by the menu or the old ask)
    /// the screen stays on (`ScreenAwake.preference`).
    @AppStorage("ikut.map.keepAwake") private var keepAwake = false
    @AppStorage("ikut.map.keepAwakeAnswered") private var keepAwakeAnswered = false
    @AppStorage(AlertSettings.readAloudKey) private var readAloud = AlertSettings.readAloudDefault

    private var keepAwakeOn: Bool { ScreenAwake.preference(answered: keepAwakeAnswered, stored: keepAwake) }
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
        alerts: AlertCenter = AlertCenter(), demoCard: String? = nil, demoDriving: Bool = false, demoExpanded: Bool = false, demoError: String? = nil, demoSelected: String? = nil,
        stopService: any StopServing = StopService(),
        onExit: @escaping () -> Void = {}
    ) {
        _alerts = State(initialValue: alerts)
        self.session = session
        self.onExit = onExit
        liveServices = false
        self.stopService = stopService
        demoScreen = demoCard
        _glanceError = State(initialValue: demoError.map { var e = GlanceError(); e.show($0, cause: .send); return e } ?? GlanceError())
        _stopCardOpen = State(initialValue: demoCard != nil)
        _panelExpanded = State(initialValue: demoExpanded)
        _selectedCar = State(initialValue: demoSelected)
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
                    .animation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion), value: viewButtonsTop)
                    // The tall sheet would cut through it: fade it out, and back when the sheet folds.
                    .opacity(DrivingGlance.modeControlOpacity(panelExpanded: panelExpanded))
                    .allowsHitTesting(!panelExpanded)
                    .accessibilityHidden(panelExpanded)
                    .animation(.linear(duration: 0.2), value: panelExpanded)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: Binding(get: { visible && !panelCovered }, set: { _ in }), onDismiss: panelDismissed) {
                panelSheet
            }
            // A confirmation asked for while the sheet is away must not come up when it returns.
            .onChange(of: panelCovered) { _, covered in
                if covered { confirmLeave = false; confirmEnd = false }
            }
            .onChange(of: typeSize) { _, _ in
                foldedContent = nil
                unfoldedContent = nil
                cardContent = nil
            }
            .onChange(of: session.alwaysExplainerShowing) { _, _ in nextAsk() }
            .onChange(of: ask) { _, now in session.askShowing = now != nil }
            .onChange(of: keepAwakeOn) { _, _ in updateAwake() }
            .onChange(of: readAloud) { _, _ in alerts.readAloudChanged() }
            .onChange(of: scenePhase) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, ended in if ended { onEnded() } }
            .onAppear(perform: appear)
            .onDisappear(perform: disappear)
            .task { await model.convoy.run() }
            .task { await model.hazards.run() }
            .task { if liveServices { await network.run() } }
            .onChange(of: network.isUp, initial: true) { _, up in if liveServices { model.networkUp = up } }
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
            .onChange(of: mapInsets, initial: true) { _, insets in
                if !panelExpanded, !stopCardOpen { legalInset = DrivingGlance.legalInset(foldedSheetHeight: insets.bottom) }
                move(to: model.cameraTarget, animated: true)
            }
            .onChange(of: session.isPaused) { _, paused in if !paused { glanceError.resolve(.pause) } }
            .onChange(of: alerts.current?.id) { followApproachIfNeeded() }
            .onChange(of: model.markers.map(\.id)) { _, ids in selectedCar = CarSelection.kept(selectedCar, among: ids) }
            .task(id: approach?.id) { await watchApproach() }
            .task(id: passedText) { await expirePassed() }
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
                        Color.car(hex: overlay.colorHex),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [6, 6]))
                if let merge = overlay.merge {
                    Annotation("Join point", coordinate: merge.clCoordinate, anchor: .center) {
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
                    MapMarkerView(
                        marker: marker, cameraHeading: cameraHeading, containerWidth: mapMaxX,
                        selected: marker.id == selectedCar)
                        // Handled here, not by `Map(selection:)`: MapKit reports no second tap on the car it already has
                        // selected, so a re-tap could never clear it.
                        .onTapGesture {
                            // One tap can reach the marker twice; the second is not a re-tap.
                            guard Date().timeIntervalSince(carTappedAt) > 0.4 else { return }
                            carTappedAt = Date()
                            selectCar(CarSelection.afterTap(on: marker.id, current: selectedCar))
                        }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // A tap on the empty map clears the selection. The map's gesture also fires for a tap on a car, a moment
        // before the car's own, so it waits and stands down when a car took the tap.
        .simultaneousGesture(TapGesture().onEnded {
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                if Date().timeIntervalSince(carTappedAt) > 0.4 { selectCar(nil) }
            }
        })
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

    /// Rings a car and points the panel at its row; the camera and the follow mode stay as they are.
    private func selectCar(_ id: String?) {
        selectedCar = id
        if CarSelection.opensPanel(selected: id, shown: shownNow) { setExpanded(true) }
    }

    /// What the banner stack and the panel cover, as the map's extra safe area.
    private var mapInsets: EdgeInsets {
        let insets = MapObscuredInsets.insets(
            mapHeight: mapHeight, top: topHeight, bottom: panelUp ? PanelSheet.height(shownNow, in: sheetHeights) : 0)
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
            withAnimation(DrivingGlance.cameraAnimation(reduceMotion: reduceMotion)) { camera = next }
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
        let nothingBelowSlot = bannerSlotEmpty && passedText == nil && session.rebuilder.notice == nil && toastHidden
            && glanceError.message == nil
        return nothingBelowSlot ? topHeight : topHeight + Spacing.s
    }

    private var bannerShowing: Bool {
        if approach != nil || passedText != nil || model.catchUp != nil || model.stopApproach != nil { return true }
        guard let alert = alerts.current, alert.kind == .event else { return false }
        return !bannerHiding.contains(alert.category)
    }

    /// "Passed the debris" goes after a few seconds; held while VoiceOver runs (a new hazard or Close takes it away).
    /// Its own task: `watchApproach` is cancelled the moment the approach ends, which would clear it at once.
    private func expirePassed() async {
        guard passedText != nil,
              let hold = DrivingGlance.passedDuration(voiceOver: UIAccessibility.isVoiceOverRunning) else { return }
        try? await Task.sleep(for: hold)
        guard !Task.isCancelled else { return }
        withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { passedText = nil }
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
                withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) {
                    approach = nil
                    passedText = "Passed the \(label)"
                }
                endHazardFocus()
                return
            }
            if distance == nil, Date().timeIntervalSince(started) > 180 {
                withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { approach = nil }
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
                    glanceError.show(message, cause: .pause)
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
            if let passed = passedText { PassedBanner(text: passed) { passedText = nil } }
            if let notice = session.rebuilder.notice { RouteNoticeBanner(notice: notice) }
            ReportToastView(model: toast)
            if let message = glanceError.message { GlanceErrorBanner(message: message) { glanceError.close() } }
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
                Button("Back to lobby", systemImage: "chevron.backward") { exit { dismiss() } }
                if liveServices {
                    Toggle("Keep screen on", systemImage: "sun.max", isOn: Binding(
                        get: { keepAwakeOn },
                        set: { keepAwake = $0; keepAwakeAnswered = true }))
                    Toggle("Read alerts aloud", systemImage: "speaker.wave.2", isOn: $readAloud)
                }
                TripExitMenu(canEnd: canEnd, canLeave: canLeave, confirmEnd: $confirmEnd, confirmLeave: $confirmLeave)
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

    private struct SelectionScrollKey: Equatable { var car: String?; var expanded: Bool }

    private struct StopListenKey: Equatable {
        var carId: String?
        var routeLength: Double?
    }

    private func openStopCard() {
        withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { stopCardOpen = true }
    }

    private func closeStopCard() {
        withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { stopCardOpen = false }
    }

    // MARK: The sheet

    /// The arrival card is up: its stop is still on (a stop skipped while it is open closes it).
    private var arrivalOpen: Bool {
        arrivalStopId.map { StopArrival.target(stopId: $0, in: model.stops) != nil } ?? false
    }

    /// A stop card takes the sheet's place: the Pit stop request (opened only by a tap on the button) or the
    /// who-is-here card (the Next stop cell).
    private var cardShowing: Bool { (stopCardOpen && stopContext != nil) || (arrivalOpen && !stopCardOpen) }

    private var shownNow: PanelSheet.Shown { PanelSheet.shown(expanded: panelExpanded, cardOpen: cardShowing) }

    /// The map's height under the pills and banners, where the sheet may reach to at most (the stop pill, a
    /// banner and the trip pill always stay visible above it, at any text size).
    private var sheetRoom: CGFloat? {
        PanelSheet.room(mapHeight: mapMaxY > 0 ? mapMaxY - mapMinY : 0,
                        reserved: max(bannerShowing ? 158 : 74, topHeight + Spacing.m))
    }

    private var sheetHeights: PanelSheet.Heights {
        PanelSheet.heights(folded: foldedContent, unfolded: unfoldedContent, card: cardContent, bar: barContent,
                           room: sheetRoom)
    }

    /// Steps aside for the trip ending (the recap), an exit in progress and the lobby's Always sheet.
    private var panelCovered: Bool {
        PanelSheet.isCovered(
            ended: session.isEnded, leaving: leaving,
            explainerWants: TripSessionLogic.explainerWants(
                wanted: session.alwaysExplainerShowing, askShowing: session.askShowing))
    }

    /// The sheet's own dismissal is the signal: whatever waited for it (Back to lobby, Leave) runs now, no timer.
    private func panelDismissed() {
        panelUp = false
        session.mapSheetUp = false
        if let action = afterPanel {
            afterPanel = nil
            action()
        }
    }

    /// Runs `action` once the sheet is gone: it would otherwise stay up over the screen that comes next.
    private func exit(_ action: @escaping () -> Void) {
        switch PanelSheet.exit(sheetUp: panelUp) {
        case .now:
            action()
        case .afterDismissal:
            afterPanel = action
            leaving = true
        }
    }

    /// Apple's own sheet over the map, as on Home: drag it between short (the folded panel) and tall (the
    /// unfolded one), always up, the map above it touchable. A stop card replaces the panel in it. The
    /// report sheet, the confirmations and the asks are presented from here, since a presented sheet
    /// blocks a presentation from the map under it.
    private var panelSheet: some View {
        let shown = shownNow
        let heights = sheetHeights
        return Group {
            if shown == .card {
                ScrollView { cardView }.scrollBounceBehavior(.basedOnSize)
            } else {
                ScrollViewReader { proxy in
                    ScrollView { panel }.scrollBounceBehavior(.basedOnSize)
                        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
                        // The list is laid out after the sheet has grown, so wait for it before scrolling to the row.
                        .task(id: SelectionScrollKey(car: selectedCar, expanded: panelExpanded)) {
                            guard panelExpanded, let car = selectedCar else { return }
                            try? await Task.sleep(for: .milliseconds(350))
                            guard !Task.isCancelled else { return }
                            withAnimation(.smooth) { proxy.scrollTo(CarSelection.rowId(car), anchor: .center) }
                        }
                }
            }
        }
        .environment(\.inPanelSheet, true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheetSafeBottom = $0 }
        .background(alignment: .top) { if shown != .card { probe } }
        .onAppear {
            panelUp = true
            session.mapSheetUp = true
        }
        .presentationDetents(PanelSheet.detents(shown, in: heights), selection: Binding(
            get: { PanelSheet.detent(shown, in: heights) },
            set: {
                guard PanelSheet.acceptsDetentReport(shown: shown, sinceCardClosed: cardClosedAt.map { -$0.timeIntervalSinceNow }),
                      let tall = PanelSheet.choice($0, in: heights) else { return }
                setExpanded(tall)
            }))
        .onChange(of: cardShowing) { _, showing in if !showing { cardClosedAt = Date() } }
        .presentationDragIndicator(shown == .card ? .hidden : .visible)
        .presentationBackgroundInteraction(.enabled(upThrough: .height(shown == .card ? heights.card : heights.tall)))
        .interactiveDismissDisabled()
        .sheet(isPresented: $showReport) {
            if let reportContext {
                ReportSheet(context: reportContext, toast: toast, onReported: { _ in })
            }
        }
        .tripExitDialogs(
            confirmLeave: Binding(get: { confirmLeave && panelUp }, set: { confirmLeave = $0 }),
            confirmEnd: Binding(get: { confirmEnd && panelUp }, set: { confirmEnd = $0 }),
            leave: { run { try await session.leave(); exit(onExit) } },
            // Ending flips session.isEnded, which opens the recap (onEnded).
            end: { run { try await session.endTrip() } })
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
    }

    /// One motion for a tap and a drag: the list and the summary cross-fade in the same transaction as the
    /// sheet's own detent change (the system's spring, or a plain fade with Reduce Motion).
    private func setExpanded(_ value: Bool) {
        guard value != panelExpanded else { return }
        withAnimation(reduceMotion ? .linear(duration: 0.2) : .smooth) { panelExpanded = value }
    }

    /// The other layout, laid out out of sight, so its height is known before the first fold or unfold.
    private var probe: some View {
        ConvoyPanel(
            model: model, expanded: .constant(!panelExpanded),
            onHeight: { if panelExpanded { foldedContent = $0 } else { unfoldedContent = $0 } },
            probe: true)
            .fixedSize(horizontal: false, vertical: true)
            // Laid out but not drawn, and left out of the accessibility tree (UI tests would find its buttons twice).
            .hidden()
    }

    @ViewBuilder private var cardView: some View {
        Group {
            if stopCardOpen, let context = stopContext {
                stopCard(context)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardContent = $0 }
            } else if let id = arrivalStopId {
                StopArrivalCard(
                    model: model, stopId: id, tripId: session.tripId, frozenNow: nil, isOrganizer: session.isOrganizer,
                    leave: leaveHandler,
                    skip: skipHandler,
                    skipAll: skipAllHandler,
                    listensToAnswers: liveServices
                ) {
                    withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { arrivalStopId = nil }
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardContent = $0 }
            }
        }
    }

    private var panel: some View {
        ConvoyPanel(
            model: model, expanded: Binding(get: { panelExpanded }, set: { setExpanded($0) }),
            onNextStop: { id in withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { arrivalStopId = id } },
            selectedCar: selectedCar,
            onHeight: { if panelExpanded { unfoldedContent = $0 } else { foldedContent = $0 } })
    }

    /// Report and Pit stop: pinned to the sheet's bottom, outside the scrolling panel.
    private var actionBar: some View {
        ConvoyActionBar(
            canReport: model.myCarId != nil, stopButton: StopLogic.buttonContent(for: stopBoard),
            onReport: openReport, onStop: openStopCard, lift: PanelSheet.barLift(safeBottom: sheetSafeBottom))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { barContent = $0 }
    }

    private var leaveHandler: (@MainActor @Sendable (String) async -> StopLeave.Result)? {
        guard liveServices else { return nil }
        return { stopId in await leaveStop(stopId) }
    }

    private var skipHandler: (@MainActor @Sendable (String, Bool) async -> StopLeave.Result)? {
        guard liveServices else { return nil }
        return { stopId, skipping in await answerStop(stopId, skipping: skipping) }
    }

    private var skipAllHandler: (@MainActor @Sendable (String) async -> StopLeave.Result)? {
        guard liveServices else { return nil }
        return { stopId in await skipStopForEveryone(stopId) }
    }

    /// "Skip this stop" for everyone, the organizer's (D25 4b): the same three outcomes as Leave.
    private func skipStopForEveryone(_ stopId: String) async -> StopLeave.Result {
        do {
            let sent = try await StopLeaveService.skipForEveryone(tripId: session.tripId, stopId: stopId, userId: session.userId)
            // The route stops going through it (D25 4d); offline, once there is signal again.
            session.rebuilder.request()
            return sent ? .sent : .queued
        } catch { return .refused }
    }

    /// Leave on the who-is-here card (D25 4a): sent when the server took it, queued when it did not answer in time
    /// (no signal; Firestore keeps the write and sends it when the phone is back online), refused when the rules said no.
    private func leaveStop(_ stopId: String) async -> StopLeave.Result {
        do {
            let sent = try await StopLeaveService.leave(tripId: session.tripId, stopId: stopId, userId: session.userId)
            return sent ? .sent : .queued
        } catch { return .refused }
    }

    /// "We'll skip this stop" / "We'll stop after all" on the who-is-here card (D25 5b), same three outcomes as Leave.
    private func answerStop(_ stopId: String, skipping: Bool) async -> StopLeave.Result {
        guard let carId = model.myCarId else { return .refused }
        do {
            let sent = skipping
                ? try await StopAnswerService.skip(tripId: session.tripId, stopId: stopId, carId: carId, userId: session.userId)
                : try await StopAnswerService.undo(tripId: session.tripId, stopId: stopId, carId: carId)
            return sent ? .sent : .queued
        } catch { return .refused }
    }

    private func stopCard(_ context: StopContext) -> some View {
        StopCard(
            board: stopBoard, context: context, driving: driving.isDriving, actions: stopActions(context),
            service: stopService, demoScreen: demoScreen,
            onClose: closeStopCard
        )
    }

    /// Live actions that also tell the pill what happened (a tap on OK is confirmed there for a few seconds).
    private func stopActions(_ context: StopContext) -> StopRequestActions {
        let live = liveServices
            ? StopService.actions(
                context: context,
                onError: { _ in glanceError.actionFinished(failure: "Couldn’t reach the convoy. Try again in a moment.") },
                onSuccess: { glanceError.actionFinished(failure: nil) })
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
        withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { pillNow = Date() }
    }

    /// Feeds the driving detector once a second from this phone's own speed.
    private func watchDriving() async {
        guard liveServices else { return }
        while !Task.isCancelled {
            driving.feed(speed: model.phoneSpeed(), at: Date())
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func showStopError(_ error: Error) { showStopError(error.localizedDescription) }

    private func showStopError(_ message: String) {
        // Stays until a later action goes through or the person closes it (D34 N3).
        glanceError.show(message, cause: .send)
    }

    // MARK: Leave and end

    private var canLeave: Bool { session.isLiveMember }
    private var canEnd: Bool { session.isOrganizer && !session.isEnded }

    private func run(_ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            do { try await action(); glanceError.resolve(.send) } catch { showStopError(error) }
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
            isTracking: session.isTracking, carId: session.member?.carId, stops: session.stops,
            skipsMeetingPoint: session.skipsMeetingPoint)
    }

    private struct SessionSignature: Equatable {
        var trip: Trip?
        var car: Car?
        var positions: [String: Position]
        var isTracking: Bool
        var carId: String?
        var stops: [PlannedStop]
        var skipsMeetingPoint: Bool
    }

    private func appear() {
        visible = true
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
                notifications: access,
                asked: TripAskMemory.asked(in: askedTrip, tripId: session.tripId),
                explainerShowing: session.alwaysExplainerShowing)
            ask = next
        }
    }

    private func updateAwake() {
        guard liveServices else { return }
        screenAwake.update(
            preference: keepAwakeOn, onScreen: onScreen, tripRunning: !session.isEnded,
            appActive: scenePhase == .active)
    }

    private func disappear() {
        visible = false
        // Popped under the sheet (an edge swipe), its own dismissal may never come.
        session.mapSheetUp = false
        leaving = false
        afterPanel = nil
        onScreen = false
        ask = nil
        session.askShowing = false
        updateAwake()
        guard liveServices else { return }
        model.stop()
        alerts.stop()
    }
}
