import CoreLocation

/// `CLLocationManager` configured for convoy tracking.
///
/// A `CLBackgroundActivitySession` is held while tracking. With only When-In-Use authorization,
/// `allowsBackgroundLocationUpdates` alone keeps updates alive after the app is backgrounded, but
/// the session is what lets a tracker that started in the foreground keep running (and be
/// relaunched into background tracking) without Always. It costs nothing when Always is granted.
@MainActor
final class CoreLocationSource: LocationSource {
    /// Fixes older than this are cached positions from before tracking started.
    nonisolated static let maxFixAge: TimeInterval = 15

    private let manager = CLLocationManager()
    private let delegate = Delegate()
    private var session: CLBackgroundActivitySession?

    init() {
        manager.delegate = delegate
        manager.activityType = .automotiveNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
    }

    func start(onFix: @escaping @Sendable (LocationFix) -> Void) {
        delegate.onFix = onFix
        session = CLBackgroundActivitySession()
        manager.startUpdatingLocation()
    }

    func stop() {
        delegate.onFix = nil
        manager.stopUpdatingLocation()
        session?.invalidate()
        session = nil
    }

    private final class Delegate: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
        // Written on the main actor; read on the thread CoreLocation delivers on (main, as the manager is created there).
        nonisolated(unsafe) var onFix: (@Sendable (LocationFix) -> Void)?

        nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let onFix else { return }
            for l in locations where l.horizontalAccuracy >= 0 && -l.timestamp.timeIntervalSinceNow <= CoreLocationSource.maxFixAge {
                onFix(LocationFix(
                    latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                    speed: l.speed, course: l.course, timestamp: l.timestamp))
            }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
    }
}
