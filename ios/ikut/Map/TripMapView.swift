import MapKit
import OSLog
import SwiftUI

/// The card sheet's comings and goings (`log stream --predicate 'category == "CardSheet"'`): what a flaky UI test needs.
let cardSheetLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "CardSheet")

/// The live convoy map, following design/project/Map.dc.html: the main route in blue, joining cars'
/// own routes dashed up to where they merge, a numbered marker per car, a trip pill at the top,
/// mode controls on the right and the convoy panel (list, Joining, Report, Stop) at the bottom.
///
/// The trip screen's driving layer (D53): it draws its chrome over the host's one map (`TripScreenHost`), tells the map
/// what to draw (`TripMapSpec`) and moves its camera, and fills the one sheet with the convoy panel. The trip screen's
/// model puts it on screen with the open trip's one session (never a second one). The Stop button opens the request sheet, and an open stop
/// request shows as a card above the panel. Pulled up to its tallest, the convoy sheet continues with the lobby's
/// journey, code, trip, options and Leave or End as system list sections (`continuation`, canvas row L): there is no Back.
struct TripMapView: View {
    let session: TripSession
    /// What continues below the convoy when the sheet is pulled up: the lobby's, which owns its rows and their asks.
    /// It is handed where my car is, for the journey's stops ahead.
    private var continuation: PulledUpSheet?
    /// On top of the convoy sheet at every height: the lobby's "You're no longer in this trip" with Back to trips.
    private var topBanner: DrivingBanner?
    /// A demo's sheet size on its first frame (the app's arrives folded: `TripSheetSize.entry`).
    private var demoShown: PanelSheet.Shown?
    /// The trip ended (organizer or server): the owner shows the recap.
    var onEnded: () -> Void = {}
    /// Alerts, the notification pre-prompt and the cars listener. Off in the demo.
    private let liveServices: Bool
    private var stopService: any StopServing = StopService()
    /// The demo can open the card on one of its screens (`road-card-*` launch states); nil in the app.
    private var demoScreen: String?
    /// `camera-sheet-tour` (Debug launch state): the sheet and the banners come and go by themselves.
    private var demoTour = false
    /// `follow-drive-interrupts` (D70): the sheet, a banner, Fit, Follow and a hazard in the middle of follow glides.
    private var demoInterrupts = false

    @Environment(TripScreenModel.self) private var stage
    @State private var model: TripMapModel
    @State private var alerts = AlertCenter()
    @State private var toast = ReportToastModel()
    /// The convoy sheet's measured heights and card hand-over (`ConvoySheetState`); its size and whether it is up are
    /// the one sheet's (`stage.sheet`).
    @State private var sheet = ConvoySheetState()
    /// The driving sheet's list is this wide (`panelSheet`).
    @State private var listWidth: CGFloat = 0
    /// The banner probe's row and list tops on screen (`bannerProbe`).
    @State private var probeRowY: CGFloat?
    @State private var probeTop: CGFloat?
    private var shown: PanelSheet.Shown { stage.sheet.size.shown }
    private var panelExpanded: Bool { shown.listUnfolded }
    @State private var reportContext: ReportContext?
    /// The ask on screen now; the next one waits for it to be answered (`TripAskPlanner`).
    @State private var ask: TripAsk?
    @State private var screenAwake = ScreenAwake()
    @State private var network = NetworkStatus()
    @State private var onScreen = false
    @Environment(\.scenePhase) private var scenePhase
    /// The open stop requests (and a "No answer"), from `StopService.listen`.
    @State private var stopBoard = StopBoard.empty
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What the pill at the top has shown and when, so each question goes quiet after 20 seconds.
    @State private var pillMemory = StopPillMemory()
    @State private var pillNow = Date()
    @State private var driving = DrivingDetector()
    @State private var glanceError = GlanceError()
    /// The banner stack's height, for the one cover's top (`drivingCover`); the sheet's own height comes from `sheetHeights`.
    @State private var topHeight: CGFloat = 0
    /// The on-screen panel's header words, for the probes (`ConvoyPanel.headerWords`).
    @State private var panelHeader: ConvoyHeader.Text?
    /// The camera inputs last acted on, by the sheet's own change (`setShown`) or by the watcher, so the watcher seeing
    /// the same ones after a sheet change makes no second move (D63 C4).
    @State private var inputsWatch = CameraInputsWatch()
    /// The bottom inset the map keeps as safe area: the folded panel's, so the Legal label sits
    /// above it. The rest of what covers the map goes into the camera (`cameraRoom`).
    @State private var legalInset: CGFloat = 0
    /// From the map's own camera, for `MapCameraRoom.latitudePerPointPerMeter`.
    @State private var latitudePerPointPerMeter = 0.0
    /// The top cover (banner stack, from the map's top edge) the camera was last aimed with: where my car sits in the visible strip
    /// (`CameraInsetMove.plan`).
    @State private var aimedTop: CGFloat = 0
    /// The hazard approach alert being followed: a pill, the hazard pinging and in view, until it's passed.
    @State private var approach: TripAlert?
    /// The camera mode to go back to once the hazard is passed.
    @State private var modeBeforeApproach: MapMode = .follow
    @State private var passedText: String?
    /// Since when each banner has been up, so the newest of "the rest" can be told (`BannerSlot`).
    @State private var bannerArrivals = BannerSlot.Arrivals()
    /// What the slot has already said, so a message coming back from waiting is not said again.
    @State private var spokenBanners = SpokenBanners()
    @AppStorage(AlertSettings.readAloudKey) private var readAloud = AlertSettings.readAloudDefault

