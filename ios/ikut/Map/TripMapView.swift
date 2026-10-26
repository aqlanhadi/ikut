import MapKit
import SwiftUI

/// The live convoy map, following design/project/Map.dc.html: the main route in blue, joining cars'
/// own routes dashed up to where they merge, a numbered marker per car, a trip pill at the top,
/// mode controls on the right and the convoy panel (list, Joining, Report, Stop) at the bottom.
///
/// The trip screen's driving layer (D53): it draws its chrome over the host's one map (`TripScreenHost`), tells the map
/// what to draw (`TripMapSpec`) and moves its camera, and fills the one sheet with the convoy panel. The lobby puts it
/// on screen with its own session (never a second one). The Stop button opens the request sheet, and an open stop
/// request shows as a card above the panel. Pulled up to its tallest, the convoy sheet continues with the lobby's
/// journey, code, trip, options and Leave or End (`continuation`, canvas row L): there is no Back.
struct TripMapView: View {
    let session: TripSession
    /// What continues below the convoy when the sheet is pulled up: the lobby's, which owns its rows and their asks.
    private var continuation: AnyView?
    /// The pulled-up lobby asks for something that takes the screen (a confirmation, rename, Change destination): the
    /// sheet steps aside for it, as the lobby's own does.
    private var lobbyWants = false
    /// The trip ended (organizer or server): the owner shows the recap.
    var onEnded: () -> Void = {}
    /// Alerts, the notification pre-prompt and the cars listener. Off in the demo.
    private let liveServices: Bool
    private var stopService: any StopServing = StopService()
    /// The demo can open the card on one of its screens (`IKUT_MAP_DEMO_CARD`); nil in the app.
    private var demoScreen: String?

    @Environment(TripMapStage.self) private var stage
    @State private var model: TripMapModel
    @State private var alerts = AlertCenter()
    @State private var toast = ReportToastModel()
    /// The convoy list starts folded on every arrival at the map; the driver opens it, or pulls the sheet up for the
    /// lobby below it, when they want it.
    @State private var sheetShown = PanelSheet.Shown.folded
    private var panelExpanded: Bool { sheetShown.listUnfolded }
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
    @State private var mapHeight: CGFloat = 0
    /// The banner stack's height, for `mapInsets`; the sheet's own height comes from `sheetHeights`.
    @State private var topHeight: CGFloat = 0
    /// Apple's convoy sheet: on screen (it reports its own appear and dismiss), and the panel's measured heights (nil
    /// until each layout is seen).
    @State private var panelUp = false
    @State private var foldedContent: CGFloat?
    @State private var unfoldedContent: CGFloat?
    @State private var cardContent: CGFloat?
    /// The pinned bar's own height and the sheet's bottom safe area (the home indicator's), measured.
    @State private var barContent: CGFloat?
    /// One sheet motion at a time (D42): while a fold or a drag's release runs, the heights hold
    /// (`PanelSheet.settled`).
    @State private var sheetMoving = false
    @State private var sheetMotion = 0
    /// The card sheet on screen (Report, Pit stop, who is here), and the one it last showed, so its content stays
    /// while it slides down. `cardDismissing`: a card is on its way out, so the next waits for its dismissal.
    @State private var presentedCard: MapCard?
    @State private var lastCard: MapCard?
    @State private var cardDismissing = false
    /// The on-screen panel's header words, for the probes (`ConvoyPanel.headerWords`).
    @State private var panelHeader: ConvoyHeader.Text?
    /// The heights the sheet uses (`PanelSheet.settled`); nil until the first measurement.
    @State private var appliedHeights: PanelSheet.Heights?
    @State private var sheetSafeBottom: CGFloat = 34
    /// The card sheet's own bottom safe area, which its buttons hang into.
    @State private var cardSafeBottom: CGFloat = 34
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
    @State private var passedText: String?
    /// Since when each banner has been up, so the newest of "the rest" can be told (`BannerSlot`).
    @State private var bannerArrivals = BannerSlot.Arrivals()
    /// What the slot has already said, so a message coming back from waiting is not said again.
    @State private var spokenBanners = SpokenBanners()
    /// Kept screen on while the map is up. Until `keepAwakeAnswered` (the person chose, by the menu or the old ask)
    /// the screen stays on (`ScreenAwake.preference`).
    @AppStorage("ikut.map.keepAwake") private var keepAwake = false
    @AppStorage("ikut.map.keepAwakeAnswered") private var keepAwakeAnswered = false
    @AppStorage(AlertSettings.readAloudKey) private var readAloud = AlertSettings.readAloudDefault

