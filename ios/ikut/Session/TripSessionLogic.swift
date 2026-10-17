import Foundation

/// What `TripSession` needs from `TrackingService`; tests substitute a fake.
@MainActor
protocol TrackingControlling: AnyObject {
    var isTracking: Bool { get }
    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?)
    /// Must stop location updates synchronously.
    func stop()
}

extension TrackingService: TrackingControlling {}

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

    /// Decodes a polyline into a route; nil for a missing or malformed string.
    static func routeLine(from polyline: String?) -> RouteLine? {
        guard let polyline, !polyline.isEmpty else { return nil }
        let coordinates = Polyline.decode(polyline)
        return coordinates.isEmpty ? nil : RouteLine(coordinates)
    }
}
