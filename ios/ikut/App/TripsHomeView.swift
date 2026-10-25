import FirebaseAuth
import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are and the routes of
/// your past trips, under Apple's own sheet with New trip, Join trip and past trips.
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

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    /// The sheet is at its tall detent (the detent selection reads and writes it).
    @State private var expanded = false
    @State private var past: [PastTrips.Entry] = []
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
         sheetUp: Binding<Bool> = .constant(false)) {
        self.covered = covered
        self.sheetUp = sheetUp
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
         selecting itemId: String? = nil, expanded: Bool = false, tappable: RecapModel? = nil, tour: Bool = false) {
        self.init(onNewTrip: {}, onJoin: {})
        _isDemo = State(initialValue: true)
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
            if now { renaming = false; renameError = nil }
        }
    }

    // MARK: Map

    /// Where you are, plus the routes of your past trips. The newest is drawn in the accent with
    /// its name; older ones are fainter. Tapping a destination opens that trip's recap.
    private var map: some View {
        Map(position: $camera) {
            if let picked {
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
            if picked != nil { refocus(animated: false) } else if !routes.isEmpty, !camera.positionedByUser { fit(animated: false) }
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
            VStack(alignment: .leading, spacing: 0) {
                if let picked {
                    PickedTripHeader(picked: picked, onBack: closePicked, onShowWholeTrip: showWholeTrip)
                } else {
                    header
                }
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
            .id(picked?.entry.id ?? "")
            .transition(.opacity)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, HomeSheet.indicatorRoom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .presentationDetents(HomeSheet.detents(compact: compact), selection: Binding(
            get: { HomeSheet.detent(expanded: expanded, compact: compact) },
            set: { expanded = HomeSheet.isExpanded($0) }))
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(.enabled(upThrough: HomeSheet.short(compact)))
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The title row, with the profile button at its top right as in Apple Maps.
            HStack(alignment: .center, spacing: Spacing.s) {
                Text("Trips")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, Spacing.xs)
                    .accessibilityAddTraits(.isHeader)
                    .frame(maxWidth: .infinity, alignment: .leading)
                profileButton
            }
            .frame(minHeight: 44)

            HStack(spacing: Spacing.gap) {
                Button(action: onNewTrip) {
                    Label("New trip", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .actionButton(.primary, onGlass: true)
                Button(action: onJoin) {
                    Label("Join trip", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .actionButton(.secondary, onGlass: true)
            }
            .padding(.top, Spacing.m)
        }
    }

    private var pastTrips: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardHeader("Past trips", top: Spacing.sectionLarge)
            if past.isEmpty {
                // The server has no per-user trip list; PastTrips remembers trips opened on this phone.
                EmptyRow("Trips you start or join will show here.")
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(past.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { RowDivider() }
                        Button { open(entry) } label: { pastRow(entry) }
                            .buttonStyle(.plain)
                    }
                }
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        }
        .onAppear { if !isDemo { past = PastTrips.all() } }
    }

    private func pastRow(_ entry: PastTrips.Entry) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: entry.endedAt == nil ? "car.fill" : "flag.checkered")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(entry.endedAt == nil ? Color.ikutPositive : Color.ikutAccent, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(PastTrips.withPhrase(entry.others) ?? pastDetail(entry)).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Spacing.l)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.endedAt == nil ? "Opens the trip" : "Shows the trip on the map")
    }

    private func pastDetail(_ entry: PastTrips.Entry) -> String {
        guard entry.endedAt != nil else { return "To \(entry.destination) · in progress" }
        return PickedTripLogic.subtitle(entry)
    }

    @ViewBuilder
    private var profileButton: some View {
        if let name = profileName {
            Menu {
                Section(name) {
                    Button("Change name", systemImage: "pencil") {
                        newName = name
                        renaming = true
                    }
                }
                #if DEBUG
                Section(Backend.current.label) {}
                #endif
            } label: {
                Text(name.prefix(1).uppercased())
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .background(Color(.tertiarySystemFill), in: Circle())
                    .contentShape(Circle())
            }
            .tint(.primary)
            .accessibilityLabel("Profile, \(name)")
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