    private var keepAwakeOn: Bool { ScreenAwake.preference(answered: keepAwakeAnswered, stored: keepAwake) }
    /// What was asked on the last trip (`TripAskMemory`), so leaving the map and coming back doesn't nag.
    @AppStorage("ikut.map.askedTrip") private var askedTrip = ""

    init(session: TripSession, continuation: AnyView? = nil, lobbyWants: Bool = false, onEnded: @escaping () -> Void = {}) {
        self.session = session
        self.continuation = continuation
        self.lobbyWants = lobbyWants
        self.onEnded = onEnded
        liveServices = true
        let model = TripMapModel(session: session)
        model.mode = TripScreenLogic.drivingEntryMode
        _model = State(initialValue: model)
    }

    /// For the demo and previews: a model that is fed by hand and no live services.
    init(
        session: TripSession, model: TripMapModel, stopBoard: StopBoard = .empty,
        alerts: AlertCenter = AlertCenter(), demoCard: String? = nil, demoReport: Bool = false, demoDriving: Bool = false, demoExpanded: Bool = false, demoError: String? = nil,
        demoApproach: TripAlert? = nil, demoPassed: String? = nil, demoToast: ReportToastModel? = nil,
        stopService: any StopServing = StopService(),
        demoPulledUp: Bool = false, continuation: AnyView? = nil
    ) {
        _alerts = State(initialValue: alerts)
        self.session = session
        self.continuation = continuation
        liveServices = false
        self.stopService = stopService
        demoScreen = demoCard
        _glanceError = State(initialValue: demoError.map { var e = GlanceError(); e.show($0, cause: .send); return e } ?? GlanceError())
        _stopCardOpen = State(initialValue: demoCard != nil && !demoReport)
        if demoReport {
            _reportContext = State(initialValue: .demo)
            _showReport = State(initialValue: true)
        }
        _sheetShown = State(initialValue: demoPulledUp ? .pulledUp : demoExpanded ? .unfolded : .folded)
        _approach = State(initialValue: demoApproach)
        _passedText = State(initialValue: demoPassed)
        _toast = State(initialValue: demoToast ?? ReportToastModel(service: DemoReportService()))
        _driving = State(initialValue: DrivingDetector(isDriving: demoDriving))
        _stopBoard = State(initialValue: stopBoard)
        _model = State(initialValue: model)
    }

