import CoreLocation
import Observation

/// Display facts about a trip's main route that the trip doc doesn't store: the town it starts
/// from, its length, and the drive time and road name from MapKit. Load once per route.
@Observable @MainActor
final class TripRouteInfo {
    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private(set) var originName: String?
    /// Meters, from the polyline.
    private(set) var distance: Double?
    /// Seconds; nil until MapKit answers.
    private(set) var travelTime: Double?
    /// "E1"; empty or nil when MapKit doesn't name the road.
    private(set) var roadName: String?

    @ObservationIgnored private var loadedRoute: String?
    @ObservationIgnored private let drive: @MainActor (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> (distance: Double, travelTime: Double, name: String)
    @ObservationIgnored private let placeName: @MainActor (CLLocationCoordinate2D) async -> String?

    /// The requests are injectable so a test can count them.
    init(
        drive: @escaping @MainActor (CLLocationCoordinate2D, CLLocationCoordinate2D) async throws -> (distance: Double, travelTime: Double, name: String)
            = { try await RouteBuilder.drive(from: $0, to: $1) },
        placeName: @escaping @MainActor (CLLocationCoordinate2D) async -> String? = { await RouteBuilder.placeName(at: $0) }
    ) {
        self.drive = drive
        self.placeName = placeName
    }

    /// No-op when `route` is the one already loaded. `routeSeconds` is the drive time the trip stored: with it
    /// MapKit isn't asked for the time, which it could only answer for the direct drive, not through stops.
    /// `needsRoadName` is false for a route through stops, which has no single road to name.
    /// `ownTrip` is for a participant, whose card shows their own trip (`OwnWayInfo`): the route's points and length
    /// only, no town and no MapKit request, so the lobby makes one drive request, not two.
    func load(route: String, routeSeconds: Double? = nil, needsRoadName: Bool = true, ownTrip: Bool = false) async {
        guard route != loadedRoute else { return }
        loadedRoute = route
        let coords = Polyline.decode(route)
        coordinates = coords
        distance = coords.count > 1 ? RouteLine(coords).length : nil
        originName = nil
        travelTime = routeSeconds
        roadName = nil
        guard let first = coords.first, let last = coords.last, coords.count > 1, !ownTrip else { return }
        async let name = placeName(first)
        let driven = routeSeconds != nil && !needsRoadName ? nil : try? await drive(first, last)
        let origin = await name
        // A newer route may have started loading while these were in flight.
        guard loadedRoute == route else { return }
        originName = origin
        travelTime = routeSeconds ?? driven?.travelTime
        roadName = needsRoadName ? driven?.name : nil
    }
}
