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

    /// Low power (D124): a car at rest in a stopped convoy. A coarser accuracy (100 m) and a fix only after 100 m of
    /// movement, so the system can leave the GPS chip off and a parked car gets almost no fixes (iOS may still use GPS
    /// when it is the only source, so the saving is not guaranteed). Not 3 km: that is one cell tower and would hide a
    /// drive-off for minutes; at 100 m the first fix after a car pulls out arrives about 10 s later at 36 km/h, and
    /// that fix puts tracking back to full. The activity type stays automotive.
    func setPower(_ power: TrackingPower) {
        switch power {
        case .full:
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.distanceFilter = 50
        case .low:
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = 100
        }
    }

    func start(onFix: @escaping @Sendable (LocationFix) -> Void) {
        delegate.onFix = onFix
        setPower(.full)
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
                    speed: l.speed, course: l.course, timestamp: l.timestamp,
                    horizontalAccuracy: l.horizontalAccuracy))
            }
        }

        nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
    }
}