    var body: some View {
        // Clear and untouchable: the host's map is under it. Only the chrome laid over it takes touches.
        Color.clear
            .allowsHitTesting(false)
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .top) {
                topStack.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
            }
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
                VStack(spacing: Spacing.s) {
                    MapModeControl(mode: $model.mode)
                    ReadAloudButton(isOn: $readAloud)
                }
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
            .preference(key: TripMapSpecKey.self, value: mapSpec)
            // The one sheet: the lobby's content becomes the convoy panel's, with its detents, in the sheet that is up.
            .preference(key: TripSheetSpecKey.self, value: TripSheetSpec(
                presented: !panelCovered, onDismiss: panelDismissed, content: AnyView(panelSheet)))
            .onChange(of: stage.reading, initial: true) { _, reading in measureCamera(reading) }
            // Any pan, pinch or rotate by the user hands the camera back to them.
            .onChange(of: stage.camera.positionedByUser) { _, byUser in
                if byUser { model.mode = MapCameraLogic.mode(afterUserGestureFrom: model.mode) }
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
                if !panelExpanded, cardNow == nil { legalInset = DrivingGlance.legalInset(foldedSheetHeight: insets.bottom) }
                move(to: model.cameraTarget, animated: true)
            }
            .onChange(of: session.isPaused) { _, paused in if !paused { glanceError.resolve(.pause) } }
            .onChange(of: alerts.current?.id) { followApproachIfNeeded() }
            .task(id: approach?.id) { await watchApproach() }
            .task(id: passedText) { await expirePassed() }
    }

    // MARK: Map

    /// What the host's map draws for driving. MapKit centers the camera, and fits regions, inside the map's safe area
    /// (`legalInset`); `cameraRoom` does the same for the rest of what covers the map, so my car is in the middle of
    /// what can be seen.
    private var mapSpec: TripMapSpec {
        TripMapSpec(
            input: .driving(route: model.mainRouteCoordinates, overlays: model.overlays,
                            hazards: model.hazards.markers, cars: model.markers),
            style: TripMapStyle(pingingEventId: approach?.eventId),
            bottomPadding: legalInset)
    }

    /// The map's height (it runs under the status bar, `mapAbove`), from the host's map.
    private var mapFullHeight: CGFloat { mapMaxY - stage.mapFrame.minY }

    /// How far above this layer's top the map starts: the one map runs under the status bar for the lobby and for
    /// driving alike, while this layer (and the banner stack it measures) starts under it.
    private var mapAbove: CGFloat { max(mapMinY - stage.mapFrame.minY, 0) }

    /// Reads the map's scale off its own camera once a move has ended; the first reading aims the camera again.
    private func measureCamera(_ reading: TripCameraReading?) {
        guard let reading else { return }
        let fullHeight = mapFullHeight
        guard fullHeight > 0, reading.distance > 0, reading.pitch == 0 else { return }
        let measured = latitudePerPointPerMeter
        latitudePerPointPerMeter = reading.latitudeDelta / Double(fullHeight) / reading.distance
        if measured == 0 { move(to: model.cameraTarget, animated: true) }
    }

    /// What the banner stack and the panel cover, as the map's extra safe area.
    private var mapInsets: EdgeInsets {
        let insets = MapObscuredInsets.insets(
            mapHeight: mapHeight, top: topHeight, bottom: panelUp ? PanelSheet.covered(shown: shownNow, in: sheetHeights, card: presentedCard == nil ? nil : cardHeight) : 0)
        return EdgeInsets(top: insets.top, leading: 0, bottom: insets.bottom, trailing: 0)
    }

    /// The visible strip the camera aims at, inside the frame MapKit fits to (the map less `legalInset`).
    private var cameraRoom: MapCameraRoom {
        MapCameraRoom(
            width: mapWidth, height: max(mapFullHeight - legalInset, 0),
            top: mapInsets.top + mapAbove, bottom: max(mapInsets.bottom - legalInset, 0),
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
            withAnimation(DrivingGlance.cameraAnimation(reduceMotion: reduceMotion)) { stage.camera = next }
        } else {
            stage.camera = next
        }
    }

    // MARK: Top

    /// A stop request is announced by the pill at the top (and spoken), never by a banner.
    private var bannerHiding: Set<EventCategory> { [.stopRequest] }

    /// Where the view buttons start: one `Spacing.s` below the banner slot when it shows something, the gap the
    /// stack keeps between the pill and the slot. The stack's height ends with a spacing after the always-present,
    /// zero-height slot when it is empty, so nothing is added then.
    private var viewButtonsTop: CGFloat {
        guard topHeight > 0 else { return Spacing.xs + 56 + Spacing.s }
        return bannerSlot.shown == nil ? topHeight : topHeight + Spacing.s
    }

    /// The alert centre's banner, when it is drawn: an event that is not a stop request and not the approach pill.
    private var alertBannerAlert: TripAlert? {
        guard let alert = alerts.current, alert.kind == .event, !bannerHiding.contains(alert.category),
              alert.id != approach?.id else { return nil }
        return alert
    }

    /// The planned stop coming up, with its kind, when its pill can be drawn.
    private var stopApproachKind: PlannedStopKind? {
        guard let stopApproach = model.stopApproach else { return nil }
        return model.stops.first(where: { $0.id == stopApproach.eventId })?.kind
    }

    /// Every message that wants the slot, with an identity that changes when it is another message of the same
    /// kind. The identity is also what the message announces under, so `SpokenBanners` keeps it while it waits.
    private var bannerPresent: [BannerSlot.Message: String] {
        BannerSlot.present(.init(
            hazardApproachId: approach?.id,
            stopPillId: stopCardOpen ? nil : stopPill?.id,
            stopApproachId: stopApproachKind == nil ? nil : model.stopApproach?.id,
            toast: toast.state, passedText: passedText, error: glanceError.message, paused: session.isPaused,
            catchUpId: model.catchUp?.id, alertBannerId: alertBannerAlert?.id,
            routeNoticeText: session.rebuilder.notice?.text))
    }

    private var bannerSlot: BannerSlot.Result {
        BannerSlot.resolve(present: Set(bannerPresent.keys), arrivals: bannerArrivals.dates)
    }

    private var bannerShowing: Bool { bannerSlot.shown != nil }

    /// "Passed the debris" goes after a few seconds; held while VoiceOver runs (a new hazard or Close takes it away).
    /// Its own task: `watchApproach` is cancelled the moment the approach ends, which would clear it at once.
    private func expirePassed() async {
        guard liveServices, passedText != nil,
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
        if !PanelSheet.expanded(panelExpanded, after: .approaching) { setShown(.folded) }
    }

    /// Back to the mode from before the alert, unless the driver has picked another mode since. The list stays as
    /// it is (#344): it does not unfold again by itself while the car is moving.
    private func endHazardFocus(_ moment: PanelSheet.HazardMoment) {
        if case .hazard = model.mode { model.mode = modeBeforeApproach }
        if !PanelSheet.expanded(panelExpanded, after: moment) { setShown(.folded) }
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
                endHazardFocus(.passed)
                return
            }
            if distance == nil, Date().timeIntervalSince(started) > 180 {
                withAnimation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion)) { approach = nil }
                endHazardFocus(.gaveUp)
                return
            }
        }
    }

    // viewButtonsTop (above) reads what the slot shows and how the stack spaces it: change one, change the other.
    private var topStack: some View {
        VStack(spacing: Spacing.s) {
            // Without Back the pill runs from the leading edge, with the same side gap on both sides.
            tripPill
            bannerSlotView
        }
        .padding(.horizontal, Spacing.m)
        .padding(.top, Spacing.xs)
    }

    /// The one message under the pill (`BannerSlot` picks it). Zero-height while empty, always in the hierarchy so
    /// the transitions run and it adds nothing to the stack. Stays at one place, under the pill.
    private var bannerSlotView: some View {
        ZStack(alignment: .top) {
            switch bannerSlot.shown {
            case .hazardApproach:
                if let approach { ApproachPill(alert: approach, model: model) { focusHazard(approach.eventId) } }
            case .stopPill:
                if let stopPill, !stopCardOpen {
                    StopPillView(pill: stopPill, onButton: pillTapped).glanceTransition(edge: .top)
                }
            case .stopApproach:
                if let stopApproach = model.stopApproach, let kind = stopApproachKind {
                    StopApproachPill(alert: stopApproach, kind: kind, model: model)
                }
            case .toast:
                ReportToastView(model: toast, haptics: false)
            case .passed:
                if let passed = passedText { PassedBanner(text: passed) { passedText = nil } }
            case .paused:
                PausedBanner(session: session, onError: { message in
                    glanceError.show(message, cause: .pause)
                })
                .glanceTransition(edge: .top)
            case .catchUp:
                if let catchUp = model.catchUp { CatchUpPill(alert: catchUp, model: model) }
            case .alertBanner:
                AlertBannerView(center: alerts, hiding: bannerHiding, hidingAlertId: approach?.id)
            case .routeNotice:
                if let notice = session.rebuilder.notice { RouteNoticeBanner(notice: notice) }
            case .error:
                if let message = glanceError.message { GlanceErrorBanner(message: message) { glanceError.close() } }
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity)
        .environment(\.spokenBanners, spokenBanners)
        // Always mounted, unlike the toast: a report made while another message has the slot still gives its haptics.
        .reportHaptics(toast)
        .animation(DrivingGlance.animation(.snappy, reduceMotion: reduceMotion), value: bannerSlot.shown)
        .onChange(of: bannerPresent, initial: true) { _, present in
            bannerArrivals.update(present: present, now: Date())
            spokenBanners.keep(Set(present.values))
        }
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
        }
        .overlay(alignment: .topTrailing) {
            // MapBannerSlot.dc.html frame i: an error is held behind another message.
            if bannerSlot.errorHeld {
                Circle().fill(Color.red).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                    .padding(.top, 2).padding(.trailing, 6)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("trip.pill.errorDot")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(bannerSlot.errorHeld ? "error waiting" : "")
        // 6 pt top and bottom, 16 pt either side, so the pill is 56 pt tall in every state.
        .padding(.horizontal, Spacing.l)
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

    /// What the card sheet over the convoy sheet shows.
    enum MapCard: Equatable, Identifiable {
        case report, stopRequest, arrival(String)
        /// One identity for all: a card changing into another swaps in the sheet that is up, never dismisses and re-presents.
        var id: String { "card" }
    }

    private struct StopListenKey: Equatable {
        var carId: String?
        var routeLength: Double?
    }

    private func openStopCard() { stopCardOpen = true }

    private func closeStopCard() { stopCardOpen = false }

    private func closeArrivalCard() { arrivalStopId = nil }

    /// The card sheet's state follows what is wanted (`cardNow`). One card at a time: a new one waits for the one on
    /// its way out to be gone (`cardDismissed`), and a card changing into another (a stop closes, its arrival card
    /// follows) swaps in the sheet that is up.
    private func syncCard(_ want: MapCard?) {
        if let want { lastCard = want }
        let before = PanelSheet.CardSheet(presented: presentedCard != nil, dismissing: cardDismissing)
        applyCard(PanelSheet.cardSync(before, wanted: want != nil), wanting: want)
    }

    private func cardDismissed() {
        let before = PanelSheet.CardSheet(presented: presentedCard != nil, dismissing: cardDismissing)
        applyCard(PanelSheet.cardDismissed(before, wanted: cardNow != nil), wanting: cardNow)
    }

    private func applyCard(_ next: PanelSheet.CardSheet, wanting want: MapCard?) {
        let startedDismissing = next.dismissing && !cardDismissing
        presentedCard = next.presented ? (presentedCard ?? want) : nil
        cardDismissing = next.dismissing
        guard startedDismissing else { return }
        // A dismissal the sheet never reports must not hold the next card back.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PanelSheet.cardDismissFallback))
            if cardDismissing { cardDismissed() }
        }
    }

    // MARK: The sheet

    /// The arrival card is up: its stop is still on (a stop skipped while it is open closes it).
    private var arrivalOpen: Bool {
        arrivalStopId.map { StopArrival.target(stopId: $0, in: model.stops) != nil } ?? false
    }

    /// The card wanted over the convoy sheet: Report, the Pit stop request (opened only by a tap on the button) or the
    /// who-is-here card (the Next stop cell).
    private var cardNow: MapCard? {
        if showReport, reportContext != nil { return .report }
        if stopCardOpen, stopContext != nil { return .stopRequest }
        if arrivalOpen, let id = arrivalStopId { return .arrival(id) }
        return nil
    }

    private var shownNow: PanelSheet.Shown { sheetShown }

    /// The lobby continues below the convoy now (`PanelSheet.showsContinuation`).
    private var continuationShown: Bool { continuation != nil && PanelSheet.showsContinuation(sheetShown, in: sheetHeights) }

    /// The card sheet's detent: its content's height, up to the room under the pills.
    private var cardHeight: CGFloat { PanelSheet.cardHeight(content: cardContent, room: sheetRoom) }

    /// The map's height under the pills and banners, where the sheet may reach to at most (the stop pill, a
    /// banner and the trip pill always stay visible above it, at any text size).
    private var sheetRoom: CGFloat? {
        PanelSheet.room(mapHeight: mapMaxY > 0 ? mapMaxY - mapMinY : 0,
                        reserved: max(bannerShowing ? 158 : 74, topHeight + Spacing.m))
    }

    /// What the layouts measure now.
    private var measuredHeights: PanelSheet.Heights {
        PanelSheet.heights(folded: foldedContent, unfolded: unfoldedContent, bar: barContent,
                           room: sheetRoom)
    }

    /// What the sheet uses: the measured heights, held while it moves (`PanelSheet.settled`).
    private var sheetHeights: PanelSheet.Heights { appliedHeights ?? measuredHeights }

    /// Takes the measured heights the sheet may use now; a change at rest (a car joins, the text grows) moves the
    /// sheet with its usual motion.
    private func resettle() {
        let next = PanelSheet.settled(appliedHeights, measured: measuredHeights, moving: sheetMoving)
        guard next != appliedHeights else { return }
        if appliedHeights == nil {
            appliedHeights = next
        } else {
            withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { appliedHeights = next }
        }
    }

    /// Runs `change` as one sheet motion (`Motion.sheet`, a fade with Reduce Motion): the detent, the content swap and
    /// the camera's re-centre in one transaction, with the heights held until it is over.
    private func moveSheet(_ change: @escaping () -> Void) {
        sheetMotion &+= 1
        let motion = sheetMotion
        sheetMoving = true
        animateSheet(motion, change)
    }

    private func animateSheet(_ motion: Int, _ change: () -> Void) {
        withAnimation(Motion.sheet(reduceMotion: reduceMotion), completionCriteria: .removed) {
            change()
        } completion: {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(PanelSheet.settleAfterMotion))
                endSheetMotion(motion)
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PanelSheet.motionLongest))
            endSheetMotion(motion)
        }
    }

    private func endSheetMotion(_ motion: Int) {
        guard motion == sheetMotion, sheetMoving else { return }
        sheetMoving = false
        resettle()
    }

    /// Steps aside for the trip ending (the recap), the lobby's Always sheet and what the pulled-up lobby asks for.
    private var panelCovered: Bool {
        PanelSheet.isCovered(
            ended: session.isEnded,
            explainerWants: TripSessionLogic.explainerWants(
                wanted: session.alwaysExplainerShowing, askShowing: session.askShowing),
            lobbyWants: lobbyWants)
    }

    /// The convoy sheet went (the trip ended, the Always sheet): the card went with it.
    private func panelDismissed() {
        panelUp = false
        session.mapSheetUp = false
        // The card went with the convoy sheet; it comes back with it if it is still wanted.
        presentedCard = nil
        cardDismissing = PanelSheet.cardsGone.dismissing
    }

    /// Apple's own sheet over the map, as on Home: drag it between short (the folded panel) and tall (the
    /// unfolded one), always up, the map above it touchable. A stop card replaces the panel in it. The
    /// report sheet, the confirmations and the asks are presented from here, since a presented sheet
    /// blocks a presentation from the map under it.
    private var panelSheet: some View {
        let shown = shownNow
        let heights = sheetHeights
        // Pulled up, the lobby continues below the unfolded panel, which stays where it was (canvas row L).
        return ScrollView {
            VStack(spacing: 0) {
                panel
                if continuationShown, let continuation {
                    continuation.transition(.opacity)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
            .sheetBottomBar { actionBar }
        .environment(\.inPanelSheet, true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheetSafeBottom = $0 }
        .background(alignment: .top) { probes }
        .onAppear {
            panelUp = true
            session.mapSheetUp = true
        }
        .presentationDetents(TripScreenLogic.Sheet.driving(heights).detents, selection: Binding(
            get: { PanelSheet.detent(shown, in: heights) },
            set: {
                guard let chosen = PanelSheet.choice($0, in: heights) else { return }
                setShown(chosen)
            }))
        .onChange(of: measuredHeights, initial: true) { resettle() }
        .onChange(of: continuationShown, initial: true) { _, shown in stage.pulledUp = shown }
        .onChange(of: cardNow, initial: true) { _, want in syncCard(want) }
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: TripScreenLogic.Sheet.driving(heights).touchableUpThrough))
        .interactiveDismissDisabled()
        .sheet(item: Binding(get: { presentedCard }, set: cardSetByTheSystem), onDismiss: cardDismissed) { _ in
            cardSheet
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
    }

    /// One motion for a tap, a drag and the hazard fold: the list and the summary cross-fade in the same transaction
    /// as the sheet's own detent change, with the heights held until it is over.
    private func setShown(_ value: PanelSheet.Shown) {
        guard value != sheetShown else { return }
        moveSheet { sheetShown = value }
    }

    /// The header's fold and unfold: unfolding a pulled-up sheet leaves it pulled up.
    private func setExpanded(_ value: Bool) {
        guard value != panelExpanded else { return }
        setShown(value ? .unfolded : .folded)
    }

    /// Both layouts, laid out out of sight with the on-screen header's words, so both heights are known before a fold
    /// or unfold and never change because of one: the on-screen panel is not measured, since while it cross-fades it
    /// lays out the outgoing summary or list under the incoming one.
    private var probes: some View {
        ZStack(alignment: .top) {
            probe(unfolded: false)
            probe(unfolded: true)
        }
        // Laid out but not drawn, and left out of the accessibility tree (UI tests would find its buttons twice).
        .hidden()
    }

    private func probe(unfolded: Bool) -> some View {
        ConvoyPanel(
            model: model, expanded: .constant(unfolded),
            onHeight: { if unfolded { unfoldedContent = $0 } else { foldedContent = $0 } },
            probe: true, headerWords: panelHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A swipe down on a card (Report allows one) closes what it showed; the sheet going away because we changed
    /// `presentedCard` ourselves has nothing left to clear.
    private func cardSetByTheSystem(_ card: MapCard?) {
        guard card == nil, presentedCard != nil else { return }
        presentedCard = nil
        cardDismissing = true
        showReport = false
        stopCardOpen = false
        arrivalStopId = nil
    }

    /// The card sheet: slides up from the bottom over the convoy sheet (the system's own, no glass or material of its
    /// own), as tall as its content up to the room under the pills, with the map above it still touchable.
    private var cardSheet: some View {
        let card = cardNow ?? lastCard
        return ScrollView {
            cardView(card)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { cardContent = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .environment(\.inPanelSheet, true)
        // The gap under the buttons equals the gap beside them (the card's 20 pt), as on the convoy sheet's bar.
        .environment(\.cardActionLift, PanelSheet.barLift(safeBottom: cardSafeBottom, gap: Spacing.block))
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { cardSafeBottom = $0 }
        .presentationDetents([.height(cardHeight)])
        .presentationDragIndicator(.hidden)
        .presentationBackgroundInteraction(.enabled)
        // The stop cards have no swipe down (#123): their body scrolls, and Close is the way out.
        .interactiveDismissDisabled(card != .report)
    }

    @ViewBuilder private func cardView(_ card: MapCard?) -> some View {
        switch card {
        case .report:
            if let reportContext { ReportSheet(context: reportContext, toast: toast, onReported: { _ in }) }
        case .stopRequest:
            if let context = stopContext { stopCard(context) }
        case .arrival(let id):
            StopArrivalCard(
                model: model, stopId: id, tripId: session.tripId, frozenNow: nil, isOrganizer: session.isOrganizer,
                leave: leaveHandler,
                skip: skipHandler,
                skipAll: skipAllHandler,
                listensToAnswers: liveServices
            ) {
                closeArrivalCard()
            }
        case nil:
            EmptyView()
        }
    }

    private var panel: some View {
        ConvoyPanel(
            model: model, expanded: Binding(get: { panelExpanded }, set: { setExpanded($0) }),
            onNextStop: { id in arrivalStopId = id },
            onHeader: { panelHeader = $0 })
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

    // MARK: Actions and lifecycle

    private func openReport() {
        guard let context = liveServices ? model.reportContext(authorId: session.userId) : .demo else { return }
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
        followApproachIfNeeded()
        // From the lobby the camera flies from the whole route to your car; on the screen's first frame it is placed.
        move(to: model.cameraTarget, animated: TripScreenLogic.animatesEntry(mapHasCamera: stage.hasCamera))
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
        // Popped, or another screen pushed over the trip: no convoy sheet any more.
        session.mapSheetUp = false
        stage.pulledUp = false
        onScreen = false
        ask = nil
        session.askShowing = false
        updateAwake()
        guard liveServices else { return }
        model.stop()
        alerts.stop()
    }
}
