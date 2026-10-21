import MapKit
import SwiftUI

/// Home after the welcome screen, as in Home.dc.html: a map of where you are and the routes of
/// your past trips, under a floating glass sheet with New Trip, Join Trip and past trips.
struct TripsHomeView: View {
    @Environment(AuthModel.self) private var auth
    var onNewTrip: () -> Void
    var onJoin: () -> Void
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
            UserAnnotation()
            // Oldest first so the newest draws on top.
            ForEach(Array(routes.enumerated().reversed()), id: \.element.id) { index, route in
                routeContent(route, latest: index == 0)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            guard height != mapHeight else { return }
            mapHeight = height
            // Refit for the real height while the camera is still ours.
            if !routes.isEmpty, !camera.positionedByUser { fit(animated: false) }
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
            .accessibilityHint("Opens the recap")
        }
        .annotationTitles(latest ? .automatic : .hidden)
    }

    /// The name Home lists for the trip (it may have been renamed since the route was cached).
    private func displayName(_ route: PastTripRoute) -> String {
        past.first(where: { $0.id == route.id })?.name ?? route.name
    }

    private func open(_ route: PastTripRoute) {
        if let entry = past.first(where: { $0.id == route.id }) { onOpenTrip(entry) }
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
    nonisolated static func obscured(mapHeight: CGFloat) -> (top: Double, bottom: Double) {
        let height = mapHeight > Self.compactHeight + Self.topObscured ? mapHeight : 874
        return (Double(Self.topObscured / height), Double(Self.compactHeight / height))
    }

    /// Status bar (about 62 pt) plus a destination flag drawn above its coordinate.
    nonisolated private static let topObscured: CGFloat = 110

    // MARK: Sheet

    /// Height of the sheet when collapsed: grabber, title, the two pills and the top of past trips.
    nonisolated private static let compactHeight: CGFloat = 300
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
            let tall = max(Self.compactHeight, full - Self.topClearance)
            let height = sheetHeight(compact: Self.compactHeight, tall: tall)

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    grabber
                    header
                }
                .contentShape(Rectangle())
                .gesture(sheetDrag(compact: Self.compactHeight, tall: tall))

                ScrollView {
                    pastTrips
                        .padding(.bottom, bottomInset + Spacing.l)
                }
                .scrollDisabled(!expanded)
                .scrollBounceBehavior(.basedOnSize)
            }
            .padding(.horizontal, Spacing.l)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(height: height, alignment: .top)
            .glassSheetBackground()
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
            .accessibilityLabel(expanded ? "Collapse trips" : "Expand trips")
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
                        Button { onOpenTrip(entry) } label: { pastRow(entry) }
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
        .accessibilityHint(entry.endedAt == nil ? "Opens the trip" : "Opens the recap")
    }

    private func pastDetail(_ entry: PastTrips.Entry) -> String {
        guard let ended = entry.endedAt else { return "To \(entry.destination) · in progress" }
        return "To \(entry.destination) · \(ended.formatted(date: .abbreviated, time: .omitted))"
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

private extension View {
    /// Liquid Glass on iOS 26 and later, with bottom corners that follow the screen's; a material
    /// before that.
    @ViewBuilder
    func glassSheetBackground() -> some View {
        // Clipped to the same shape: a ScrollView draws on under the safe area and past the rounded
        // corners, so past trips would show outside the glass.
        if #available(iOS 26, *) {
            let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(Radius.panel)), isUniform: false)
            clipShape(shape).glassEffect(.regular, in: shape)
        } else {
            clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 20, y: 10)
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
