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
        case "list-tall": return TripsHomeView(demo: past, routes: [thin], expanded: true)
        default: return TripsHomeView(demo: past, routes: [thin])
        }
    }
}
#endif
