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

    /// No-op when `route` is the one already loaded.
    func load(route: String) async {
        guard route != loadedRoute else { return }
        loadedRoute = route
        let coords = Polyline.decode(route)
        coordinates = coords
        distance = coords.count > 1 ? RouteLine(coords).length : nil
        originName = nil
        travelTime = nil
        roadName = nil
        guard let first = coords.first, let last = coords.last, coords.count > 1 else { return }
        async let name = RouteBuilder.placeName(at: first)
        let drive = try? await RouteBuilder.drive(from: first, to: last)
        let origin = await name
        // A newer route may have started loading while these were in flight.
        guard loadedRoute == route else { return }
        originName = origin
        travelTime = drive?.travelTime
        roadName = drive?.name
    }
}
