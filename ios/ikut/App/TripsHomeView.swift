import FirebaseAuth
import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are and the routes of
/// your past trips, under Apple's own sheet with Where to?, Join with a code, the trips now running and past trips.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    var onNewTrip: () -> Void
    var onJoin: () -> Void
    /// A trip that hasn't ended opens its lobby; an ended one is picked on this map instead.
    var onOpenTrip: (PastTrips.Entry) -> Void = { _ in }
    /// A pushed screen or a sheet of the parent is up: Home's sheet steps aside (a sheet is presented
    /// over Home, so it would sit over them) and comes back when this is false again.
    var covered = false
    /// Follows whether the sheet is on screen (set when it appears, cleared once it has gone), for the parent.
    var sheetUp: Binding<Bool> = .constant(false)
    /// New trip was tapped and its gates (name, location) are through: the sheet becomes Where to? over this map.
    /// Cleared again when the flow closes or the trip is made.
    var creating: Binding<Bool> = .constant(false)
    /// The trip was made: its id, to open its lobby.
    var onCreated: (String) -> Void = { _ in }

    /// The create flow (Where to?, then New trip) over this map; nil while the sheet shows its list.
    @State private var flow: NewTripFlow?
    /// Where the camera was before the flow, for Close.
    @State private var cameraBeforeCreate: MapCameraPosition?
    /// The trip was made and its lobby is being pushed: the flow stays until Home's sheet is covered, so the list never flashes.
    @State private var finishingCreate = false

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    /// The sheet is at its tall detent (the detent selection reads and writes it).
    @State private var expanded = false
    @State private var past: [PastTrips.Entry] = []
    /// The status line of each trip in Now (one read when the list appears), by trip id.
    @State private var nowStatus: [String: String] = [:]
    /// Routes of the newest ended trips, drawn on the map (newest first).
    @State private var routes: [PastTripRoute] = []
    @State private var camera: MapCameraPosition
    @State private var mapHeight: CGFloat = 0
    /// The camera as it last moved, to tell whether a late refit would only nudge it (not state: it changes every
    /// frame of a glide).
    @State private var cameraBox = CameraBox()
    /// The past trip picked on the map, whose recap fills the sheet.
    @State private var picked: PickedTrip?
    /// Its route when it is older than the 12 drawn and the recap hasn't loaded yet.
    @State private var fetchedRoute: PastTripRoute?
    /// Where the camera was before picking, for Back.
    @State private var cameraBeforePick: MapCameraPosition?
    /// The short sheet's height, the same for the list and a picked trip so a pick never resizes it. Follows the
    /// text size and nothing else.
    @ScaledMetric(relativeTo: .body) private var shortHeight: CGFloat = HomeSheet.compactHeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Screenshot demo (`init(demo:)`): shows what it was given, and reads nothing from the phone or the server.
    @State private var isDemo = false
    #if DEBUG
    /// Demo that can be tapped through: picking a trip gives it this recap (no server). `tour` also picks the
    /// first trip and closes it again by itself (the second time pulling it up and down first), so a recording needs no taps.
    @State private var demoModel: RecapModel?
    @State private var tour = false
    #endif

    init(onNewTrip: @escaping () -> Void, onJoin: @escaping () -> Void,
         onOpenTrip: @escaping (PastTrips.Entry) -> Void = { _ in }, covered: Bool = false,
         sheetUp: Binding<Bool> = .constant(false), creating: Binding<Bool> = .constant(false),
         onCreated: @escaping (String) -> Void = { _ in }) {
        self.covered = covered
        self.sheetUp = sheetUp
        self.creating = creating
        self.onCreated = onCreated
        self.onNewTrip = onNewTrip
        self.onJoin = onJoin
        self.onOpenTrip = onOpenTrip
        // Open on the cached past routes when there are any: a later switch away from
        // `.userLocation` can lose to the first location fix.
        let cache = PastTripsMapService.cachedRoutes()
        let cached = PastTripsMapLogic.tripsToDraw(PastTrips.all()).compactMap { cache[$0.id] }
        let insets = Self.obscured(mapHeight: 0)
        if let region = PastTripsMapLogic.region(fitting: cached, bottomObscured: insets.bottom, topObscured: insets.top) {
            _camera = State(initialValue: .region(region))
            _routes = State(initialValue: cached)
        } else {
            _camera = State(initialValue: .userLocation(fallback: .region(Self.fallback)))
        }
    }

    #if DEBUG
    /// For previews and the screenshot test: Home with `past` listed and `routes` drawn, or with `picked`
    /// picked (its route from `routes`), pulled up if `expanded`.
    init(demo past: [PastTrips.Entry], routes: [PastTripRoute], picked: PickedTrip? = nil,
         selecting itemId: String? = nil, expanded: Bool = false, tappable: RecapModel? = nil, tour: Bool = false,
         creating createFlow: NewTripFlow? = nil, nowStatus: [String: String] = [:]) {
        self.init(onNewTrip: {}, onJoin: {})
        if let createFlow {
            _flow = State(initialValue: createFlow)
            let insets = HomeSheet.createInsets(
                mapHeight: 0, sheet: HomeSheet.height(HomeSheet.mode(flow: createFlow), compact: HomeSheet.compactHeight),
                compact: HomeSheet.compactHeight)
            if let region = createFlow.region(bottomObscured: insets.bottom, topObscured: insets.top) {
                _camera = State(initialValue: .region(region))
            }
        }
        _isDemo = State(initialValue: true)
        _nowStatus = State(initialValue: nowStatus)
        _demoModel = State(initialValue: tappable)
        _tour = State(initialValue: tour)
        _past = State(initialValue: past)
        _routes = State(initialValue: routes)
        _expanded = State(initialValue: expanded)
        _picked = State(initialValue: picked)
        if let picked {
            if let itemId, let item = picked.model.recap?.timeline.first(where: { $0.id == itemId }) { picked.select(item) }
            let route = PickedTripLogic.route(for: picked.entry, snapshot: picked.model.snapshot, drawn: routes, fetched: nil)
            _fetchedRoute = State(initialValue: route)
            let insets = Self.obscured(mapHeight: 0)
            if let c = picked.selectedItem?.coordinate {
                _camera = State(initialValue: .region(PickedTripLogic.focus(on: c, bottomObscured: insets.bottom, topObscured: insets.top)))
            } else if let route, let r = PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top) {
                _camera = State(initialValue: .region(r))
            }
        } else if let r = PastTripsMapLogic.region(fitting: routes, bottomObscured: Self.obscured(mapHeight: 0).bottom,
                                                   topObscured: Self.obscured(mapHeight: 0).top) {
            _camera = State(initialValue: .region(r))
        }
    }
    #endif

    /// Where the map opens when location isn't available yet.
    private static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))

    var body: some View {
        ZStack {
            map
        }
        .task(id: PastTripsMapLogic.tripsToDraw(past).map(\.id)) { if !isDemo { await loadRoutes() } }
        .task(id: picked?.entry.id) { if !isDemo { await loadPicked() } }
        #if DEBUG
        .task(id: tour) {
            guard tour, let first = past.first else { return }
            for cycle in 0..<2 {
                try? await Task.sleep(for: .seconds(2.5))
                open(first)
                try? await Task.sleep(for: .seconds(3.5))
                if cycle == 1 {
                    // Pulled up and back down, to see that the map and Legal stay put under the tall sheet.
                    expanded = true
                    try? await Task.sleep(for: .seconds(3))
                    expanded = false
                    try? await Task.sleep(for: .seconds(2.5))
                }
                closePicked()
            }
        }
        #endif
        .onChange(of: creating.wrappedValue) { _, now in
            if now { beginCreate() } else if flow != nil, !finishingCreate { closeCreate() }
        }
        .onChange(of: mode) { old, new in
            let keep = HomeSheet.expanded(expanded, from: old, to: new)
            if keep != expanded { withAnimation(sheetMotion) { expanded = keep } }
        }
        .onChange(of: flow?.cameraKey) { _, _ in refocusCreate(animated: true) }
        .onChange(of: picked?.model.snapshot != nil) { was, has in
            // The recap arrived, perhaps from Try again: its route is the full one and the dots come with it.
            guard let picked, !isDemo,
                  PickedTripLogic.shouldRefit(hadSnapshot: was, hasSnapshot: has, itemSelected: picked.selectedItem != nil,
                                              cameraMovedByUser: camera.positionedByUser) else { return }
            refocus(animated: true, settling: true)
        }
        .sheet(isPresented: Binding(get: { !covered }, set: { _ in }), onDismiss: { sheetUp.wrappedValue = false }) {
            sheetContent.onAppear { sheetUp.wrappedValue = true }
        }
        // The name alert belongs to the sheet; when the sheet steps aside it must not come back on its own later.
        .onChange(of: covered) { _, now in
            if now {
                renaming = false
                renameError = nil
                if finishingCreate {
                    finishingCreate = false
                    flow = nil
                    cameraBeforeCreate = nil
                }
            }
        }
    }

    // MARK: Map

    /// Where you are, plus the routes of your past trips. The newest is drawn in the accent with
    /// its name; older ones are fainter. Tapping a destination opens that trip's recap.
    private var map: some View {
        Map(position: $camera) {
            if let flow {
                NewTripMapContent.content(flow)
            } else if let picked {
                pickedContent(picked)
            } else {
                UserAnnotation()
                // Oldest first so the newest draws on top.
                ForEach(Array(routes.enumerated().reversed()), id: \.element.id) { index, route in
                    routeContent(route, latest: index == 0)
                }
            }
        }
        // Tapping the map away from the route goes back to the list.
        .onTapGesture { if picked != nil { closePicked() } }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .continuous) { cameraBox.record($0.camera, latitudeDelta: $0.region.span.latitudeDelta) }
        // The logo and Legal ride 10 pt above the short sheet instead of under it, from the first frame, and stay
        // there when the sheet is pulled up (it covers them, as in Apple Maps; owner 2026-10-25, #343). The padding
        // goes on the Map itself, before it ignores the safe area, as on the driving map.
        .safeAreaPadding(.bottom, HomeSheet.legalInset(compact: compact))
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            guard height != mapHeight else { return }
            mapHeight = height
            // Refit for the real height while the camera is still ours.
            if flow != nil { refocusCreate(animated: false) } else if picked != nil { refocus(animated: false) } else if !routes.isEmpty, !camera.positionedByUser { fit(animated: false) }
        }
    }

    @MapContentBuilder
    private func routeContent(_ route: PastTripRoute, latest: Bool) -> some MapContent {
        let line = route.coordinates
        if line.count > 1 {
            MapPolyline(coordinates: line)
                .stroke(.white.opacity(latest ? 0.9 : 0.6),
                        style: StrokeStyle(lineWidth: latest ? 9 : 6, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: line)
                .stroke(Color.ikutAccent.opacity(latest ? 1 : 0.45),
                        style: StrokeStyle(lineWidth: latest ? 5 : 3, lineCap: .round, lineJoin: .round))
        }
        if let start = route.start {
            Annotation("", coordinate: start, anchor: .center) {
                Circle().fill(.white).frame(width: latest ? 12 : 9, height: latest ? 12 : 9)
                    .overlay(Circle().stroke(Color.ikutAccent.opacity(latest ? 1 : 0.6), lineWidth: latest ? 3 : 2))
                    .accessibilityHidden(true)
            }
            .annotationTitles(.hidden)
        }
        Annotation(displayName(route), coordinate: route.destination, anchor: .center) {
            Button { open(route) } label: {
                Image(systemName: "flag.checkered")
                    .font(.system(size: latest ? 13 : 10, weight: .bold))
                    .foregroundStyle(latest ? .white : Color.ikutAccent)
                    .frame(width: latest ? 30 : 22, height: latest ? 30 : 22)
                    .background(latest ? Color.ikutAccent : Color.white, in: Circle())
                    .overlay(Circle().stroke(latest ? Color.white : Color.ikutAccent.opacity(0.6), lineWidth: 2))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(displayName(route)), to \(route.destinationName)")
            .accessibilityHint("Shows the trip on the map")
        }
        .annotationTitles(latest ? .automatic : .hidden)
    }

    /// The name Home lists for the trip (it may have been renamed since the route was cached).
    private func displayName(_ route: PastTripRoute) -> String {
        past.first(where: { $0.id == route.id })?.name ?? route.name
    }

    private func open(_ route: PastTripRoute) {
        if let entry = past.first(where: { $0.id == route.id }) { open(entry) }
    }

    /// An ended trip is picked here, on the map; one still running opens its lobby.
    private func open(_ entry: PastTrips.Entry) {
        guard entry.endedAt != nil else { onOpenTrip(entry); return }
        pick(entry)
    }

    // MARK: Picked trip

    /// Only the picked trip's route, with its stops and road reports, and a flag at the destination.
    @MapContentBuilder
    private func pickedContent(_ picked: PickedTrip) -> some MapContent {
        if let route = pickedRoute(picked) {
            let line = route.coordinates
            if line.count > 1 {
                MapPolyline(coordinates: line)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: line)
                    .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = route.start {
                Annotation("", coordinate: start, anchor: .center) {
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.ikutAccent, lineWidth: 3))
                        .accessibilityHidden(true)
                }
                .annotationTitles(.hidden)
            }
            Annotation(route.destinationName, coordinate: route.destination, anchor: .center) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Color.ikutAccent, in: Circle())
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    .accessibilityHidden(true)
            }
            .annotationTitles(.visible)
        }
        ForEach(PickedTripLogic.markers(picked.model.recap)) { item in
            let selected = picked.selectedItemId == item.id
            Annotation(PickedTripLogic.pinLabel(item), coordinate: item.coordinate!, anchor: .center) {
                // A tap selects it like its timeline row (and doesn't fall through to the map's tap-away).
                Button { selectItem(item) } label: {
                    RecapEventDot(kind: item.kind, symbol: item.symbol, size: selected ? 30 : 22, selected: selected)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PickedTripLogic.pinLabel(item))
                .accessibilityHint("Shows it on the map")
            }
            .annotationTitles(selected ? .visible : .hidden)
        }
    }

    private func pickedRoute(_ picked: PickedTrip) -> PastTripRoute? {
        PickedTripLogic.route(for: picked.entry, snapshot: picked.model.snapshot, drawn: routes, fetched: fetchedRoute)
    }

    private func pick(_ entry: PastTrips.Entry) {
        cameraBeforePick = camera
        fetchedRoute = nil
        withAnimation(sheetMotion) {
            expanded = false
            picked = pickedTrip(for: entry)
        }
        refocus(animated: true)
        AccessibilityNotification.Announcement("Showing \(entry.name) on the map. Back to trips is at the top of the sheet.").post()
    }

    private func pickedTrip(for entry: PastTrips.Entry) -> PickedTrip {
        #if DEBUG
        if let demoModel { return PickedTrip(entry: entry, model: demoModel) }
        #endif
        return PickedTrip(entry: entry)
    }

    /// Back to the list, with the camera where it was.
    private func closePicked() {
        guard picked != nil else { return }
        withAnimation(sheetMotion) {
            picked = nil
            expanded = false
        }
        fetchedRoute = nil
        if let before = cameraBeforePick { move(to: before, animated: true) }
        cameraBeforePick = nil
    }

    /// A timeline item: the map goes to it, and the sheet drops to short with the item in it.
    private func selectItem(_ item: RecapTimelineItem) {
        guard let picked else { return }
        picked.select(item)
        withAnimation(sheetMotion) { expanded = false }
        refocus(animated: true)
    }

    /// The X on the item: back to the whole route.
    private func showWholeTrip() {
        picked?.clearSelection()
        refocus(animated: true)
    }

    /// What the sheet's content change runs on: the camera's motion, or a short crossfade with Reduce Motion.
    private var sheetMotion: Animation? { HomeSheet.motion(reduceMotion: reduceMotion) }

    /// Every camera move on Home goes through here: the same motion as the sheet's content change, and a jump
    /// with Reduce Motion.
    private func move(to position: MapCameraPosition, animated: Bool) {
        if animated, !reduceMotion { withAnimation(sheetMotion) { camera = position } } else { camera = position }
    }

    /// Camera for the picked trip: the selected item's spot, else the whole route, above the short sheet.
    /// `settling`: a refit after the first one (the recap or the full route arrived), skipped when it would only
    /// nudge a picture that is already there.
    private func refocus(animated: Bool, settling: Bool = false) {
        guard let picked else { return }
        let insets = Self.obscured(mapHeight: mapHeight, sheet: compact, padding: HomeSheet.legalInset(compact: compact))
        let region: MKCoordinateRegion?
        if let c = picked.selectedItem?.coordinate {
            region = PickedTripLogic.focus(on: c, bottomObscured: insets.bottom, topObscured: insets.top)
        } else if let route = pickedRoute(picked) {
            region = PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top)
        } else {
            region = nil
        }
        guard let region else { return }
        if settling, let seen = cameraBox.seen,
           PickedTripLogic.nearlyShown(centerLatitude: seen.camera.centerCoordinate.latitude,
                                       centerLongitude: seen.camera.centerCoordinate.longitude,
                                       latitudeSpan: seen.latitudeDelta, target: region) { return }
        move(to: .region(region), animated: animated)
    }

    /// Loads the picked trip's recap, and its route alone when it is older than the 12 drawn.
    private func loadPicked() async {
        guard let picked else { return }
        let entry = picked.entry
        async let recapLoaded: Void = picked.model.load(myUserId: Auth.auth().currentUser?.uid)
        if !routes.contains(where: { $0.id == entry.id }), picked.model.snapshot == nil {
            let one = await PastTripsMapService.load([entry], keeping: false).first
            if !Task.isCancelled, self.picked?.entry.id == entry.id, let one {
                fetchedRoute = one
                refocus(animated: true, settling: true)
            }
        }
        await recapLoaded
        // The recap's own route is the full one, and the dots arrive with it.
        if !Task.isCancelled, self.picked?.entry.id == entry.id, picked.selectedItem == nil { refocus(animated: true, settling: true) }
    }

    private func loadRoutes() async {
        let drawn = PastTripsMapLogic.tripsToDraw(past)
        guard !drawn.isEmpty else { routes = []; return }
        let loaded = await PastTripsMapService.load(drawn)
        guard !Task.isCancelled, loaded != routes else { return }
        show(loaded, animated: true)
    }

    private func show(_ list: [PastTripRoute], animated: Bool) {
        let first = routes.isEmpty
        routes = list
        // Fly only between two fits of routes; the first fit jumps, as a long fly from the
        // user's location is easily cut short by layout or a location fix.
        fit(animated: animated && !first)
    }

    /// Points the camera at every drawn route, above the compact sheet.
    private func fit(animated: Bool) {
        guard flow == nil else { return }
        let insets = Self.obscured(mapHeight: mapHeight)
        guard let region = PastTripsMapLogic.region(fitting: routes, bottomObscured: insets.bottom,
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

    private var mode: HomeSheet.Mode { HomeSheet.mode(flow: flow) }

    /// New trip's gates are through: Where to? takes over the sheet and the map.
    private func beginCreate() {
        guard flow == nil else { return }
        cameraBeforeCreate = camera
        if picked != nil { closePicked() }
        withAnimation(sheetMotion) {
            expanded = false
            flow = NewTripFlow()
        }
    }

    /// Back to Home's list, the camera where it was. Nothing was written.
    private func closeCreate() {
        flow?.cancel()
        withAnimation(sheetMotion) {
            flow = nil
            expanded = false
        }
        creating.wrappedValue = false
        if let before = cameraBeforeCreate { move(to: before, animated: true) }
        cameraBeforeCreate = nil
    }

    /// The camera for the step on screen: the pin at the top of the list, or the whole route above New trip's sheet.
    private func refocusCreate(animated: Bool) {
        guard let flow else { return }
        let sheet = HomeSheet.height(mode, compact: compact)
        let insets = HomeSheet.createInsets(mapHeight: mapHeight, sheet: sheet, compact: compact)
        guard let region = flow.region(bottomObscured: insets.bottom, topObscured: insets.top) else { return }
        move(to: .region(region), animated: animated)
    }

    private func createTrip() {
        guard let flow else { return }
        guard let uid = auth.userID else {
            flow.createError = "Couldn’t sign you in. Check your signal and try again."
            return
        }
        let organizer = TripOrganizer(id: uid, displayName: auth.displayName ?? "Organizer")
        Task {
            let id = await flow.create { name, place, route in
                try await TripService.createTrip(name: name, destination: place, route: route, organizer: organizer).tripId
            }
            guard let id else { return }
            flow.search.errorMessage = nil
            finishingCreate = true
            creating.wrappedValue = false
            onCreated(id)
            // Demo and tests have no parent to cover the sheet.
            if !covered, isDemo { finishingCreate = false; self.flow = nil }
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
            if let flow {
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
                    if let picked {
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
                if let picked {
                    PickedTripHeader(picked: picked, onBack: closePicked, onShowWholeTrip: showWholeTrip)
                } else {
                    header
                }
            }
            .id(picked?.entry.id ?? "")
            .transition(.opacity)
            }
        }
        .animation(sheetMotion, value: mode)
        .padding(.horizontal, Spacing.l)
        .padding(.top, HomeSheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(HomeSheet.detents(mode, compact: compact), selection: Binding(
            get: { HomeSheet.detent(expanded: expanded, mode: mode, compact: compact) },
            set: { expanded = HomeSheet.isExpanded($0) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: HomeSheet.short(HomeSheet.height(mode, compact: compact))))
        .interactiveDismissDisabled()
        .alert("Your name", isPresented: $renaming) {
            TextField("Your name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
        } message: {
            Text("What the convoy sees in new trips.")
        }
        .alert("Couldn’t change your name", isPresented: .constant(renameError != nil)) {
            Button("OK") { renameError = nil }
        } message: {
            Text(renameError ?? "")
        }
    }

    /// The search bar's height, which the name button is made to match (it grows with the text size).
    @State private var barHeight = SheetSearch.height

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            // Apple Maps' top row: the search bar and the name's avatar. Tapping the bar starts the same flow, in
            // Where to?, where the bar becomes editable.
            HStack(spacing: Spacing.gap) {
                SheetSearchButton(placeholder: "Where to?", action: onNewTrip)
                    .trackingHeight($barHeight)
                    .accessibilityIdentifier("homeWhereTo")
                profileButton
            }
            .padding(.top, Spacing.xs)

            Button(action: onJoin) {
                HStack(spacing: Spacing.m) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color(.label).opacity(0.9), in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                        .accessibilityHidden(true)
                    Text("Join with a code").font(.body.weight(.medium)).foregroundStyle(.primary)
                    Spacer(minLength: Spacing.s)
                    Text("or scan").font(.subheadline).foregroundStyle(Color.surfaceSecondary)
                }
                .padding(.horizontal, Spacing.m)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
                .surfaceTile(radius: Radius.control)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("homeJoin")
        }
    }

    /// "Now" (only when a trip hasn't ended) and "Past trips", each a group of rows on a tile.
    private var pastTrips: some View {
        let parts = HomeNow.split(past)
        return VStack(alignment: .leading, spacing: 0) {
            if !parts.now.isEmpty {
                sectionTitle("Now")
                group(parts.now) { nowRow($0) }
            }
            sectionTitle("Past trips")
            if parts.past.isEmpty {
                // The server has no per-user trip list; PastTrips remembers trips opened on this phone.
                EmptyRow("Trips you start or join will show here.")
                    .foregroundStyle(Color.surfaceSecondary)
                    .surfaceTile(radius: Radius.control)
            } else {
                group(parts.past) { pastRow($0) }
            }
        }
        .onAppear { if !isDemo { past = PastTrips.all() } }
        // Starts each time the list appears (and when the trips in Now change), so Now is read once per appearance.
        .task(id: parts.now.map(\.id)) {
            guard !isDemo else { return }
            for entry in parts.now {
                let read = await HomeNow.load(tripId: entry.id)
                if Task.isCancelled { return }
                if let endedAt = read.endedAt {
                    // It ended while this phone wasn't in it: remember that, and it moves to Past trips.
                    PastTrips.record(tripId: entry.id, name: read.name ?? entry.name,
                                     destination: read.destination ?? entry.destination, endedAt: endedAt)
                    past = PastTrips.all()
                } else {
                    nowStatus[entry.id] = read.line
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.surfaceSecondary)
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.m)
            .padding(.bottom, Spacing.xs)
            .accessibilityAddTraits(.isHeader)
    }

    private func group(_ entries: [PastTrips.Entry], row: @escaping (PastTrips.Entry) -> some View) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                if index > 0 { RowDivider() }
                Button { open(entry) } label: { row(entry) }
                    .buttonStyle(.plain)
            }
        }
        .surfaceTile(radius: Radius.control)
    }

    private func nowRow(_ entry: PastTrips.Entry) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "flag.checkered")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.ikutAccent, in: RoundedRectangle(cornerRadius: Radius.icon, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(nowStatus[entry.id] ?? HomeNow.fallbackStatus)
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).lineLimit(2)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.surfaceSecondary)
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the trip")
    }

    private func pastRow(_ entry: PastTrips.Entry) -> some View {
        HStack(spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(PastTrips.withPhrase(entry.others) ?? PickedTripLogic.subtitle(entry))
                    .font(.footnote).foregroundStyle(Color.surfaceSecondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if let ended = entry.endedAt {
                Text(ended.formatted(.dateTime.day().month(.abbreviated)))
                    .font(.subheadline).foregroundStyle(Color.surfaceSecondary)
            }
        }
        .padding(.horizontal, Spacing.m)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the trip on the map")
    }

    @ViewBuilder
    private var profileButton: some View {
        if let name = profileName {
            RoundGlassIconButton(text: name.prefix(1).uppercased(), label: "Your name and settings", size: barHeight, exact: true) {
                newName = name
                renaming = true
            }
        }
    }

    /// Who the profile button shows: the signed-in name (a demo state shows a sample name).
    private var profileName: String? {
        #if DEBUG
        if isDemo { return "Aqlan" }
        #endif
        return auth.state == .signedIn ? auth.displayName : nil
    }

    private func saveName() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .success = DisplayName.validate(trimmed) else {
            renameError = "Use 1 to \(DisplayName.maxLength) characters."
            return
        }
        Task {
            do { try await auth.updateDisplayName(trimmed) } catch { renameError = error.localizedDescription }
        }
    }
}

#Preview {
    Backend.configure()
    return TripsHomeView(onNewTrip: {}, onJoin: {})
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
    return TripsHomeView(onNewTrip: {}, onJoin: {})
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
