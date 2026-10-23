import FirebaseAuth
import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are and the routes of
/// your past trips, under a floating glass sheet with New Trip, Join Trip and past trips.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    var onNewTrip: () -> Void
    var onJoin: () -> Void
    /// A trip that hasn't ended opens its lobby; an ended one is picked on this map instead.
    var onOpenTrip: (PastTrips.Entry) -> Void = { _ in }

    @State private var renaming = false
    @State private var newName = ""
    @State private var renameError: String?
    @State private var expanded = false
    /// Springs back with the detent change when the drag ends, rather than snapping to the old
    /// detent for a frame first.
    @GestureState(resetTransaction: Transaction(animation: .snappy)) private var dragOffset: CGFloat = 0
    @State private var past: [PastTrips.Entry] = []
    /// Routes of the newest ended trips, drawn on the map (newest first).
    @State private var routes: [PastTripRoute] = []
    @State private var camera: MapCameraPosition
    @State private var mapHeight: CGFloat = 0
    /// The past trip picked on the map, whose recap fills the sheet.
    @State private var picked: PickedTrip?
    /// Its route when it is older than the 12 drawn and the recap hasn't loaded yet.
    @State private var fetchedRoute: PastTripRoute?
    /// Where the camera was before picking, for Back.
    @State private var cameraBeforePick: MapCameraPosition?
    /// Height of the short sheet while a trip is picked: it holds the stats line, so it follows the text size.
    @State private var pickedCompact: CGFloat = TripsHomeView.pickedCompactMinimum
    /// Height of the pinned part of the sheet (grabber and header), measured.
    @State private var pinnedHeight: CGFloat = 0

    init(onNewTrip: @escaping () -> Void, onJoin: @escaping () -> Void,
         onOpenTrip: @escaping (PastTrips.Entry) -> Void = { _ in }) {
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

    /// Where the map opens when location isn't available yet.
    private static let fallback = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687),
        span: MKCoordinateSpan(latitudeDelta: 1.2, longitudeDelta: 1.2))

    var body: some View {
        ZStack {
            map
            sheet
        }
        .task(id: PastTripsMapLogic.tripsToDraw(past).map(\.id)) { await loadRoutes() }
        .task(id: picked?.entry.id) { await loadPicked() }
        .overlay(alignment: .topTrailing) { profileButton }
        .alert("Your name", isPresented: $renaming) {
            TextField("Your name", text: $newName)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveName() }
        } message: {
            Text("What the convoy sees in new trips.")
        }
        .alert("Couldn't change your name", isPresented: .constant(renameError != nil)) {
            Button("OK") { renameError = nil }
        } message: {
            Text(renameError ?? "")
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
            Annotation(item.title, coordinate: item.coordinate!, anchor: .center) {
                RecapEventDot(kind: item.kind, symbol: item.symbol, size: selected ? 30 : 22, selected: selected)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
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
        withAnimation(.snappy) {
            expanded = false
            picked = PickedTrip(entry: entry)
        }
        refocus(animated: true)
        AccessibilityNotification.Announcement("Showing \(entry.name) on the map. Back to trips is at the top of the sheet.").post()
    }

    /// Back to the list, with the camera where it was.
    private func closePicked() {
        guard picked != nil else { return }
        withAnimation(.snappy) {
            picked = nil
            expanded = false
        }
        fetchedRoute = nil
        if let before = cameraBeforePick {
            withAnimation(.smooth(duration: 0.8)) { camera = before }
        }
        cameraBeforePick = nil
    }

    /// A timeline item: the map goes to it, and the sheet drops to short with the item in it.
    private func selectItem(_ item: RecapTimelineItem) {
        guard let picked else { return }
        picked.select(item)
        withAnimation(.snappy) { expanded = false }
        refocus(animated: true)
    }

    /// The X on the item: back to the whole route.
    private func showWholeTrip() {
        picked?.clearSelection()
        refocus(animated: true)
    }

    /// Camera for the picked trip: the selected item's spot, else the whole route, above the short sheet.
    private func refocus(animated: Bool) {
        guard let picked else { return }
        let insets = Self.obscured(mapHeight: mapHeight, sheet: pickedCompact)
        let region: MKCoordinateRegion?
        if let c = picked.selectedItem?.coordinate {
            region = PickedTripLogic.focus(on: c, bottomObscured: insets.bottom, topObscured: insets.top)
        } else if let route = pickedRoute(picked) {
            region = PickedTripLogic.fit(route, bottomObscured: insets.bottom, topObscured: insets.top)
        } else {
            region = nil
        }
        guard let region else { return }
        if animated { withAnimation(.smooth(duration: 0.8)) { camera = .region(region) } } else { camera = .region(region) }
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
                refocus(animated: true)
            }
        }
        await recapLoaded
        // The recap's own route is the full one, and the dots arrive with it.
        if !Task.isCancelled, self.picked?.entry.id == entry.id, picked.selectedItem == nil { refocus(animated: true) }
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
        if animated {
            withAnimation(.smooth(duration: 0.8)) { camera = .region(region) }
        } else {
            camera = .region(region)
        }
    }

    /// Fractions of the map's height kept clear of routes: the status bar plus room for a flag at
    /// the top, and the compact sheet at the bottom (the map runs under both). Before the map has a
    /// height the typical phone height stands in, rather than dividing by zero (which pushed the
    /// fit far south).
    nonisolated static func obscured(mapHeight: CGFloat, sheet: CGFloat = TripsHomeView.compactHeight) -> (top: Double, bottom: Double) {
        let height = mapHeight > sheet + Self.topObscured ? mapHeight : 874
        return (Double(Self.topObscured / height), Double(sheet / height))
    }

    /// Status bar (about 62 pt) plus a destination flag drawn above its coordinate.
    nonisolated private static let topObscured: CGFloat = 110

    // MARK: Sheet

    /// Height of the sheet when collapsed: grabber, title, the two pills and the top of past trips.
    nonisolated static let compactHeight: CGFloat = 300
    /// The short sheet of a picked trip (design/project/HomePicked.dc.html): back, name, date, stats line.
    nonisolated static let pickedCompactMinimum: CGFloat = 172
    /// Room left above the expanded sheet for the profile button.
    private static let topClearance: CGFloat = 64

    /// A Flighty-style glass sheet floating over the map. Drag or tap the top to move between a
    /// compact and a tall detent. A custom overlay rather than a `.sheet`, like `ConvoyPanel`:
    /// a sheet that is always up would sit over pushed screens and block the name sheet.
    private var sheet: some View {
        GeometryReader { geo in
            let bottomInset = geo.safeAreaInsets.bottom
            // From the top of the safe area to the bottom of the screen.
            let full = geo.size.height + bottomInset
            // A picked trip's short sheet is as tall as its header (the text size can wrap it).
            let compact = picked == nil ? Self.compactHeight
                : max(Self.pickedCompactMinimum, pinnedHeight + bottomInset + Spacing.l)
            let tall = max(compact, full - Self.topClearance)
            let height = sheetHeight(compact: compact, tall: tall)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    grabber
                    if let picked {
                        PickedTripHeader(picked: picked, onBack: closePicked, onShowWholeTrip: showWholeTrip)
                    } else {
                        header
                    }
                }
                .contentShape(Rectangle())
                .gesture(sheetDrag(compact: compact, tall: tall))
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { pinnedHeight = $0 }

                ScrollView {
                    if let picked {
                        PickedTripBody(picked: picked, onSelect: selectItem)
                            .padding(.bottom, bottomInset + Spacing.l)
                    } else {
                        pastTrips
                            .padding(.bottom, bottomInset + Spacing.l)
                    }
                }
                .id(picked?.entry.id)
                .scrollDisabled(!expanded)
                .scrollBounceBehavior(.basedOnSize)
            }
            .onChange(of: compact, initial: true) { _, new in
                if picked != nil, pickedCompact != new {
                    pickedCompact = new
                    refocus(animated: false)
                }
            }
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: height, alignment: .top)
            .glassSurface(.sheet)
            .padding(.horizontal, Spacing.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .offset(y: bottomInset - 8)
        }
    }

    private func sheetHeight(compact: CGFloat, tall: CGFloat) -> CGFloat {
        let base = expanded ? tall : compact
        let raw = base - dragOffset
        // Rubber-band past either detent.
        if raw > tall { return tall + (raw - tall) * 0.2 }
        if raw < compact { return compact - (compact - raw) * 0.2 }
        return raw
    }

    private func sheetDrag(compact: CGFloat, tall: CGFloat) -> some Gesture {
        // Global: the header moves with the sheet, so a local translation would chase the finger and jitter.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragOffset) { value, state, _ in state = value.translation.height }
            .onEnded { value in
                let base = expanded ? tall : compact
                // Project the fling so a quick flick moves a detent even over a short distance.
                let projected = base - value.predictedEndTranslation.height
                withAnimation(.snappy) { expanded = projected > (compact + tall) / 2 }
            }
    }

    private var grabber: some View {
        Capsule()
            .fill(Color(.systemGray3))
            .frame(width: 36, height: 5)
            .frame(maxWidth: .infinity, minHeight: 20)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
            .accessibilityElement()
            .accessibilityLabel(picked != nil ? (expanded ? "Collapse recap" : "Expand recap") : (expanded ? "Collapse trips" : "Expand trips"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(.snappy) { expanded.toggle() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trips")
                .font(.largeTitle.bold())
                .padding(.horizontal, Spacing.xs)
                .padding(.top, Spacing.tight)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: Spacing.gap) {
                Button(action: onNewTrip) {
                    Label("New Trip", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle())
                Button(action: onJoin) {
                    Label("Join Trip", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(GlassPillButtonStyle())
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
        .onAppear { past = PastTrips.all() }
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
        if let name = auth.displayName, auth.state == .signedIn {
            Menu {
                Section(name) {
                    Button("Change Name", systemImage: "pencil") {
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
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.08), radius: 7, y: 4)
            }
            .tint(.primary)
            .accessibilityLabel("Profile, \(name)")
            .padding(.horizontal, Spacing.l)
            .padding(.top, Spacing.s)
        }
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

/// `SecondaryPillButtonStyle` for a glass background: the opaque card fill would read as a slab.
private struct GlassPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.ikutAccent)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(.fill.quaternary, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
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
