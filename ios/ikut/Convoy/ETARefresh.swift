import CoreLocation
import MapKit

/// Travel time between two points. A protocol so tests (and previews) don't hit MKDirections.
protocol ETAProviding: Sendable {
    /// Expected driving time in seconds.
    func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval
}

/// `MKDirections.calculateETA`, automobile, leaving now. One request per call.
struct MapKitETAProvider: ETAProviding {
    func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval {
        let request = MKDirections.Request()
        request.source = Self.mapItem(from)
        request.destination = Self.mapItem(to)
        request.transportType = .automobile
        request.departureDate = Date()
        let response = try await MKDirections(request: request).calculateETA()
        return response.expectedTravelTime
    }

    private static func mapItem(_ c: CLLocationCoordinate2D) -> MKMapItem {
        if #available(iOS 26.0, *) {
            return MKMapItem(location: CLLocation(latitude: c.latitude, longitude: c.longitude), address: nil)
        }
        return MKMapItem(placemark: MKPlacemark(coordinate: c))
    }
}

/// When to ask for a new front-car ETA. Pure.
///
/// Apple throttles MKDirections (error `loadingThrottled`), and an ETA doesn't change much second to
/// second, so requests are spaced:
/// - never sooner than `minInterval` (30 s) after the last one;
/// - between 30 and 60 s, only if the reference car has moved `movementThreshold` (500 m) or more
///   since the last request, or is a different car;
/// - always once `maxInterval` (60 s) has passed;
/// - after failures the spacing doubles per consecutive failure (60, 120, 240 s), capped at
///   `maxBackoff` (300 s), and movement no longer shortcuts it.
struct ETARefreshSchedule: Equatable, Sendable {
    var minInterval: TimeInterval = 30
    var maxInterval: TimeInterval = 60
    var movementThreshold: CLLocationDistance = 500
    var maxBackoff: TimeInterval = 300

    static let `default` = ETARefreshSchedule()

    /// - Parameters:
    ///   - lastRequest: when the last request was made; nil if none yet.
    ///   - movedSince: meters the reference car has moved since then; pass `.infinity` if the
    ///     reference car changed.
    ///   - consecutiveFailures: failed requests in a row.
    func shouldRequest(
        lastRequest: Date?, movedSince: CLLocationDistance, now: Date, consecutiveFailures: Int = 0
    ) -> Bool {
        guard let lastRequest else { return true }
        let elapsed = now.timeIntervalSince(lastRequest)
        if elapsed < 0 { return true } // clock went backwards: don't wait it out
        if consecutiveFailures > 0 {
            let factor = pow(2, Double(min(consecutiveFailures, 10) - 1))
            return elapsed >= min(maxBackoff, maxInterval * factor)
        }
        if elapsed < minInterval { return false }
        if elapsed >= maxInterval { return true }
        return movedSince >= movementThreshold
    }
}