    /// Kept screen on while the map is up: the screen's one setting (`TripScreenModel.keepScreenOn`).
    private var keepAwakeOn: Bool { stage.keepScreenOn }
    /// What was asked on the last trip (`TripAskMemory`), so leaving the map and coming back doesn't nag.
    @AppStorage("ikut.map.askedTrip") private var askedTrip = ""

    /// The app's: `model` is the open trip's, made with it by the screen's model (`OpenTrip.map`).
    init(
        session: TripSession, map model: TripMapModel, continuation: PulledUpSheet? = nil,
        topBanner: DrivingBanner? = nil, onEnded: @escaping () -> Void = {}
    ) {
        self.session = session
        self.continuation = continuation
        self.topBanner = topBanner
        self.onEnded = onEnded
        liveServices = true
        _model = State(initialValue: model)
    }

    /// For the demo and previews: a model that is fed by hand and no live services.
    init(
        session: TripSession, model: TripMapModel, stopBoard: StopBoard = .empty,
        alerts: AlertCenter = AlertCenter(), demoCard: String? = nil, demoReport: Bool = false, demoDriving: Bool = false, demoExpanded: Bool = false, demoError: String? = nil,
        demoApproach: TripAlert? = nil, demoPassed: String? = nil, demoToast: ReportToastModel? = nil, demoTour: Bool = false,
        demoInterrupts: Bool = false, stopService: any StopServing = StopService(),
        demoPulledUp: Bool = false, continuation: PulledUpSheet? = nil, topBanner: DrivingBanner? = nil,
        demoAsk: TripAsk? = nil
    ) {
        _ask = State(initialValue: demoAsk)
        _alerts = State(initialValue: alerts)
        self.session = session
        self.continuation = continuation
        self.topBanner = topBanner
        liveServices = false
        self.stopService = stopService
        demoScreen = demoCard
        self.demoTour = demoTour
        self.demoInterrupts = demoInterrupts
        _glanceError = State(initialValue: demoError.map { var e = GlanceError(); e.show($0, cause: .send); return e } ?? GlanceError())
        var demoSheet = ConvoySheetState()
        demoSheet.stopCardOpen = demoCard != nil && !demoReport
        if demoReport {
            _reportContext = State(initialValue: .demo)
            demoSheet.reportOpen = true
        }
        demoShown = demoPulledUp ? .pulledUp : demoExpanded ? .unfolded : nil
        _sheet = State(initialValue: demoSheet)
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
            // What covers the one map (D63 C4): a banner or a measured height written as it changes; a fold, unfold or
            // pull-up writes it itself, in its own transaction (`setShown`).
            .onChange(of: drivingCover, initial: true) { _, cover in stage.cover(cover, from: .driving) }
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
                .animation(DrivingGlance.animation(Motion.pill, reduceMotion: reduceMotion), value: viewButtonsTop)
                // The tall sheet would cut through it: fade it out, and back when the sheet folds.
                .opacity(DrivingGlance.modeControlOpacity(panelExpanded: panelExpanded))
                .allowsHitTesting(!panelExpanded)
                .accessibilityHidden(panelExpanded)
                .animation(Motion.fade, value: panelExpanded)
            }
            .toolbar(.hidden, for: .navigationBar)
            .preference(key: TripMapSpecKey.self, value: mapSpec)
            // The one sheet: the lobby's content becomes the convoy panel's, with its detents, in the sheet that is up.
            .preference(key: TripSheetSpecKey.self, value: TripSheetSpec(onDismiss: panelDismissed, content: AnyView(panelSheet)))
            .onChange(of: stage.reading, initial: true) { _, reading in measureCamera(reading) }
            // Any pan, pinch or rotate by the user hands the camera back to them.
            .onChange(of: stage.camera.positionedByUser) { _, byUser in
                // A pan ends a paced flight at once: nothing held lands on top of it.
                guard byUser else { return }
                stage.flight.cancel()
                model.mode = MapCameraLogic.mode(afterUserGestureFrom: model.mode)
            }
            .onChange(of: typeSize) { _, _ in sheet.forgetMeasuredHeights() }
            .onChange(of: session.alwaysExplainerShowing) { _, _ in nextAsk() }
            .onChange(of: ask) { _, now in session.askShowing = now != nil }
            .onChange(of: keepAwakeOn) { _, _ in updateAwake() }
            .onChange(of: readAloud) { _, _ in alerts.readAloudChanged() }
            .onChange(of: scenePhase) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, _ in updateAwake() }
            .onChange(of: session.isEnded) { _, ended in if ended { onEnded() } }
            // Opened on the app's first frame (a relaunch, a Now row read as started) the member doc comes after the
            // alerts started: from then on this car's own stop requests are not announced.
            .onChange(of: session.member?.carId) { _, carId in alerts.setMyCar(carId) }
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
                if sheet.stopRequestsChanged(hadRequests: !old.requests.isEmpty, hasRequests: !board.requests.isEmpty) {
                    cardSheetLog.debug("stop card closed by its stop")
                }
            }
            .task(id: pillTimerKey) { await tickPill() }
            .task { await watchDriving() }
            // The phone's own fixes for the map (D70): the tracker's stops in the background, where its map draws
            // nothing; a passenger's runs as before. The last fix is kept while it is stopped.
            .task(id: MapLocationStream.runs(isTracker: model.isTracker, phase: scenePhase)) {
                guard liveServices, MapLocationStream.runs(isTracker: model.isTracker, phase: scenePhase) else { return }
                await model.runDeviceLocation()
            }
            .onChange(of: sessionSignature) { _, _ in if liveServices { model.sync() } }
            // One watcher for everything that moves the camera (D67): the aim itself, and the sheet, the stop card or a
            // banner changing what the map can see. Several changes in one update are one move, on the motion of the
            // change that caused it (`CameraInsetMove`).
            .onChange(of: cameraInputs, initial: true) { _, new in takeCameraInputs(new) }
            .onChange(of: session.isPaused) { _, paused in if !paused { glanceError.resolve(.pause) } }
            .onChange(of: alerts.current?.id) { followApproachIfNeeded() }
            .task(id: approach?.id) { await watchApproach() }
            .task(id: passedText) { await expirePassed() }
            .task(id: demoTour) { if demoTour { await playSheetTour() } }
            .task(id: demoInterrupts) { if demoInterrupts { await playInterrupts() } }
    }

    // MARK: Map

    /// `camera-sheet-tour`: unfold and fold the sheet, then a banner and an error come and go, looping, so the camera's
    /// moves can be watched against each (`IKUT_CAMERA_LOG=1` logs them).
    private func playSheetTour() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        var round = 0
        while !Task.isCancelled {
            // Following my car first (a banner leaves the road where it is), then the whole convoy (it refits).
            model.mode = round % 2 == 0 ? .follow : .fit
            round += 1
            await pause(3)
            setShown(.unfolded)
            await pause(3)
            setShown(.folded)
            await pause(3)
            withAnimation(Motion.banner(reduceMotion: reduceMotion)) { passedText = "Passed the debris" }
            await pause(4)
            withAnimation(Motion.banner(reduceMotion: reduceMotion)) { passedText = nil }
            await pause(2.5)
            withAnimation(Motion.banner(reduceMotion: reduceMotion)) { glanceError.show("Couldn’t reach the convoy. Try again in a moment.", cause: .pause) }
            await pause(4)
            withAnimation(Motion.banner(reduceMotion: reduceMotion)) { glanceError.resolve(.pause) }
            await pause(2.5)
        }
    }

    /// `follow-drive-interrupts`: each change lands 0.4 s into a follow glide (the fixes come on the whole second),
    /// so the camera can be checked to end where the change says, with no snap back to the glide's aim.
    private func playInterrupts() async {
        func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        await pause(3.4)
        for change in 0..<8 where !Task.isCancelled {
            #if DEBUG
            CameraMoveLog.note("interrupt \(change)")
            #endif
            switch change {
            case 0: setShown(.unfolded)
            case 1: setShown(.folded)
            case 2: withAnimation(Motion.banner(reduceMotion: reduceMotion)) { passedText = "Passed the debris" }
            case 3: withAnimation(Motion.banner(reduceMotion: reduceMotion)) { passedText = nil }
            case 4: model.mode = .fit
            case 5: model.mode = .follow
            case 6: model.mode = .hazard(id: "demo-debris")
            default: model.mode = .follow
            }
            await pause(3)
        }
    }

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

    /// The map's height down to the screen's bottom edge, from the one map (D63 C4).
    private var mapFullHeight: CGFloat { stage.space.fullHeight }
    private var mapWidth: CGFloat { stage.space.frame.width }

    /// How far above this layer's top the map starts: the one map runs under the status bar for the lobby and for
    /// driving alike, while this layer (and the banner stack it measures) starts under it.
    private var mapAbove: CGFloat { stage.space.above }

    /// Reads the map's scale off its own camera once a move has ended; the first reading aims the camera again.
    private func measureCamera(_ reading: TripCameraReading?) {
        guard let reading else { return }
        let fullHeight = mapFullHeight
        guard fullHeight > 0, reading.distance > 0, reading.pitch == 0 else { return }
        let measured = latitudePerPointPerMeter
        latitudePerPointPerMeter = reading.latitudeDelta / Double(fullHeight) / reading.distance
        if measured == 0 { move(to: model.cameraTarget, animated: true, reaim: true) }
    }

    /// What the camera aims at and what covers the map, watched as one value.
    private var cameraInputs: CameraInsetMove.Inputs {
        CameraInsetMove.inputs(target: model.cameraTarget, layerHeight: stage.space.layerHeight, above: mapAbove, cover: cover)
    }

    /// What this layer lays over the map: the banner stack at the top, the sheet and the stop card at the bottom.
    private var drivingCover: MapCover {
        MapCover(top: topHeight, bottom: sheet.covered(shown, up: stage.sheet.up, room: sheetRoom, hasTopBanner: topBanner != nil))
    }

    /// What covers the map, as the one cover holds it; this layer's own until its first write lands.
    private var cover: MapCover { stage.space.cover(in: .driving) ?? drivingCover }

    /// Hands the camera inputs it has not acted on yet (`CameraInputsWatch`).
    private func takeCameraInputs(_ new: CameraInsetMove.Inputs) {
        guard let (old, new) = inputsWatch.take(new) else { return }
        cameraInputsChanged(from: old, to: new)
    }

    /// The camera's move for a change of its inputs: none when my car stays comfortably in view under a new banner,
    /// otherwise one, on the motion of the sheet or banner that caused it.
    private func cameraInputsChanged(from old: CameraInsetMove.Inputs, to new: CameraInsetMove.Inputs) {
        if !panelExpanded, cardNow == nil { legalInset = DrivingGlance.legalInset(foldedSheetHeight: new.bottom) }
        // The first look: aim at the target, as before the watcher.
        guard old != new else { move(to: model.cameraTarget, animated: true); return }
        let plan = CameraInsetMove.plan(old: old, new: new, frameHeight: mapFullHeight, aimedTop: aimedTop)
        #if DEBUG
        CameraMoveLog.record(inputs: new, plan: plan)
        #endif
        guard let plan else { return }
        // My car on to its next fix (or the convoy's frame moving with its cars): a linear glide over the time
        // between fixes, which also takes in a recentre a banner left for it (D70).
        var step: TimeInterval?
        if CameraInsetMove.isStep(from: old.target, to: new.target) {
            // Following: my fix's glide, even when a car's write came in the same update.
            if case .follow? = new.target, let aim = model.myAim { step = aim.duration } else { step = model.lastGlide }
        }
        move(to: model.cameraTarget, animated: true, plan: plan, step: step)
    }

    /// The visible strip the camera aims at, inside the frame MapKit fits to (the map less `legalInset`).
    private var cameraRoom: MapCameraRoom {
        let inputs = cameraInputs
        return MapCameraRoom(
            width: mapWidth, height: max(mapFullHeight - legalInset, 0),
            top: inputs.top, bottom: max(inputs.bottom - legalInset, 0),
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

    /// The view `target` shows, for pacing: a follow camera's height from the map's own scale once it is read.
    private func cameraView(for target: CameraTarget) -> CameraView {
        switch target {
        case .follow(let center, let distance):
            return CameraView(center: center.clCoordinate, distance: distance,
                              latitudePerMeter: latitudePerPointPerMeter * Double(mapFullHeight))
        case .fit(let region):
            return CameraView(latitude: region.center.latitude, longitude: region.center.longitude,
                              latitudeSpan: region.latitudeSpan)
        }
    }

    /// Every camera move on the driving map. A nudge (a follow step, a re-centre for the sheet or a banner) is a short
    /// glide, on the motion of the sheet or banner that caused it; a flight in the air takes the change into its
    /// landing (`retarget`) or waits for it; anything bigger (into follow from the lobby, Fit, a hazard, a car) is
    /// paced by `CameraPace` and takes over whatever is in flight (`CameraInsetMove.action`).
    private func move(to target: CameraTarget?, animated: Bool, reaim: Bool = false,
                      plan: CameraInsetMove.Plan = .init(targetChanged: true, cause: .none), step: TimeInterval? = nil) {
        guard let aimed = cameraRoom.target(target), let next = Self.position(for: aimed) else { return }
        aimedTop = cameraInputs.top
        guard animated else { stage.place(next); return }
        let view = cameraView(for: aimed)
        let nudge = { [stage, reduceMotion, mapWidth] (cause: CameraInsetMove.Cause) in
            // A follow step: MapKit plays its own short ease for a small `withAnimation` move, whatever its length, so
            // the step is a keyframe glide instead, which it plays as given (D70); one too small to see is placed.
            if cause == .none, !reduceMotion, let step, let camera = next.camera {
                let points = (stage.seenView.map { CameraPace.travel(from: $0, to: view) } ?? 1) * Double(mapWidth)
                stage.glide(to: camera, duration: step > 0 && points >= MarkerGlide.placeUnder ? step : 0.01)
                return
            }
            // A sheet or banner move while a follow glide runs: MapKit keeps playing the glide over a `withAnimation`
            // move, so the move itself is a keyframe on the cover's time, which takes the glide's place.
            if stage.isGliding, !reduceMotion, let camera = next.camera {
                stage.glide(to: camera, duration: cause == .banner ? 0.3 : 0.4)
                return
            }
            // Anything else ends a running glide first, so it isn't fought or swallowed.
            stage.endGlide()
            withAnimation(CameraInsetMove.animation(cause, reduceMotion: reduceMotion, step: step)) { stage.camera = next }
        }
        let paced = CameraPace.decide(flyingTo: stage.flight.destination, seen: stage.seenView, to: view, reaim: reaim)
        let action = CameraInsetMove.action(plan, paced: paced, flying: stage.flight.isFlying)
        #if DEBUG
        CameraMoveLog.record(plan: plan, action: action, from: stage.seenView, to: view)
        #endif
        switch action {
        case .hold: stage.flight.hold { nudge(.none) }
        case .nudge(let cause): nudge(cause)
        case .retarget:
            stage.endGlide()
            if !stage.flight.retarget(to: next, view: view) { nudge(plan.cause) }
        case .fly: stage.fly(to: next, view: view, reduceMotion: reduceMotion)
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
            stopPillId: sheet.stopCardOpen ? nil : stopPill?.id,
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
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { passedText = nil }
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
        setShown(PanelSheet.shown(after: .approaching, from: shown))
    }

    /// Back to the mode from before the alert, unless the driver has picked another mode since. The list stays as
    /// it is (#344): it does not unfold again by itself while the car is moving.
    private func endHazardFocus(_ moment: PanelSheet.Moment) {
        if case .hazard = model.mode { model.mode = modeBeforeApproach }
        setShown(PanelSheet.shown(after: moment, from: shown))
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
                withAnimation(DrivingGlance.animation(Motion.pill, reduceMotion: reduceMotion)) {
                    approach = nil
                    passedText = "Passed the \(label)"
                }
                endHazardFocus(.passed)
                return
            }
            if distance == nil, Date().timeIntervalSince(started) > 180 {
                withAnimation(Motion.banner(reduceMotion: reduceMotion)) { approach = nil }
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
            slotMessage
                // One motion for every message: a new one comes in as the slot's transition, and the old one leaves.
                .id(bannerSlot.shown)
                .transition(bannerTransition)
        }
        .frame(maxWidth: .infinity)
        .environment(\.spokenBanners, spokenBanners)
        // Always mounted, unlike the toast: a report made while another message has the slot still gives its haptics.
        .reportHaptics(toast)
        .animation(Motion.banner(reduceMotion: reduceMotion), value: bannerSlot.shown)
        .animation(Motion.banner(reduceMotion: reduceMotion), value: alerts.current?.id)
        .onChange(of: bannerPresent, initial: true) { _, present in
            bannerArrivals.update(present: present, now: Date())
            spokenBanners.keep(Set(present.values))
        }
    }

    private var bannerTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    @ViewBuilder private var slotMessage: some View {
        Group {
            switch bannerSlot.shown {
            case .hazardApproach:
                if let approach { ApproachPill(alert: approach, model: model) { focusHazard(approach.eventId) } }
            case .stopPill:
                if let stopPill, !sheet.stopCardOpen {
                    StopPillView(pill: stopPill, onButton: pillTapped)
                }
            case .stopApproach:
                if let stopApproach = model.stopApproach, let kind = stopApproachKind {
                    StopApproachPill(alert: stopApproach, kind: kind, model: model)
                }
            case .toast:
                ReportToastView(model: toast, inSlot: true, haptics: false)
            case .passed:
                if let passed = passedText { PassedBanner(text: passed) { passedText = nil } }
            case .paused:
                PausedBanner(session: session, onError: { message in
                    glanceError.show(message, cause: .pause)
                })
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
                    .padding(.top, Spacing.xxs).padding(.trailing, Spacing.xs)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("trip.pill.errorDot")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(bannerSlot.errorHeld ? "error waiting" : "")
        // 4 pt top and bottom, 16 pt either side, so the pill is 56 pt tall in every state.
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xs)
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
        return model.isTracker && !session.isPaused ? Color.green : .orange
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

    private func openStopCard() { sheet.stopCardOpen = true }

    private func closeStopCard() {
        cardSheetLog.debug("stop card closed")
        sheet.stopCardOpen = false
    }

    private func closeArrivalCard() { sheet.arrivalStopId = nil }

    /// The card sheet's state follows what is wanted (`cardNow`); see `ConvoySheetState.syncCard`.
    private func syncCard(_ want: MapCard?) {
        cardSheetLog.debug("want \(String(describing: want), privacy: .public), presented \(sheet.presentedCard != nil), dismissing \(sheet.cardDismissing)")
        applyCard(sheet.syncCard(wanted: want))
    }

    private func cardDismissed() {
        cardSheetLog.debug("dismissed; want \(String(describing: cardNow), privacy: .public)")
        applyCard(sheet.cardDismissed(wanted: cardNow))
    }

    private func applyCard(_ startedDismissing: Bool) {
        guard startedDismissing else { return }
        // A dismissal the sheet never reports must not hold the next card back.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PanelSheet.cardDismissFallback))
            if sheet.cardDismissing { cardDismissed() }
        }
    }

    // MARK: The sheet

    /// The arrival card is up: its stop is still on (a stop skipped while it is open closes it).
    private var arrivalOpen: Bool {
        sheet.arrivalStopId.map { StopArrival.target(stopId: $0, in: model.stops) != nil } ?? false
    }

    /// The card wanted over the convoy sheet: Report, the Pit stop request (opened only by a tap on the button) or the
    /// who-is-here card (the Next stop cell).
    private var cardNow: MapCard? {
        sheet.wantedCard(reportReady: reportContext != nil, stopReady: stopContext != nil, arrivalLive: arrivalOpen)
    }

    /// The top of the convoy sheet's scrolling content.
    private static let sheetTop = "sheet.top"

    /// Where my car is on the main route and its pace, for the pulled-up journey; nil while it is still joining.
    private var journeyHere: LobbyContent.JourneyHere? {
        model.convoy.myEntry.map { LobbyContent.JourneyHere(offset: $0.convoyOffset, pace: model.stopPace()) }
    }

    /// The lobby continues below the convoy now (`PanelSheet.showsContinuation`).
    private var continuationShown: Bool { continuation != nil && PanelSheet.showsContinuation(shown, in: sheetHeights) }

    /// The map's height under the pills and banners, where the sheet may reach to at most (the stop pill, a
    /// banner and the trip pill always stay visible above it, at any text size).
    private var sheetRoom: CGFloat? {
        PanelSheet.room(mapHeight: stage.space.layer.bottomEdge > 0 ? stage.space.layer.bottomEdge - stage.space.layer.minY : 0,
                        reserved: max(bannerShowing ? 158 : 74, topHeight + Spacing.m))
    }

    /// What the layouts measure now.
    private var measuredHeights: PanelSheet.Heights {
        sheet.measuredHeights(room: sheetRoom, hasTopBanner: topBanner != nil)
    }

    /// What the sheet uses: the measured heights, held while it moves (`PanelSheet.settled`).
    private var sheetHeights: PanelSheet.Heights { sheet.heights(room: sheetRoom, hasTopBanner: topBanner != nil) }

    /// Takes the measured heights the sheet may use now; a change at rest (a car joins, the text grows) moves the
    /// sheet with its usual motion.
    private func resettle() {
        guard let next = sheet.heightsToTake(room: sheetRoom, hasTopBanner: topBanner != nil) else { return }
        if sheet.appliedHeights == nil {
            sheet.take(next)
        } else {
            withAnimation(Motion.sheet(reduceMotion: reduceMotion)) { _ = sheet.take(next) }
        }
    }

    /// Runs `change` as one sheet motion (`Motion.sheet`, a fade with Reduce Motion): the detent, the content swap and
    /// the camera's re-centre in one transaction, with the heights held until it is over.
    private func moveSheet(_ change: @escaping () -> Void) {
        animateSheet(sheet.beginMotion(), change)
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
        guard sheet.endMotion(motion) else { return }
        resettle()
    }

    /// The convoy sheet went (the trip ended, the Always sheet): the card went with it.
    private func panelDismissed() {
        cardSheetLog.debug("convoy sheet dismissed")
        // The card went with the convoy sheet; it comes back with it if it is still wanted.
        sheet.convoySheetWent()
    }

    /// Apple's own sheet over the map, as on Home: drag it between short (the folded panel) and tall (the
    /// unfolded one), always up, the map above it touchable. A stop card replaces the panel in it. The
    /// report sheet, the confirmations and the asks are presented from here, since a presented sheet
    /// blocks a presentation from the map under it.
    private var panelSheet: some View {
        let shown = self.shown
        let heights = sheetHeights
        // Pulled up, the lobby continues below the unfolded panel, which stays where it was (canvas row L): one system
        // list, the panel in a clear row of its own and the lobby's sections after it.
        let list = ScrollViewReader { scroller in
            List {
                if let topBanner { topBanner.rows }
                Section {
                    // As wide as the list, not as the section: the grouped list insets its sections by its own
                    // margin, and the panel keeps the width its heights were measured at (`probes`).
                    panel
                        .frame(width: listWidth > 0 ? listWidth : nil)
                        .frame(maxWidth: .infinity)
                        .lobbyRow().id(Self.sheetTop)
                }
                if continuationShown, let continuation {
                    continuation.sections(journeyHere)
                }
            }
            .modifier(DrivingList(hasBanner: topBanner != nil))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { listWidth = $0 }
            // The pulled-up marker: UI tests and VoiceOver find the lobby below the convoy by it.
            .accessibilityIdentifier(continuationShown ? "trip.pulledUp" : "driving.sheet")
            // On the list itself: around the ScrollViewReader the bar did not inset the content, so the last rows
            // (Leave trip, End trip) stayed under it.
            .sheetBottomBar { actionBar }
            // The lobby below the convoy went (the grabber, the header, a stop request, a hazard): the sheet starts at the
            // convoy's header again, not partway down.
            .onChange(of: continuationShown) { _, shown in if !shown, topBanner == nil { scroller.scrollTo(Self.sheetTop, anchor: .top) } }
        }
        return (continuation?.asks(AnyView(list)) ?? AnyView(list))
        .environment(\.inPanelSheet, true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) { sheet.sheetSafeBottom = $0 }
        .background(alignment: .top) { probes }
        .background(alignment: .top) { bannerProbe }
        .presentationDetents(TripScreenLogic.Sheet.driving(heights).detents, selection: Binding(
            get: { PanelSheet.detent(shown, in: heights) },
            set: {
                guard let chosen = PanelSheet.choice($0, in: heights) else { return }
                setShown(chosen)
            }))
        .onChange(of: measuredHeights, initial: true) { resettle() }
        .onChange(of: continuationShown, initial: true) { _, shown in stage.pulledUp = shown }
        .onChange(of: cardNow, initial: true) { _, want in
            syncCard(want)
            if want != nil { setShown(PanelSheet.shown(after: .stopAsks, from: self.shown)) }
        }
        // A stop request's pill asks for an answer: a pulled-up sheet comes back to tall so it isn't behind the lobby.
        .onChange(of: stopPill?.id) { _, id in
            if id != nil { setShown(PanelSheet.shown(after: .stopAsks, from: self.shown)) }
        }
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: TripScreenLogic.Sheet.driving(heights).touchableUpThrough))
        // A swipe on the content resizes the sheet below its tallest, so a swipe up on the car list pulls it up to the
        // lobby below the convoy and a swipe down steps back (#424); pulled up, the rows scroll, and a swipe down at
        // their top steps the sheet back down. A tap on the convoy's header still folds and unfolds the list.
        .presentationContentInteraction(.resizes)
        .interactiveDismissDisabled()
        .sheet(item: Binding(get: { sheet.presentedCard }, set: cardSetByTheSystem), onDismiss: cardDismissed) { _ in
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
        guard value != shown else { return }
        // The camera's move for the new cover in the same transaction as the resize (D63 C4), on the sheet's motion.
        moveSheet {
            // The watch is stored before the camera acts, so the watcher's next look finds these inputs handled.
            var watch = inputsWatch
            let change = watch.resize(stage, to: value, cover: { drivingCover }, inputs: { cameraInputs })
            inputsWatch = watch
            if let change { cameraInputsChanged(from: change.old, to: change.new) }
        }
    }

    /// The header's fold and unfold: unfolding a pulled-up sheet leaves it pulled up.
    private func setExpanded(_ value: Bool) {
        guard let next = shown.expanding(value) else { return }
        setShown(next)
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

    /// The banner on top of the panel, laid out as a list of its own with a row where the panel goes: that row's
    /// top is how far down the panel sits under the banner, whatever the list's own section gaps are, and the list
    /// never scrolls, so the reading is not a scroll position's.
    @ViewBuilder private var bannerProbe: some View {
        if let topBanner {
            List {
                topBanner.measure
                Section {
                    Color.clear.lobbyRow()
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { probeRowY = $0; readBannerProbe() }
                }
            }
            .modifier(DrivingList(hasBanner: true))
            .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { probeTop = $0; readBannerProbe() }
            .frame(height: PanelSheet.bannerProbeRoom)
            // Above the sheet, out of sight and touch (its rows are the banner's own, drawn invisible and with nothing to find by
            // `DrivingBanner.measure`). Not
            // `.hidden()`: a hidden list makes no cells, so its row would never be laid out to be read.
            .offset(y: -PanelSheet.bannerProbeRoom)
            .allowsHitTesting(false)
        }
    }

    /// The banner probe's reading: the marker row's top less the probe list's own (both on screen), which is how far down
    /// the panel sits under the banner. A named coordinate space does not reach into a list's rows.
    private func readBannerProbe() {
        guard let row = probeRowY, let top = probeTop else { return }
        sheet.topContent = max(0, row - top)
    }

    private func probe(unfolded: Bool) -> some View {
        ConvoyPanel(
            model: model, expanded: .constant(unfolded),
            onHeight: { if unfolded { sheet.unfoldedContent = $0 } else { sheet.foldedContent = $0 } },
            probe: true, headerWords: panelHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A swipe down on a card (Report allows one) closes what it showed; the sheet going away because we changed
    /// `presentedCard` ourselves has nothing left to clear.
    private func cardSetByTheSystem(_ card: MapCard?) {
        guard card == nil, sheet.cardClosedBySystem() else { return }
        cardSheetLog.debug("card dismissed by the system")
    }

    /// The card sheet: slides up from the bottom over the convoy sheet (the system's own, no glass or material of its
    /// own), as tall as its content up to the room under the pills, with the map above it still touchable.
    private var cardSheet: some View {
        let card = cardNow ?? sheet.lastCard
        return ScrollView {
            cardView(card)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sheet.cardContent = $0 }
                // The keyboard's share of the taller sheet, under the card (Q16).
                .padding(.bottom, sheet.cardKeyboard)
        }
        .scrollBounceBehavior(.basedOnSize)
        // The sheet grows by the keyboard instead (`cardDetent`): left to the system, the keyboard covered the whole card,
        // pushed its body out of the scroll view and took its buttons' lift with it, so the message field was gone.
        .ignoresSafeArea(.keyboard)
        .environment(\.inPanelSheet, true)
        // The buttons sit as far above the sheet's bottom edge as every sheet's bottom bar (`PanelSheet.sideGap`).
        .environment(\.cardActionLift, PanelSheet.barLift(safeBottom: sheet.cardSafeBottom))
        .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.bottom }) {
            sheet.readCardSafeBottom($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = note.object as? UIScreen else { return }
            sheet.keyboardFrame(frame, screenHeight: screen.bounds.height)
            cardSheetLog.debug("keyboard covers \(sheet.cardKeyboard)")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            sheet.keyboardGone()
        }
        .onDisappear { sheet.keyboardGone() }
        .presentationDetents([.height(sheet.cardDetent(room: sheetRoom))])
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
            onNextStop: { id in sheet.arrivalStopId = id },
            onHeader: { panelHeader = $0 })
    }

    /// Report and Pit stop: pinned to the sheet's bottom, outside the scrolling panel.
    private var actionBar: some View {
        ConvoyActionBar(
            canReport: model.myCarId != nil, stopButton: StopLogic.buttonContent(for: stopBoard),
            onReport: openReport, onStop: openStopCard, lift: PanelSheet.barLift(safeBottom: sheet.sheetSafeBottom))
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { sheet.barContent = $0 }
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
                    withAnimation(Motion.banner(reduceMotion: reduceMotion)) {
                        pillMemory.noteOK(request, now: Date())
                        pillNow = Date()
                    }
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
        withAnimation(Motion.banner(reduceMotion: reduceMotion)) { pillNow = Date() }
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
        sheet.reportOpen = true
    }

    /// Sessions fields that change what the map shows.
    private var sessionSignature: SessionSignature {
        SessionSignature(
            trip: session.trip, car: session.car, positions: session.positions,
            isTracking: session.isTracking, carId: session.member?.carId, stops: session.stops,
            skipsMeetingPoint: session.skipsMeetingPoint, cars: session.cars)
    }

    private struct SessionSignature: Equatable {
        var trip: Trip?
        var car: Car?
        var positions: [String: Position]
        var isTracking: Bool
        var carId: String?
        var stops: [PlannedStop]
        var skipsMeetingPoint: Bool
        var cars: [Car]
    }

    private func appear() {
        if let demoShown { stage.sheet.resize(to: .driving(demoShown)) }
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

/// The banner on top of the driving sheet ("You're no longer in this trip", with Back to trips): the lobby's banner
/// section, and the same rows drawn invisible and out of the accessibility tree, which the sheet lays out out of sight to
/// know how far down the panel sits under it (`TripMapView.bannerProbe`).
struct DrivingBanner {
    var rows: AnyView
    var measure: AnyView
}

/// What continues below the convoy panel when the driving sheet is pulled up: the lobby's journey, code, trip, options and
/// Leave or End as system list sections (`sections`, handed where my car is), and what presents from inside the sheet
/// (`asks`: the QR code, the confirmations, the rename), which the lobby owns.
struct PulledUpSheet {
    var sections: (LobbyContent.JourneyHere?) -> AnyView
    var asks: (AnyView) -> AnyView
}

/// The driving sheet's list: grouped sections on the sheet's own glass, with nothing of its own above, below or between
/// the panel and the banner on top of it, so the detents are the panel's measured heights.
private struct DrivingList: ViewModifier {
    var hasBanner: Bool

    func body(content: Content) -> some View {
        content
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .environment(\.defaultMinListHeaderHeight, 0)
            // The banner's grabber room (the panel's own header has it when there is no banner).
            .contentMargins(.top, hasBanner ? Spacing.xs + BottomSheet.indicatorRoom : 0, for: .scrollContent)
            .contentMargins(.bottom, 0, for: .scrollContent)
            .listSectionSpacing(.custom(Spacing.s))
    }
}
