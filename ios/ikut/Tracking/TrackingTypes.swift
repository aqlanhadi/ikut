import CoreLocation
import FirebaseFirestore
import Foundation

/// One raw location sample, reduced to Sendable values so it can cross actors and be faked in tests.
struct LocationFix: Sendable, Equatable {
    var latitude: Double
    var longitude: Double
    /// Meters per second; negative when CoreLocation has no valid speed.
    var speed: Double
    /// Degrees clockwise from north; negative when CoreLocation has no valid course.
    var course: Double
    var timestamp: Date
    /// Radius of uncertainty in meters (CoreLocation's `horizontalAccuracy`); 0 when not known (fakes, old callers).
    var horizontalAccuracy: Double = 0

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// How hard the location source works (D124): `low` while the convoy is stopped and this car is at rest.
enum TrackingPower: Sendable, Equatable {
    case full
    case low
}

/// Source of location fixes. `stop()` must stop delivering fixes immediately.
@MainActor
protocol LocationSource: AnyObject {
    func start(onFix: @escaping @Sendable (LocationFix) -> Void)
    func stop()
    /// Switches between full accuracy and the low-power mode of a car at rest. A source that has one mode ignores it.
    func setPower(_ power: TrackingPower)
}

extension LocationSource {
    func setPower(_ power: TrackingPower) {}
}

/// Writes a car's latest position, resolving once the write is acknowledged by the server.
protocol PositionWriting: Sendable {
    func write(_ position: Position, tripId: String, carId: String) async throws
}

/// Monotonic time, injectable so throttle timing is testable.
@MainActor
protocol TrackingClock: AnyObject {
    /// Seconds on a monotonic timeline.
    var now: TimeInterval { get }
    /// Suspends until `now >= deadline`; throws if cancelled.
    func sleep(until deadline: TimeInterval) async throws
}

@MainActor
final class SystemTrackingClock: TrackingClock {
    /// Seconds on the continuous clock, which keeps counting while the phone sleeps (`systemUptime` does not, and
    /// would stretch the 45 s heartbeat across a sleep).
    private let origin = ContinuousClock.now

    var now: TimeInterval {
        let d = origin.duration(to: .now)
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)), clock: .continuous)
    }
}

/// Writes `trips/{tripId}/positions/{carId}` with `setData` (overwrite). `updatedAt` is a server timestamp.
struct FirestorePositionWriter: PositionWriting {
    func write(_ position: Position, tripId: String, carId: String) async throws {
        let ref = Firestore.firestore().document(FirestorePaths.position(tripId: tripId, carId: carId))
        // The Codable overload has no async variant (it would return before the server acknowledges),
        // so bridge the completion handler: the publisher's one-in-flight guard depends on this waiting.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            do {
                try ref.setData(from: position) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
