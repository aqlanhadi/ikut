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

/// Writes (a date) or clears (nil) `pausedAt` on the car doc; tests substitute a fake.
typealias PauseWriter = @MainActor (_ carId: String, _ pausedAt: Date?) async throws -> Void

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

    /// A pause lasts at most this long; after it, every client treats the car as sharing again and the
    /// tracker's own session resumes by itself. Covers a forgotten pause, a crash or a relaunch.
    static let pauseExpiry: TimeInterval = 30 * 60

    /// True while `pausedAt` is set, not in the future by more than a skew allowance, and younger than `pauseExpiry`.
    static func isPaused(pausedAt: Date?, now: Date) -> Bool {
        guard let pausedAt else { return false }
        return now.timeIntervalSince(pausedAt) < pauseExpiry
    }

    /// Whether other members should show this car as paused ("Paused" instead of "Last seen ...").
    static func isPaused(_ car: Car?, now: Date) -> Bool {
        isPaused(pausedAt: car?.pausedAt, now: now)
    }

    /// The explainer is shown at most once per session, and only when the permission logic asks for it.
    static func shouldPresentAlwaysExplainer(action: LocationAction, alreadyShown: Bool) -> Bool {
        action == .showAlwaysExplainer && !alreadyShown
    }

    /// The Always sheet is on screen only while wanted and no map ask is up, so the two never stack.
    static func explainerVisible(wanted: Bool, askShowing: Bool) -> Bool { wanted && !askShowing }

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
