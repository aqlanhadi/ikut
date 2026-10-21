import FirebaseAuth
import MapKit
import SwiftUI

/// After the trip (design/project/Summary.dc.html): title, route map with stats, awards and a
/// filterable timeline, with Share and Done. Opened for every member when the trip ends, and from
/// Home's past trips.
struct RecapView: View {
    @State private var model: RecapModel
    var onDone: () -> Void
    @State private var filter: Filter = .all
    @State private var showMap = false

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", stops = "Stops", reports = "Road Reports"
        var id: String { rawValue }
    }

    init(tripId: String, onDone: @escaping () -> Void) {
        _model = State(initialValue: RecapModel(tripId: tripId))
        self.onDone = onDone
    }

    init(model: RecapModel, onDone: @escaping () -> Void = {}) {
        _model = State(initialValue: model)
        self.onDone = onDone
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                topBar
                if let recap = model.recap, let snapshot = model.snapshot {
                    content(recap, snapshot)
                } else if let error = model.errorMessage {
                    Text(error).foregroundStyle(.secondary).padding(.top, 40)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.xl)
        }
        .background(Color.ikutScreen)
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load(myUserId: Auth.auth().currentUser?.uid) }
        .fullScreenCover(isPresented: $showMap) {
            if let recap = model.recap, let snapshot = model.snapshot {
                RecapMapView(recap: recap, snapshot: snapshot) { showMap = false }
            }
        }
        .accessibilityIdentifier("recap")
    }

    private var topBar: some View {
        HStack {
            MapCloseButton(action: onDone)
            Spacer()
            if let recap = model.recap {
                ShareLink(item: shareText(recap)) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .tint(.primary)
                .accessibilityLabel("Share recap")
            }
        }
        .padding(.top, Spacing.s)
    }

    @ViewBuilder
    private func content(_ recap: Recap, _ snapshot: RecapSnapshot) -> some View {
        Text("Trip complete")
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ikutAccent)
            .padding(.horizontal, Spacing.xs).padding(.top, Spacing.cozy)
        Text(recap.title)
            .font(.largeTitle.bold())
            .padding(.horizontal, Spacing.xs).padding(.top, Spacing.xxs)
            .accessibilityAddTraits(.isHeader)
        Text(recap.subtitle)
            .font(.subheadline).foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.xs).padding(.top, Spacing.xxs)

        VStack(spacing: 0) {
            Button { showMap = true } label: {
                RecapRouteMap(recap: recap, snapshot: snapshot, interactive: false)
                    .frame(height: 150)
                    .overlay(alignment: .bottomTrailing) {
                        Label("Route map", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 11).frame(height: 30)
                            .background(.regularMaterial, in: Capsule())
                            .padding(Spacing.s)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open full route map")
            statGrid(recap.stats)
        }
        .ikutCard()
        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(.top, Spacing.section)

        if !recap.awards.isEmpty {
            sectionTitle("Road Trip Awards")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.gap), GridItem(.flexible())], spacing: Spacing.gap) {
                ForEach(recap.awards, id: \.kind) { award(of: $0, snapshot) }
            }
        }

        sectionTitle("Timeline")
        Picker("Filter timeline", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        timeline(recap.timeline.filter(matches))
            .padding(.top, Spacing.m)

        ForEach(recap.notes, id: \.self) { note in
            InlineNote(note, systemImage: "info.circle", inset: Spacing.xs)
                .padding(.top, Spacing.m)
        }

        VStack(spacing: Spacing.xs) {
            ShareLink(item: shareText(recap)) {
                Label("Share Recap with Convoy", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PillButtonStyle())
            Button("Done", action: onDone).buttonStyle(LinkPillButtonStyle())
        }
        .padding(.top, Spacing.block)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.title2.bold())
            .padding(.horizontal, Spacing.xs).padding(.top, 26).padding(.bottom, Spacing.s)
            .accessibilityAddTraits(.isHeader)
    }

    private func statGrid(_ stats: [RecapStat]) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { row in
                if row > 0 { Divider() }
                GridRow {
                    statTile(stats[row])
                    if row + 1 < stats.count {
                        statTile(stats[row + 1]).overlay(alignment: .leading) { Rectangle().fill(Color(.separator)).frame(width: 0.5) }
                    }
                }
            }
        }
    }

    private func statTile(_ s: RecapStat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(s.label).font(.footnote).foregroundStyle(.secondary)
            (Text(s.value).font(.system(size: 28, weight: .bold, design: .rounded))
                + Text(s.unit.isEmpty ? "" : " \(s.unit)").font(.system(size: 17, weight: .semibold)).foregroundStyle(.secondary))
                .monospacedDigit()
            Text(s.note.isEmpty ? " " : s.note).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.cozy)
        .accessibilityElement(children: .combine)
    }

    private static let awardStyle: [RecapAward.Kind: (symbol: String, tint: Color)] = [
        .lead: ("bolt.fill", Color(hex: "#C93400")!),
        .firstIn: ("flag.checkered", Color(hex: "#1F7A35")!),
        .reporter: ("eye.fill", Color(hex: "#B25000")!),
        .stopCaller: ("fuelpump.fill", Color(hex: "#D70015")!),
        .sweeper: ("shield.fill", Color(hex: "#5856D6")!),
    ]

    private func award(of a: RecapAward, _ s: RecapSnapshot) -> some View {
        let style = Self.awardStyle[a.kind] ?? ("star.fill", .ikutAccent)
        let car = s.cars.first { $0.id == a.carId }
        return VStack(alignment: .leading, spacing: Spacing.gap) {
            HStack {
                Image(systemName: style.symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(style.tint, in: Circle())
                Spacer()
                if let car { CarBadge(number: car.number, colorHex: car.color, size: 26) }
            }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(a.title).font(.headline)
                Text(a.detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.cozy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ikutCard()
        .accessibilityElement(children: .combine)
    }

    private func matches(_ item: RecapTimelineItem) -> Bool {
        switch filter {
        case .all: true
        case .stops: item.kind == .stop
        case .reports: item.kind == .hazard
        }
    }

    private func timeline(_ items: [RecapTimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text(filter == .all ? "Nothing to show." : "None on this trip, or no longer stored.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.bottom, Spacing.m)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: Spacing.m) {
                    Text(RecapLogic.clock(item.time))
                        .font(.footnote.weight(.semibold)).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 42, alignment: .leading).padding(.top, 5)
                    VStack(spacing: Spacing.xs) {
                        RecapEventDot(kind: item.kind, symbol: item.symbol, size: 28)
                        if index < items.count - 1 {
                            Capsule().fill(Color(.systemGray5)).frame(width: 2).frame(minHeight: 12)
                        }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, Spacing.xs).padding(.bottom, Spacing.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.top, Spacing.l).padding(.bottom, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ikutCard()
    }

    private func shareText(_ r: Recap) -> String {
        var lines = ["\(r.title): trip complete", r.subtitle]
        lines += r.stats.map { "\($0.label): \($0.value)\($0.unit.isEmpty ? "" : " \($0.unit)")" }
        return lines.joined(separator: "\n")
    }
}

/// Timeline and map dot: yellow for road reports, red for stops, accent for the trip, gray for cars.
struct RecapEventDot: View {
    var kind: RecapTimelineItem.Kind
    var symbol: String
    var size: CGFloat
    var selected = false

    var body: some View {
        let (fill, ink): (Color, Color) = switch kind {
        case .trip: (.ikutAccent, .white)
        case .stop: (Color(hex: "#FF3B30")!, .white)
        case .hazard: (Color(hex: "#FFCC00")!, .black)
        case .car: (Color(.systemGray5), Color(.label))
        }
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(ink)
            .frame(width: size, height: size)
            .background(fill, in: Circle())
            .overlay { if selected { Circle().stroke(Color.ikutAccent.opacity(0.35), lineWidth: 4).padding(-4) } }
            .accessibilityHidden(true)
    }
}

/// The main route with event dots, each car's last position and the destination pin.
struct RecapRouteMap: View {
    var recap: Recap
    var snapshot: RecapSnapshot
    var interactive: Bool
    var selectedId: String?
    @Binding var camera: MapCameraPosition

    init(recap: Recap, snapshot: RecapSnapshot, interactive: Bool, selectedId: String? = nil,
         camera: Binding<MapCameraPosition> = .constant(.automatic)) {
        self.recap = recap
        self.snapshot = snapshot
        self.interactive = interactive
        self.selectedId = selectedId
        _camera = camera
    }

    var body: some View {
        let route = Polyline.decode(snapshot.route)
        Map(position: $camera, interactionModes: interactive ? .all : []) {
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(Color(hex: "#F3D08A")!.opacity(0.9), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route)
                    .stroke(Color.ikutAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            }
            if let start = route.first {
                Annotation("Start", coordinate: start, anchor: .center) {
                    Circle().fill(.white).frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.ikutAccent, lineWidth: 4))
                }
            }
            ForEach(recap.timeline.filter { $0.kind != .trip && $0.coordinate != nil }) { item in
                Annotation(item.title, coordinate: item.coordinate!, anchor: .center) {
                    RecapEventDot(kind: item.kind, symbol: item.symbol, size: selectedId == item.id ? 30 : 22,
                                  selected: selectedId == item.id)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .annotationTitles(.hidden)
            }
            ForEach(snapshot.positions, id: \.carId) { p in
                if let car = snapshot.cars.first(where: { $0.id == p.carId }) {
                    Annotation(car.name, coordinate: p.coordinate, anchor: .center) {
                        CarBadge(number: car.number, colorHex: car.color, size: 26)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    .annotationTitles(interactive ? .automatic : .hidden)
                }
            }
            Marker(snapshot.destinationName, systemImage: "mappin", coordinate: snapshot.destination)
                .tint(Color.ikutAccent)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .allowsHitTesting(interactive)
    }
}

#if DEBUG
extension RecapSnapshot {
    /// KL to Ipoh on the demo route, for previews and the screenshot test.
    @MainActor static func demo(now: Date = Date()) -> RecapSnapshot {
        let main = MapDemo.densify(MapDemo.mainWaypoints)
        let line = RouteLine(main)
        let start = now.addingTimeInterval(-10_020)
        func at(_ f: Double) -> CLLocationCoordinate2D { line.coordinate(atOffset: line.length * f) ?? main[0] }
        let end = main.last!
        func ev(_ id: String, _ type: EventType, car: String, user: String, _ min: Double, f: Double, expires: Double? = nil, place: String? = nil) -> RecapEvent {
            let c = at(f)
            return RecapEvent(id: id, type: type.rawValue, carId: car, authorId: user, latitude: c.latitude, longitude: c.longitude,
                              createdAt: start.addingTimeInterval(min * 60), expiresAt: expires.map { start.addingTimeInterval($0 * 60) },
                              message: nil, placeName: place)
        }
        return RecapSnapshot(
            tripId: "demo", name: "Balik kampung raya", destinationName: "Ipoh",
            destinationLatitude: end.latitude, destinationLongitude: end.longitude,
            route: Polyline.encode(main), createdAt: start, endedAt: now,
            cars: [
                .init(id: "c1", name: "Aqlan’s Myvi", color: "#2563EB", number: 1, isLead: true),
                .init(id: "c2", name: "Wyna’s Axia", color: "#D9480F", number: 2, isLead: false),
                .init(id: "c3", name: "Hafiz’s Saga", color: "#0F766E", number: 3, isLead: false),
                .init(id: "c4", name: "Daniel’s City", color: "#7C3AED", number: 4, isLead: false),
            ],
            memberNames: ["u1": "Aqlan", "u2": "Wyna", "u3": "Hafiz", "u4": "Daniel", "u5": "Faiz"],
            memberCars: ["u1": "c1", "u2": "c2", "u3": "c3", "u4": "c4", "u5": "c1"],
            positions: [
                .init(carId: "c1", latitude: end.latitude + 0.001, longitude: end.longitude, convoyOffset: line.length - 100, updatedAt: start.addingTimeInterval(161 * 60)),
                .init(carId: "c2", latitude: end.latitude, longitude: end.longitude + 0.002, convoyOffset: line.length - 200, updatedAt: start.addingTimeInterval(165 * 60)),
                .init(carId: "c3", latitude: end.latitude - 0.002, longitude: end.longitude, convoyOffset: line.length - 250, updatedAt: start.addingTimeInterval(167 * 60)),
                .init(carId: "c4", latitude: at(0.97).latitude, longitude: at(0.97).longitude, convoyOffset: line.length * 0.97, updatedAt: start.addingTimeInterval(166 * 60)),
            ],
            events: [
                ev("e1", .debris, car: "c1", user: "u1", 36, f: 0.2),
                ev("e2", .stopFuel, car: "c2", user: "u2", 65, f: 0.45, expires: 91, place: "Petronas Tapah"),
                ev("e3", .heavyRain, car: "c3", user: "u3", 107, f: 0.7),
            ])
    }
}

#Preview {
    RecapView(model: RecapModel(snapshot: .demo(), originName: "Tanjung Malim"))
}
#endif

#Preview("Event dots") {
    let dots: [(RecapTimelineItem.Kind, String)] = [
        (.trip, "flag.fill"), (.stop, "fuelpump.fill"), (.hazard, "exclamationmark.triangle.fill"),
        (.hazard, "cloud.rain.fill"), (.car, "car.fill"), (.trip, "mappin.circle.fill"),
    ]
    VStack(spacing: Spacing.l) {
        HStack(spacing: Spacing.m) {
            ForEach(dots.indices, id: \.self) { RecapEventDot(kind: dots[$0].0, symbol: dots[$0].1, size: 28) }
        }
        HStack(spacing: Spacing.l) {
            RecapEventDot(kind: .stop, symbol: "fuelpump.fill", size: 36)
            RecapEventDot(kind: .stop, symbol: "fuelpump.fill", size: 36, selected: true)
        }
    }
    .padding(Spacing.l)
}
