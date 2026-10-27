import CoreLocation
import MapKit
import Observation

/// What a past trip picked on Home's map needs that isn't drawing: the words in the short sheet, which
/// route the map shows, and where the camera goes (design/project/HomePicked.dc.html). Pure, so tests can
/// check it without a screen.
enum PickedTripLogic {
    /// "To Ipoh · 31 Mar 2026": the destination and the day the trip ended, from the past-trips entry
    /// (known before the recap loads). Same words the list's row uses.
    static func subtitle(_ entry: PastTrips.Entry, locale: Locale = .current) -> String {
        guard let ended = entry.endedAt else { return "To \(entry.destination)" }
        return "To \(entry.destination) · \(ended.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))"
    }

    /// A trip this phone left before it ended (`PastTrips.Entry.leftAt`): only its cached route is shown; the trip
    /// and its recap are members-only, so neither is read.
    static func readsServer(_ entry: PastTrips.Entry) -> Bool { entry.leftAt == nil }

    /// What a left trip's sheet says where the recap would be (D54, owner's answer to #421).
    static let leftTitle = "You left while the trip was in progress"
    static let leftLine = "No recap for trips you leave early."

    /// "205 km · 2 h 47 min · 4 cars · 1 stop". A part the recap can't give is left out: no route, no
    /// duration, no cars, and no stops (positions and events are purged 7 days after the end, so none
    /// can mean none kept).
    static func statsLine(_ recap: Recap) -> String? {
        var parts: [String] = []
        if let meters = recap.routeDistance { parts.append(RouteFormat.distance(meters)) }
        if let duration = recap.duration, duration >= 30 { parts.append(ConvoyFormat.duration(duration)) }
        if recap.carCount > 0 { parts.append(recap.carCount == 1 ? "1 car" : "\(recap.carCount) cars") }
        if recap.stopCount > 0 { parts.append(recap.stopCount == 1 ? "1 stop" : "\(recap.stopCount) stops") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The route to draw for the picked trip, best first: the recap's own full route once it has loaded;
    /// else the thinned one already drawn on Home (it is in the 12 newest); else `fetched`, a single
    /// read for a trip older than those 12. Nil when none of them is there yet.
    static func route(for entry: PastTrips.Entry, snapshot: RecapSnapshot?, drawn: [PastTripRoute],
                      fetched: PastTripRoute?) -> PastTripRoute? {
        if let snapshot, snapshot.tripId == entry.id {
            let line = Polyline.decode(snapshot.route)
            if line.count > 1 {
                return PastTripRoute(id: entry.id, name: snapshot.name, destinationName: snapshot.destinationName,
                                     destinationLatitude: snapshot.destinationLatitude,
                                     destinationLongitude: snapshot.destinationLongitude,
                                     points: line.map { [$0.latitude, $0.longitude] })
            }
        }
        return drawn.first { $0.id == entry.id } ?? fetched.flatMap { $0.id == entry.id ? $0 : nil }
    }

    /// The whole route in the part of the map above the short sheet.
    static func fit(_ route: PastTripRoute, bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion? {
        PastTripsMapLogic.region(fitting: [route], bottomObscured: bottomObscured, topObscured: topObscured)
    }

    /// A close view of one spot, with the spot centred in the part of the map above the short sheet.
    static func focus(on coordinate: CLLocationCoordinate2D, span: Double = 0.15,
                      bottomObscured: Double, topObscured: Double) -> MKCoordinateRegion {
        let bottom = max(0, min(bottomObscured, 0.7)), top = max(0, min(topObscured, 0.7))
        let centerLat = coordinate.latitude + span * (top - bottom) / 2
        return MKCoordinateRegion(center: .init(latitude: max(-85, min(85, centerLat)), longitude: coordinate.longitude),
                                  span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span))
    }

    /// The label on a marked item's pin and its VoiceOver name: what it is and when, "Fuel stop · 13:16".
    static func pinLabel(_ item: RecapTimelineItem) -> String {
        let what = item.pinTitle.isEmpty ? item.title : item.pinTitle
        return "\(what) · \(RecapLogic.clock(item.time))"
    }

    /// Whether the camera should go back to the whole route: the recap has just arrived (the full route
    /// and the dots with it, or a Try again that worked), nothing is selected and the camera is still ours.
    static func shouldRefit(hadSnapshot: Bool, hasSnapshot: Bool, itemSelected: Bool, cameraMovedByUser: Bool) -> Bool {
        !hadSnapshot && hasSnapshot && !itemSelected && !cameraMovedByUser
    }

    /// Whether the camera already shows `target` closely enough that a late refit (the full route arriving after
    /// the thinned one was fitted) would only nudge the picture: centre within 6% and span within 6% of the span.
    static func nearlyShown(centerLatitude: Double, centerLongitude: Double, latitudeSpan: Double,
                            target: MKCoordinateRegion) -> Bool {
        let span = max(target.span.latitudeDelta, 1e-9)
        return abs(centerLatitude - target.center.latitude) < 0.06 * span
            && abs(centerLongitude - target.center.longitude) < 0.06 * span
            && abs(latitudeSpan / span - 1) < 0.06
    }

    /// What the map marks on the picked route: stops (red) and road reports (yellow) with a place.
    static func markers(_ recap: Recap?) -> [RecapTimelineItem] {
        (recap?.timeline ?? []).filter { ($0.kind == .stop || $0.kind == .hazard) && $0.coordinate != nil }
    }
}

/// A past trip picked on Home: its recap (loading, loaded or couldn't load), the timeline filter, and the
/// timeline item the map is showing, if any.
@Observable @MainActor
final class PickedTrip {
    let entry: PastTrips.Entry
    let model: RecapModel
    var filter: RecapFilter = .all
    private(set) var selectedItemId: String?

    init(entry: PastTrips.Entry, model: RecapModel? = nil) {
        self.entry = entry
        self.model = model ?? RecapModel(tripId: entry.id)
    }

    var title: String { model.recap?.title ?? entry.name }
    /// This phone left the trip before it ended: the route only, no recap.
    var isLeft: Bool { !PickedTripLogic.readsServer(entry) }
    var subtitle: String { PickedTripLogic.subtitle(entry) }
    var statsLine: String? { model.recap.flatMap(PickedTripLogic.statsLine) }

    var selectedItem: RecapTimelineItem? {
        model.recap?.timeline.first { $0.id == selectedItemId }
    }

    /// A timeline item with a place on the map; others (the trip's end) do nothing.
    func select(_ item: RecapTimelineItem) {
        guard item.coordinate != nil else { return }
        selectedItemId = item.id
    }

    /// Back to the whole trip.
    func clearSelection() { selectedItemId = nil }
}

#if DEBUG
/// States of Home for the launch screens (`IKUT_SCREEN`, see `DemoScreens`): the list, and a trip picked while its
/// recap is loaded, loading or couldn't load.
@MainActor
enum HomePickedDemo {
    static func view(_ name: String) -> TripsHomeView {
        if let join = JoinDemo.home(name) { return join }
        let snapshot = RecapSnapshot.demo()
        let day: TimeInterval = 86_400
        let now = Date()
        let entry = PastTrips.Entry(id: snapshot.tripId, name: snapshot.name, destination: snapshot.destinationName,
                                    endedAt: now.addingTimeInterval(-day), seenAt: now, others: ["Wyna", "Hafiz", "Daniel"])
        let older = [
            PastTrips.Entry(id: "sample-2", name: "Makan trip", destination: "Melaka", endedAt: now.addingTimeInterval(-9 * day),
                            seenAt: now.addingTimeInterval(-9 * day), others: nil),
            PastTrips.Entry(id: "sample-3", name: "Cameron weekend", destination: "Tanah Rata",
                            endedAt: now.addingTimeInterval(-40 * day), seenAt: now.addingTimeInterval(-40 * day), others: ["Wyna"]),
        ]
        let thin = PastTripsMapLogic.route(id: entry.id, name: entry.name, destinationName: snapshot.destinationName,
                                           destination: snapshot.destination, encodedRoute: snapshot.route)
        let past = [entry] + older
        let model = RecapModel(snapshot: snapshot, originName: "Tanjung Malim")
        switch name {
        case "short": return TripsHomeView(demo: past, routes: [thin], picked: PickedTrip(entry: entry, model: model))
        case "tall": return TripsHomeView(demo: past, routes: [thin], picked: PickedTrip(entry: entry, model: model), expanded: true)
        case "item":
            let stop = model.recap?.timeline.first { $0.kind == .stop }?.id
            return TripsHomeView(demo: past, routes: [thin], picked: PickedTrip(entry: entry, model: model), selecting: stop)
        case "loading": return TripsHomeView(demo: past, routes: [thin], picked: PickedTrip(entry: entry, model: RecapModel(tripId: "demo-never-loaded")))
        case "failed": return TripsHomeView(demo: past, routes: [thin], picked: PickedTrip(entry: entry, model: RecapModel(failedTripId: entry.id)))
        case "left":
            var left = entry
            left.leftAt = now.addingTimeInterval(-day)
            return TripsHomeView(demo: [left] + older, routes: [thin],
                                 picked: PickedTrip(entry: left, model: RecapModel(tripId: "demo-never-loaded")))
        case "tap", "tour":
            // Two more routes, so the list's fit is wider than the picked trip's and picking moves the camera.
            func line(_ id: String, _ name: String, _ to: String, _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> PastTripRoute {
                PastTripsMapLogic.route(id: id, name: name, destinationName: to, destination: b, encodedRoute: Polyline.encode([a, b]))
            }
            let kl = CLLocationCoordinate2D(latitude: 3.139, longitude: 101.687)
            let drawn = [thin,
                         line("sample-2", "Makan trip", "Melaka", kl, .init(latitude: 2.196, longitude: 102.25)),
                         line("sample-3", "Cameron weekend", "Tanah Rata", kl, .init(latitude: 4.47, longitude: 101.38))]
            return TripsHomeView(demo: past, routes: drawn, tappable: model, tour: name == "tour")
        case "where-to", "new-trip":
            // The create flow over Home's map: Ipoh's results as pins (the second one at the top of the list), or the
            // route to Ipoh drawn with the Name field.
            func place(_ name: String, _ area: String, _ lat: Double, _ lon: Double, _ category: MKPointOfInterestCategory? = nil)
                -> DestinationResult {
                DestinationResult(name: name, subtitle: area, coordinate: .init(latitude: lat, longitude: lon), category: category?.rawValue)
            }
            let ipoh = place("Ipoh", "City in Perak", 4.5975, 101.0901)
            let search = CreateTripModel()
            search.showForDemo(query: "Ipoh", results: [
                ipoh,
                place("Ipoh Parade", "Shopping centre · Perak", 4.6002, 101.0764, .store),
                place("Ipoh railway station", "Station · Perak", 4.5985, 101.0902, .publicTransport),
                place("Ipoh Garden", "Perak", 4.6140, 101.1210),
            ], origin: .init(latitude: 3.139, longitude: 101.687), originName: "Kuala Lumpur")
            let flow = NewTripFlow(search: search)
            if name == "new-trip" {
                flow.showReadyForDemo(
                    place: ipoh,
                    route: BuiltRoute(distance: 205_000, travelTime: 9_600, name: "E1", polyline: Polyline.encode(LobbyStopsDemo.route)))
            } else {
                flow.topResultID = ipoh.id
            }
            return TripsHomeView(demo: past, routes: [thin], creating: flow)
        case "now", "now-started", "now-failed":
            // A trip that hasn't ended, in Now above Past trips: gathering, on the move, or one that couldn't be read.
            let running = PastTrips.Entry(id: "sample-now", name: "Balik kampung raya", destination: "Ipoh", endedAt: nil,
                                          seenAt: now, others: ["Wyna", "Hafiz"])
            let line = switch name {
            case "now-started": "On the move · since 12:05"
            case "now-failed": HomeNow.fallbackStatus
            default: "Gathering · 4 of 5 cars ready · meet 12:00"
            }
            return TripsHomeView(demo: [running] + past, routes: [thin], nowStatus: ["sample-now": line])
        case "list-tall": return TripsHomeView(demo: past, routes: [thin], expanded: true)
        default: return TripsHomeView(demo: past, routes: [thin])
        }
    }
}
#endif
