import CoreLocation
import Foundation

/// What `TripSession` needs from `TrackingService`; tests substitute a fake.
@MainActor
protocol TrackingControlling: AnyObject {
    var isTracking: Bool { get }
    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?)
    /// Called with every fix that was published while tracking.
    var onFix: ((LocationFix) -> Void)? { get set }
    /// One fix without starting to track; nil if cancelled or unavailable.
    func firstFix() async -> LocationFix?
    /// Must stop location updates synchronously.
    func stop()
}

extension TrackingService: TrackingControlling {}

/// Defaults so simple conformers (previews, no-op fakes) need not implement the fix hooks.
extension TrackingControlling {
    var onFix: ((LocationFix) -> Void)? {
        get { nil }
        set {}
    }
    func firstFix() async -> LocationFix? { nil }
}

/// What `TripSession` needs from `CarRouteService`; tests substitute a fake.
@MainActor
protocol CarRouteControlling: AnyObject {
    var routeLine: RouteLine? { get }
    func ensureRoute(at location: CLLocationCoordinate2D) async throws -> CarRoutePlan
    func handle(fix: LocationFix) async -> CarRouteEvent
}

extension CarRouteService: CarRouteControlling {}

/// Builds the car-route service for one tracking session from the trip and car docs.
typealias CarRouteFactory = @MainActor (_ tripId: String, _ carId: String, _ trip: Trip, _ car: Car) throws -> CarRouteControlling

enum TripSessionLogic {
    /// Only the car's tracker, while the trip is active and they are still a member, broadcasts.
    static func shouldTrack(
        userId: String, tripStatus: TripStatus?, isMember: Bool, trackerUserId: String?
    ) -> Bool {
        guard !userId.isEmpty, tripStatus == .active, isMember else { return false }
        return trackerUserId == userId
    }

    /// The explainer is shown at most once per session, and only when the permission logic asks for it.
    static func shouldPresentAlwaysExplainer(action: LocationAction, alreadyShown: Bool) -> Bool {
        action == .showAlwaysExplainer && !alreadyShown
    }

    @MainActor static func makeCarRouteService(tripId: String, carId: String, trip: Trip, car: Car) throws -> CarRouteControlling {
        try CarRouteService(
            tripId: tripId, carId: carId, mainRoute: trip.route,
            destination: CLLocationCoordinate2D(
                latitude: trip.destination.coordinate.latitude, longitude: trip.destination.coordinate.longitude),
            route: car.route, state: car.state)
    }

    /// Flat lat/lon list used to compare routes (`RouteLine` is not Equatable); nil for no route.
    static func signature(of line: RouteLine?) -> [Double]? {
        guard let line else { return nil }
        return line.coordinates.flatMap { [$0.latitude, $0.longitude] }
    }

    /// Decodes a polyline into a route; nil for a missing or malformed string.
    static func routeLine(from polyline: String?) -> RouteLine? {
        guard let polyline, !polyline.isEmpty else { return nil }
        let coordinates = Polyline.decode(polyline)
        return coordinates.isEmpty ? nil : RouteLine(coordinates)
    }
}
