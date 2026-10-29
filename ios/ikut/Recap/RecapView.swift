import FirebaseAuth
import MapKit
import SwiftUI

/// After the trip (design/project/Summary.dc.html): trip name as the large title, route map with stats, awards and a
/// filterable timeline, with Share in the bar and Done below. Opened for every member when the trip ends. Home's past
/// trips show the same content in the Home sheet instead (`PickedTripSheet`).
struct RecapView: View {
    @State private var model: RecapModel
    var onDone: () -> Void
    @State private var filter: RecapFilter = .all
    @State private var showMap = false

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
                if let recap = model.recap, let snapshot = model.snapshot {
                    RecapContent(recap: recap, snapshot: snapshot, layout: .screen, filter: $filter,
                                 onOpenMap: { showMap = true }, onDone: onDone)
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
        .navigationTitle(model.recap?.title ?? "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if let recap = model.recap {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: RecapContent.shareText(recap)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share recap")
                }
            }
        }
        .task { await model.load(myUserId: Auth.auth().currentUser?.uid) }
        .fullScreenCover(isPresented: $showMap) {
            if let recap = model.recap, let snapshot = model.snapshot {
                RecapMapView(recap: recap, snapshot: snapshot) { showMap = false }
            }
        }
        .accessibilityIdentifier("recap")
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
        case .stop: (.recapStopPin, .white)
        case .hazard: (.recapHazardPin, .black)
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
    /// The map's bottom safe area, for a card over its bottom (`MapLegal`): the logo and Legal sit above it.
    var legalInset: CGFloat
    @Binding var camera: MapCameraPosition
    /// Each frame of the camera as it moves (the recap map plans its next step from it).
    var onCamera: ((MapCamera, Double) -> Void)?

    init(recap: Recap, snapshot: RecapSnapshot, interactive: Bool, selectedId: String? = nil, legalInset: CGFloat = 0,
         camera: Binding<MapCameraPosition> = .constant(.automatic), onCamera: ((MapCamera, Double) -> Void)? = nil) {
        self.onCamera = onCamera
        self.legalInset = legalInset
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
                    .stroke(Color.recapRouteGlow.opacity(0.9), style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
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
        .onMapCameraChange(frequency: .continuous) { onCamera?($0.camera, $0.region.span.latitudeDelta) }
        .safeAreaPadding(.bottom, legalInset)
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
        func ev(_ id: String, _ type: EventType, car: String, user: String, _ min: Double, f: Double, expires: Double? = nil, message: String? = nil) -> RecapEvent {
            let c = at(f)
            return RecapEvent(id: id, type: type.rawValue, carId: car, authorId: user, latitude: c.latitude, longitude: c.longitude,
                              createdAt: start.addingTimeInterval(min * 60), expiresAt: expires.map { start.addingTimeInterval($0 * 60) },
                              message: message)
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
                ev("e2", .stopFuel, car: "c2", user: "u2", 65, f: 0.45, expires: 95, message: "Low on fuel, next R&R please"),
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
