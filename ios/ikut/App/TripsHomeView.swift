import FirebaseAuth
import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are and the routes of
/// your past trips, under Apple's own sheet with Where to?, Join with a code, the trips now running and past trips.
/// It is the Home layer over the app's one map (`TripScreenHost`, D54): it hands the map what to draw (`TripMapSpec`)
/// and the one sheet its content (`TripSheetSpec`), and moves the shared camera, so opening a trip is a camera move and
/// a sheet change on the same map.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    @Environment(TripScreenModel.self) private var stage
    @Environment(LocationPermission.self) private var location
    /// Home's flows and what they remember (`HomeModel`); HomeView makes it and hands it in.
    let given: HomeModel
    /// A demo's own model, kept across redraws of its parent (which makes a new view, and so a new seeded model, each time).
    @State private var seeded: HomeModel?
    var model: HomeModel { seeded ?? given }
    var onNewTrip: () -> Void
    var onJoin: () -> Void
    /// A trip that hasn't ended opens on the same map: its lobby, or driving when Home has read that it started. An
    /// ended one is picked on this map instead.
    var onOpenTrip: (PastTrips.Entry, _ started: Bool) -> Void = { _, _ in }
    /// A pushed screen or a sheet of the parent is up: Home's sheet steps aside (a sheet is presented over Home, so it
    /// would sit over them) and comes back when this is false again (`TripSheetCover.home`, set by the parent).
    var covered: Bool { stage.sheet.covered(by: TripSheetCover.home) }
    /// The trip was made: its id, to open its lobby.
    var onCreated: (String) -> Void = { _ in }
    /// The trip was joined: its id, to open its lobby, and whether this phone tracks its car.
    var onJoined: (String, Bool) -> Void = { _, _ in }

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    @State private var settingsShown = false
    #if DEBUG
    /// A launch state opens with a name alert up: `rename` (the field) or `rename-error` (it couldn't be saved).
    var demoAlert: String?
    /// `settings-design-fonts` opens Settings on Design with the font sizes list pushed.
    static func settingsDrill(_ demo: String?) -> DesignDrill? { demo == "settings-design-fonts" ? .literals(.font) : nil }
    #endif
    /// The short sheet's height, the same for the list and a picked trip so a pick never resizes it. Follows the
    /// text size and nothing else.
    @ScaledMetric(relativeTo: .body) private var shortHeight: CGFloat = HomeSheet.compactHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    /// Demo that can be tapped through: picking a trip gives it this recap (no server). `tour` also picks the
    /// first trip and closes it again by itself (the second time pulling it up and down first), so a recording needs no taps.
    @State private var demoModel: RecapModel?
    @State var tour = false
    /// `home-camera-tour` (D57): plays Home's camera hops by itself, with a caption naming each.
    @State private var cameraTour = false
    @State var tourCaption = ""
    #endif

    init(model: HomeModel = HomeModel.launching(), onNewTrip: @escaping () -> Void, onJoin: @escaping () -> Void,
         onOpenTrip: @escaping (PastTrips.Entry, Bool) -> Void = { _, _ in }, onCreated: @escaping (String) -> Void = { _ in },
         onJoined: @escaping (String, Bool) -> Void = { _, _ in }) {
        given = model
        self.onJoined = onJoined
        self.onCreated = onCreated
        self.onNewTrip = onNewTrip
        self.onJoin = onJoin
        self.onOpenTrip = onOpenTrip
    }

    #if DEBUG
    /// For previews and the screenshot test: Home with `past` listed and `routes` drawn, or with `picked`
    /// picked (its route from `routes`), pulled up if `expanded`.
    init(demo past: [PastTrips.Entry], routes: [PastTripRoute], picked: PickedTrip? = nil,
         selecting itemId: String? = nil, expanded: Bool = false, tappable: RecapModel? = nil, tour: Bool = false,
         cameraTour: Bool = false,
         creating createFlow: NewTripFlow? = nil, joining joinStepper: JoinStepper? = nil, nowStatus: [String: String] = [:]) {
        let seeded = HomeModel.launching()
        if let joinStepper {
            seeded.joinFlow = joinStepper
            if let camera = Self.demoJoinCamera(joinStepper) { seeded.listCamera = camera }
        }
        if let createFlow {
            seeded.flow = createFlow
            if let camera = Self.demoCreateCamera(createFlow) { seeded.listCamera = camera }
        }
        seeded.isDemo = true
        seeded.nowStatus = nowStatus
        seeded.past = past
        seeded.routes = routes
        seeded.expanded = expanded
        seeded.picked = picked
        if let picked {
            let (route, camera) = Self.demoPickedCamera(picked, selecting: itemId, routes: routes)
            seeded.fetchedRoute = route
            if let camera { seeded.listCamera = camera }
        } else if let r = PastTripsMapLogic.region(fitting: routes, bottomObscured: Self.obscured(mapHeight: 0).bottom,
                                                   topObscured: Self.obscured(mapHeight: 0).top) {
            seeded.listCamera = .region(r)
        }
        self.init(model: seeded, onNewTrip: {}, onJoin: {})
        _seeded = State(initialValue: seeded)
        _demoModel = State(initialValue: tappable)
        _tour = State(initialValue: tour)
        _cameraTour = State(initialValue: cameraTour)
    }
    #endif

    /// The map's height on screen (it runs under the status bar and the home indicator), from the one map (D63 C4).
    var mapHeight: CGFloat { stage.space.frame.height }

    /// What Home's sheet covers now, as the one cover holds it (written here first, so a camera move made in the same
    /// transaction as a sheet change reads the new one).
    private func sheetCover() -> MapCover {
        let cover = HomeSheet.cover(model.mode, compact: compact)
        stage.cover(cover, from: .home)
        return stage.space.cover(in: .home) ?? cover
    }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .preference(key: TripMapSpecKey.self, value: mapSpec)
            .preference(key: TripSheetSpecKey.self, value: TripSheetSpec(content: AnyView(sheetContent)))
            // Coming back from a trip the camera flies from it to the list; the app's first frame just places it.
            .onAppear {
                // A demo's own model takes the screen's one sheet, at the size it was seeded with.
                if model.sheet !== stage.sheet {
                    let tall = model.expanded
                    model.sheet = stage.sheet
                    model.expanded = tall
                }
                guard stage.entryCamera == .homeList, !stage.entryMoved else { return }
                // Once per appearance (Home is new after a trip): where the phone last knew you were.
                if model.here == nil, !model.isDemo, model.routes.isEmpty { model.here = Self.lastKnownLocation() }
                // The app's first frame (back from a trip, HomeView flies it with the switch, `enteredWithCamera`).
                if let camera = model.entryCamera(mapHeight: mapHeight) {
                    move(to: camera, animated: TripScreenLogic.animatesEntry(mapHasCamera: stage.hasCamera))
                }
            }
            .onChange(of: HomeSheet.cover(model.mode, compact: compact), initial: true) { _, cover in stage.cover(cover, from: .home) }
            .onChange(of: mapHeight) { _, _ in
                // Refit for the real height while the camera is still ours.
                if model.flow != nil { refocusCreate(animated: false) } else if model.joinFlow != nil { refocusJoin(animated: false) } else if model.picked != nil { refocus(animated: false) } else if !model.routes.isEmpty, !stage.camera.positionedByUser { fit(animated: false) } else if model.here != nil, !stage.camera.positionedByUser { showHere(animated: false) }
            }
            // Your location, once it may be read: the first fix (and a real move after it) moves Home's view of you.
            .task(id: locationGranted) { if !model.isDemo, locationGranted { await watchLocation() } }
        .task(id: PastTripsMapLogic.tripsToDraw(model.past).map(\.id)) { if !model.isDemo { await loadRoutes() } }
        .task(id: model.picked?.entry.id) { if !model.isDemo { await loadPicked() } }
        #if DEBUG
        .task(id: tour) {
            await playTour()
        }
        .task(id: cameraTour) { if cameraTour { await playCameraTour() } }
        .overlay(alignment: .top) {
            if cameraTour {
                Text(tourCaption)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.xs)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 70)
                    .accessibilityIdentifier("cameraTour.caption")
                    .allowsHitTesting(false)
            }
        }
        #endif
        .onChange(of: model.creating) { _, now in
            if now { beginCreate() } else if model.flow != nil, !model.finishingCreate { closeCreate() }
        }
        // Before the join request below: a link at launch begins joining with the right motion.
        .onChange(of: reduceMotion, initial: true) { _, now in model.reduceMotion = now }
        .onChange(of: model.joining, initial: true) { _, now in
            if let now { beginJoin(now) } else if model.joinFlow != nil, !model.finishingJoin, !model.isDemo { closeJoin() }
        }
        .onChange(of: model.joinFlow?.model.preview) { _, _ in refocusJoin(animated: true) }
        .onChange(of: model.mode) { old, new in
            let keep = HomeSheet.expanded(model.expanded, from: old, to: new)
            if keep != model.expanded { withAnimation(sheetMotion) { model.expanded = keep } }
        }
        .onChange(of: model.flow?.cameraKey) { _, _ in refocusCreate(animated: true) }
        .onChange(of: model.picked?.model.snapshot != nil) { was, has in
            // The recap arrived, perhaps from Try again: its route is the full one and the dots come with it.
            guard let picked = model.picked, !model.isDemo,
                  PickedTripLogic.shouldRefit(hadSnapshot: was, hasSnapshot: has, itemSelected: picked.selectedItem != nil,
                                              cameraMovedByUser: stage.camera.positionedByUser) else { return }
            refocus(animated: true, settling: true)
        }
        // The name alert belongs to the sheet; when the sheet steps aside it must not come back on its own later.
        .onChange(of: covered) { _, now in
            if now {
                renaming = false
                renameError = nil
                model.coverSheet()
            }
        }
    }

    // MARK: Map

    /// What Home asks the one map to draw: the create flow's pins and route, a picked trip, or where you are plus the
    /// routes of your past trips (the newest in the accent with its name, older ones fainter; tapping a destination
    /// picks that trip). A tap on the map away from a picked trip's route goes back to the list.
    private var mapSpec: TripMapSpec {
        let input: TripMapInput
        if let joinFlow = model.joinFlow {
            input = joinFlow.mapInput
        } else if let flow = model.flow {
            input = .newTrip(places: flow.pins, focusedId: flow.focusTarget?.id,
                             route: flow.ready.map { Polyline.decode($0.route.polyline) } ?? [])
        } else if let picked = model.picked {
            input = .picked(route: model.pickedRoute, dots: PickedTripLogic.markers(picked.model.recap),
                            selectedId: picked.selectedItemId)
        } else {
            input = .home(routes: model.routes, names: Dictionary(model.past.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
        }
        return TripMapSpec(
            input: input,
            style: TripMapStyle(
                onPastTripTap: { id in if let entry = model.past.first(where: { $0.id == id }) { open(entry) } },
                onRecapDotTap: { id in
                    if let item = model.picked?.model.recap?.timeline.first(where: { $0.id == id }) { selectItem(item) }
                }),
            // The logo and Legal ride 10 pt above the short sheet instead of under it, from the first frame, and stay
            // there when the sheet is pulled up (it covers them, as in Apple Maps; owner 2026-10-25, #343).
            // A left trip's short sheet takes them down with it (#437).
            bottomPadding: HomeSheet.legalInset(model.mode, compact: compact),
            hidesControls: true,
            onTap: model.picked != nil ? { closePicked() } : nil)
    }

    /// An ended trip is picked here, on the map; one still running opens on the same map.
    func open(_ entry: PastTrips.Entry) {
        switch model.opening(entry) {
        case .trip(let entry, let started): onOpenTrip(entry, started)
        case .pick(let entry): pick(entry)
        }
    }

    // MARK: Picked trip

    private func pick(_ entry: PastTrips.Entry) {
        var recap: RecapModel?
        #if DEBUG
        recap = demoModel
        #endif
        // The change and its camera move in one call on the screen (D63 C4), as for every Home change below.
        model.pick(entry, camera: stage.camera, recap: recap, on: stage) { refocus(animated: true) }
        AccessibilityNotification.Announcement("Showing \(entry.name) on the map. Back to trips is at the top of the sheet.").post()
    }

    /// Back to the list, with the camera where it was.
    func closePicked() {
        model.closePicked(camera: stage.camera, on: stage) { goBack($0) }
    }

    /// A timeline item: the map goes to it, and the sheet drops to short with the item in it.
    func selectItem(_ item: RecapTimelineItem) {
        model.select(item, on: stage) { refocus(animated: true) }
    }

    /// The X on the item: back to the whole route.
    func showWholeTrip() {
        model.picked?.clearSelection()
        refocus(animated: true)
    }

    /// What the sheet's content change runs on: the camera's motion, or a short crossfade with Reduce Motion.
    private var sheetMotion: Animation? { HomeSheet.motion(reduceMotion: reduceMotion) }

    /// Every camera move on Home goes through the one model's (`TripScreenModel.move`, paced by `CameraPace`, D57).
    func move(to position: MapCameraPosition, animated: Bool) {
        stage.move(to: position, animated: animated, reduceMotion: reduceMotion)
    }

    /// Camera for the picked trip: the selected item's spot, else the whole route, above the short sheet.
    /// `settling`: a refit after the first one (the recap or the full route arrived), skipped when it would only
    /// nudge a picture that is already there.
    private func refocus(animated: Bool, settling: Bool = false) {
        guard let picked = model.picked else { return }
        // Above the short sheet, a left trip's included, whose padding follows it down.
        let insets = Self.obscured(mapHeight: mapHeight, sheet: sheetCover().bottom,
                                   padding: HomeSheet.legalInset(model.mode, compact: compact))
        let region: MKCoordinateRegion?
        if let c = picked.selectedItem?.coordinate {
            region = PickedTripLogic.focus(on: c, bottomObscured: insets.bottom, topObscured: insets.top)
        } else if let route = model.pickedRoute {
            region = PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top)
        } else {
            region = nil
        }
        guard let region else { return }
        if settling, let seen = stage.cameraBox.seen,
           PickedTripLogic.nearlyShown(centerLatitude: seen.camera.centerCoordinate.latitude,
                                       centerLongitude: seen.camera.centerCoordinate.longitude,
                                       latitudeSpan: seen.latitudeDelta, target: region) { return }
        move(to: .region(region), animated: animated)
    }

    /// Loads the picked trip's recap, and its route alone when it is older than the 12 drawn.
    private func loadPicked() async {
        // A trip left early shows only its cached route: the trip and its recap are members-only.
        guard let picked = model.picked, PickedTripLogic.readsServer(picked.entry) else { return }
        let entry = picked.entry
        async let recapLoaded: Void = picked.model.load(myUserId: Auth.auth().currentUser?.uid)
        if !model.routes.contains(where: { $0.id == entry.id }), picked.model.snapshot == nil {
            let one = await PastTripsMapService.load([entry], keeping: false).first
            if !Task.isCancelled, model.picked?.entry.id == entry.id, let one {
                model.fetchedRoute = one
                refocus(animated: true, settling: true)
            }
        }
        await recapLoaded
        // The recap's own route is the full one, and the dots arrive with it.
        if !Task.isCancelled, model.picked?.entry.id == entry.id, picked.selectedItem == nil { refocus(animated: true, settling: true) }
    }

    private func loadRoutes() async {
        let drawn = PastTripsMapLogic.tripsToDraw(model.past)
        guard !drawn.isEmpty else { model.routes = []; return }
        let loaded = await PastTripsMapService.load(drawn)
        guard !Task.isCancelled, loaded != model.routes else { return }
        show(loaded, animated: true)
    }

    private func show(_ list: [PastTripRoute], animated: Bool) {
        let first = model.routes.isEmpty
        model.routes = list
        // Fly only between two fits of routes; the first fit jumps, as a long fly from the
        // user's location is easily cut short by layout or a location fix.
        fit(animated: animated && !first)
    }

    /// Points the camera at every drawn route, above the compact sheet.
    func fit(animated: Bool) {
        guard model.flow == nil, model.joinFlow == nil else { return }
        let insets = Self.obscured(mapHeight: mapHeight)
        guard let region = PastTripsMapLogic.region(fitting: model.routes, bottomObscured: insets.bottom,
                                                    topObscured: insets.top) else { return }
        move(to: .region(region), animated: animated)
    }

    /// Fractions of the map's height kept clear of routes: the status bar plus room for a flag at
    /// the top, and the compact sheet at the bottom (the map runs under both). Before the map has a
    /// height the typical phone height stands in, rather than dividing by zero (which pushed the
    /// fit far south).
    nonisolated static func obscured(mapHeight: CGFloat, sheet: CGFloat = HomeSheet.compactHeight,
                                      padding: CGFloat = HomeSheet.defaultReach) -> (top: Double, bottom: Double) {
        let height = mapHeight > sheet + Self.topObscured ? mapHeight : 874
        // The map's bottom safe-area padding (`HomeSheet.legalInset`) is already kept clear, since MapKit fits
        // inside it; only the part of the sheet above that padding is left for the camera.
        return (Double(Self.topObscured / height), Double(max(0, sheet - padding) / height))
    }

    /// Status bar (about 62 pt) plus a destination flag drawn above its coordinate.
    nonisolated private static let topObscured: CGFloat = 110

    // MARK: Create flow

    /// New trip's gates are through: Where to? takes over the sheet and the map.
    private func beginCreate() {
        model.beginCreate(camera: stage.camera, goBack: goBack, on: stage) { refocusCreate(animated: true) }
    }

    /// Back to Home's list, the camera where it was. Nothing was written.
    private func closeCreate() {
        model.closeCreate(camera: stage.camera, on: stage) { goBack($0) }
    }

    /// The camera for the step on screen: the pin at the top of the list, or the whole route above New trip's sheet.
    /// Before there is a place, the view around you when the camera shows you, else the fixed region it has.
    private func refocusCreate(animated: Bool) {
        guard let flow = model.flow else { return }
        let insets = HomeSheet.createInsets(mapHeight: mapHeight, sheet: sheetCover().bottom, compact: compact)
        let place = flow.region(bottomObscured: insets.bottom, topObscured: insets.top)
        guard let region = HomeCamera.create(place: place, here: model.here, follows: followsFixes(hasPlace: place != nil),
                                             bottomObscured: insets.bottom, topObscured: insets.top) else { return }
        move(to: .region(region), animated: animated)
    }

    // MARK: Your location

    /// Where the phone last knew you were, when location may be read: Home opens on it rather than on the fallback
    /// (back from a trip this view is new, and the live updates take a moment to start).
    static func lastKnownLocation() -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        return manager.location?.coordinate
    }

    private var locationGranted: Bool {
        location.status == .whenInUse || location.status == .always
    }

    /// Whether a fix may move the camera now (`HomeCamera.followsFixes`).
    private func followsFixes(hasPlace: Bool) -> Bool {
        HomeCamera.followsFixes(mode: model.mode, hasRoutes: !model.routes.isEmpty, hasPlace: hasPlace,
                                positionedByUser: stage.camera.positionedByUser)
    }

    /// Reads your location while Home is up. A fix moves the camera only when it is a real move from the last view of
    /// you and the camera shows you; the rest are dropped without touching the view.
    private func watchLocation() async {
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if Task.isCancelled { break }
                guard let fix = update.location, fix.horizontalAccuracy >= 0,
                      HomeCamera.isRealMove(from: model.here, to: fix.coordinate) else { continue }
                model.here = fix.coordinate
                if let flow = model.flow {
                    if followsFixes(hasPlace: flow.focusTarget != nil) { refocusCreate(animated: true) }
                } else if followsFixes(hasPlace: false) {
                    showHere(animated: stage.hasCamera)
                }
            }
        } catch {
            // The stream ended; the camera stays where it is.
        }
    }

    /// Close or Back to trips: where the model says the camera goes (`HomeModel.CameraReturn`).
    private func goBack(_ back: HomeModel.CameraReturn) {
        switch back {
        case .here: showHere(animated: true)
        case .saved(let saved): move(to: saved, animated: true)
        case .stay: break
        }
    }

    /// The list's view of you above its short sheet, when it has no routes to show.
    private func showHere(animated: Bool) {
        guard let here = model.here, model.flow == nil, model.joinFlow == nil, model.picked == nil, model.routes.isEmpty else { return }
        let insets = Self.obscured(mapHeight: mapHeight)
        move(to: .region(HomeCamera.around(here, bottomObscured: insets.bottom, topObscured: insets.top)), animated: animated)
    }

    // MARK: Join flow

    /// Join's gates are through (or a link brought a code): the sheet becomes the join steps and the map shows the trip
    /// once its code is found. A link arriving mid-join must not swap the steps from under the person.
    private func beginJoin(_ start: JoinStart) {
        model.beginJoin(start, camera: stage.camera, displayName: auth.displayName, signedIn: auth.state == .signedIn,
                        location: location.status)
    }

    /// Back to Home's list, the camera where it was. Nothing was written.
    private func closeJoin() {
        model.closeJoin(camera: stage.camera, on: stage) { goBack($0) }
    }

    private func joined(_ tripId: String, tracks: Bool) {
        model.joined(covered: covered)
        onJoined(tripId, tracks)
    }

    /// The camera for a found code: the trip's end above the sheet; nothing before that.
    private func refocusJoin(animated: Bool) {
        guard let joinFlow = model.joinFlow else { return }
        let insets = HomeSheet.createInsets(mapHeight: mapHeight, sheet: sheetCover().bottom, compact: compact)
        guard let region = JoinSteps.region(for: joinFlow.model.preview, bottomObscured: insets.bottom, topObscured: insets.top) else { return }
        move(to: .region(region), animated: animated)
    }

    private func createTrip() {
        Task {
            let id = await model.createTrip(userID: auth.userID, displayName: auth.displayName, covered: covered) { organizer, name, place, route in
                try await TripService.createTrip(name: name, destination: place, route: route, organizer: organizer).tripId
            }
            if let id { onCreated(id) }
        }
    }

    // MARK: Sheet

    /// The short detent's height: one for the list and a picked trip.
    private var compact: CGFloat { HomeSheet.compact(scaled: shortHeight) }

    /// Apple's own sheet over the map: drag it between a short and a tall detent, as in Apple Maps. It is
    /// always up (no dismiss), and the map behind it takes touches while it is short. The name alerts are
    /// presented from here, since a presented sheet blocks a presentation from Home.
    private var sheetContent: some View {
        let compact = compact
        // The header and the scrolling body are one page that crossfades in place, so the sheet (always at the
        // same short height) keeps its size and only its contents change.
        return ZStack(alignment: .top) {
            if let joinFlow = model.joinFlow {
                JoinSheet(stepper: joinFlow, onClose: closeJoin, onJoined: { joined($0, tracks: $1) })
                    .transition(.opacity)
            } else if let flow = model.flow {
                Group {
                    if let ready = flow.ready {
                        NewTripSheet(flow: flow, ready: ready, onBack: { withAnimation(sheetMotion) { flow.back() } },
                                     onClose: closeCreate, onCreate: createTrip)
                    } else {
                        WhereToSheet(flow: flow, onClose: closeCreate)
                    }
                }
                .id(flow.ready == nil ? "create-search" : "create-ready")
                .transition(.opacity)
            } else {
            // The header stays put and the rows fade out under it (the system's soft top edge).
            Group {
                ScrollView {
                    if let picked = model.picked {
                        PickedTripBody(picked: picked, onSelect: selectItem)
                            .padding(.bottom, Spacing.l)
                    } else {
                        pastTrips
                            .padding(.bottom, Spacing.l)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .sheetTopBar {
                if let picked = model.picked {
                    PickedTripHeader(picked: picked, onBack: closePicked, onShowWholeTrip: showWholeTrip)
                } else {
                    HomeHeader(onNewTrip: onNewTrip, onJoin: onJoin, profileName: profileName, barHeight: $barHeight) { name in
                        newName = name
                        settingsShown = true
                    }
                }
            }
            .id(model.picked?.entry.id ?? "")
            .transition(.opacity)
            }
        }
        .animation(sheetMotion, value: model.mode)
        .padding(.horizontal, Spacing.l)
        .padding(.top, HomeSheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(HomeSheet.detents(model.mode, compact: compact), selection: Binding(
            get: { HomeSheet.detent(expanded: model.expanded, mode: model.mode, compact: compact) },
            set: { model.expanded = HomeSheet.isExpanded($0) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: HomeSheet.short(HomeSheet.height(model.mode, compact: compact))))
        .interactiveDismissDisabled()
        .modifier(HomeRenameAlerts(renaming: $renaming, newName: $newName, renameError: $renameError))
        // The name button opens Settings (D72). Its own alerts, since this view's are blocked while it is up.
        .sheet(isPresented: $settingsShown) {
            settingsSheet
                .modifier(HomeRenameAlerts(renaming: $renaming, newName: $newName, renameError: $renameError))
                .presentationDetents([.large])
        }
        #if DEBUG
        .onAppear {
            switch demoAlert {
            case "settings", "settings-design", "settings-design-fonts": settingsShown = true
            case "rename": newName = "Nurul"; renaming = true
            case "rename-error": renameError = "Use 1 to \(DisplayName.maxLength) characters."
            default: break
            }
        }
        #endif
    }

    private var settingsSheet: SettingsSheet {
        let onRename = { newName = profileName ?? ""; renaming = true }
        #if DEBUG
        return SettingsSheet(name: profileName ?? "", tab: demoAlert?.hasPrefix("settings-design") == true ? .design : .you,
                             drill: Self.settingsDrill(demoAlert), onRename: onRename, onClose: { settingsShown = false })
        #else
        return SettingsSheet(name: profileName ?? "", onRename: onRename, onClose: { settingsShown = false })
        #endif
    }

    /// The search bar's height, which the name button is made to match (it grows with the text size).
    @State private var barHeight = SheetSearch.height

    /// "Now" (only when a trip hasn't ended) and "Past trips", each a group of rows on a tile.
    private var pastTrips: some View {
        let parts = HomeNow.split(model.past)
        return VStack(alignment: .leading, spacing: 0) {
            if !parts.now.isEmpty {
                HomeSectionTitle(title: "Now")
                HomeTripGroup(entries: parts.now, open: open) { HomeNowRow(entry: $0, status: model.nowStatus[$0.id]) }
            }
            HomeSectionTitle(title: "Past trips")
            if parts.past.isEmpty {
                // The server has no per-user trip list; PastTrips remembers trips opened on this phone.
                EmptyRow("Trips you start or join will show here.")
                    .foregroundStyle(Color.surfaceSecondary)
                    .surfaceTile(radius: Radius.control)
            } else {
                HomeTripGroup(entries: parts.past, open: open) { HomePastRow(entry: $0) }
            }
        }
        .onAppear { if !model.isDemo { model.reloadPast() } }
        // Starts each time the list appears (and when the trips in Now change), so Now is read once per appearance.
        .task(id: parts.now.map(\.id)) {
            guard !model.isDemo else { return }
            await model.readNow(signedIn: auth.state == .signedIn)
        }
    }

    /// Who the profile button shows: the signed-in name (a demo state shows a sample name).
    private var profileName: String? {
        #if DEBUG
        if model.isDemo { return "Aqlan" }
        #endif
        return auth.state == .signedIn ? auth.displayName : nil
    }
}

#Preview {
    Backend.configure()
    return TripScreenHost(mode: .home) { TripsHomeView(onNewTrip: {}, onJoin: {}) }
        .environment(AuthModel())
}

#Preview("Past trips") {
    Backend.configure()
    // Saved in the preview's own defaults, so the plain preview lists them too after this one has run.
    let day: TimeInterval = 86_400
    PastTrips.record(tripId: "sample-3", name: "Cameron weekend", destination: "Tanah Rata",
                     endedAt: Date().addingTimeInterval(-40 * day), others: ["Wyna"], now: Date().addingTimeInterval(-40 * day))
    PastTrips.record(tripId: "sample-2", name: "Makan trip", destination: "Melaka",
                     endedAt: Date().addingTimeInterval(-9 * day), others: nil, now: Date().addingTimeInterval(-9 * day))
    PastTrips.record(tripId: "sample-1", name: "Balik kampung raya", destination: "Ipoh",
                     endedAt: Date().addingTimeInterval(-day), others: ["Wyna", "Hafiz", "Daniel"])
    return TripScreenHost(mode: .home) { TripsHomeView(onNewTrip: {}, onJoin: {}) }
        .environment(AuthModel())
}

/// The camera a map last reported and when, kept outside the view's state so a glide doesn't redraw Home.
@MainActor
final class CameraBox {
    private(set) var seen: (camera: MapCamera, latitudeDelta: Double)?

    func record(_ camera: MapCamera, latitudeDelta: Double) {
        seen = (camera, latitudeDelta)
    }
}
