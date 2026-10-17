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

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Source of location fixes. `stop()` must stop delivering fixes immediately.
@MainActor
protocol LocationSource: AnyObject {
    func start(onFix: @escaping @Sendable (LocationFix) -> Void)
    func stop()
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
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(until deadline: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(max(0, deadline - now)))
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
