import CoreLocation
import Foundation
import Observation
import OSLog

/// The tracker duty of a `TripSession`: runs the car's `TrackingService` and everything that goes with it.
///
/// Owns the tracking session key (same car, main route and meeting point), the startup (one fix, then the car's own
/// route, then tracking), the car-route service and the fixes it is fed, and the restart when the car doc's route
/// changes. `TripSession` still owns what decides whether this phone has the duty (the listeners, pause, leave, end,
/// the meeting-point answer) and tells this type, in `reevaluate`, whether to track and what to track with; it calls
/// `stopNow()` before any network call on pause, leave and end.
@Observable @MainActor
final class TrackingDuty {
    /// What the session wants tracked right now, read once per `reevaluate`.
    struct Wanted {
        var trip: Trip
        var car: Car
        var carId: String
        var stops: [PlannedStop]
        var skipsMeetingPoint: Bool
        /// The car's answer on the meeting point has not been read yet, so a session may not be keyed on it.
        var waitsForAnswer: Bool
    }

    private(set) var isTracking = false {
        didSet { PlacesRefresher.tripRunning = isTracking }
    }

    /// The trip's main route as the session holds it right now (startup finishes after the trip may have changed).
    @ObservationIgnored var mainRoute: () -> String? = { nil }

    @ObservationIgnored private let tripId: String
    @ObservationIgnored private let tracker: TrackingControlling
    @ObservationIgnored private let carRouteFactory: CarRouteFactory
    @ObservationIgnored private let ensureTimeout: Duration
    @ObservationIgnored private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ikut", category: "TripSession")
    /// The tracking session in progress (same car and main route); nil when not the tracker.
    @ObservationIgnored private var sessionKey: SessionKey?
    /// Bumped whenever a session ends or begins; stale startup and fix tasks compare against it.
    @ObservationIgnored private var sessionGeneration = 0
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var carRoute: CarRouteControlling?
    /// Signature of the own route `TrackingService` was last started with.
    @ObservationIgnored private var trackedCarRoute: [Double]?

    private struct SessionKey: Equatable {
        var carId: String
        var tripRoute: String
        /// Latitude and longitude of the meeting point; nil without one.
        var meetingPoint: [Double]?
    }

    init(tripId: String, tracker: TrackingControlling, carRouteFactory: @escaping CarRouteFactory, ensureTimeout: Duration) {
        self.tripId = tripId
        self.tracker = tracker
        self.carRouteFactory = carRouteFactory
        self.ensureTimeout = ensureTimeout
        self.tracker.onFix = { [weak self] fix in self?.handle(fix: fix) }
    }

    /// The session's deinit: no later fix, tracking stopped, and the tracking session ended (the generation goes up), so a
    /// startup still waiting for the first fix or `ensureRoute` can't start tracking once the session is gone.
    /// (`PlacesRefresher` is the session's to reset.)
    func shutDown() {
        tracker.onFix = nil
        stopNow()
    }

    /// Stops tracking synchronously and ends the session: no later fix reaches the car-route service.
    func stopNow() {
        tracker.stop()
        sessionGeneration += 1
        startupTask?.cancel()
        startupTask = nil
        carRoute = nil
        sessionKey = nil
        trackedCarRoute = nil
        isTracking = false
    }

    /// Starts, restarts (own route changed) or stops tracking to match what the session wants (nil: nothing).
    ///
    /// A restart happens in exactly one place: here, when the car doc's `route` differs from the one
    /// tracking runs with. A reroute by the car-route service lands here through the snapshot of its own write.
    func reevaluate(_ wanted: Wanted?) {
        guard let wanted else {
            if tracker.isTracking || sessionKey != nil { stopNow() }
            isTracking = tracker.isTracking
            return
        }
        let trip = wanted.trip, car = wanted.car, carId = wanted.carId
        // The session wants tracking only on an active trip, so this is the same as `startedAt != nil` there.
        let started = TripSessionLogic.isStarted(trip)
        if wanted.waitsForAnswer {
            isTracking = tracker.isTracking
            return
        }
        let running = sessionKey.flatMap { key -> TripSessionLogic.RunningSession? in
            guard key.carId == carId, key.tripRoute == trip.route else { return nil }
            return TripSessionLogic.RunningSession(
                meetingPoint: key.meetingPoint.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) })
        }
        let meetingPoint = TripSessionLogic.sessionMeetingPoint(
            in: wanted.stops, skippingAlong: wanted.skipsMeetingPoint, carState: car.state, tripStarted: started,
            running: running)
        let key = SessionKey(
            carId: carId, tripRoute: trip.route, meetingPoint: meetingPoint.map { [$0.latitude, $0.longitude] })
        if key != sessionKey {
            stopNow()
            beginSession(
                key, trip: trip,
                car: TripSessionLogic.carForNewSession(car, hasMeetingPoint: meetingPoint != nil, tripStarted: started),
                meetingPoint: meetingPoint)
        } else if tracker.isTracking {
            let docRoute = TripSessionLogic.routeLine(from: car.route)
            if TripSessionLogic.signature(of: docRoute) != trackedCarRoute {
                startTracking(carId: carId, carRoute: docRoute)
            }
        }
        isTracking = tracker.isTracking
    }

    private func startTracking(carId: String, carRoute: RouteLine?) {
        trackedCarRoute = TripSessionLogic.signature(of: carRoute)
        tracker.start(
            tripId: tripId, carId: carId,
            mainRoute: TripSessionLogic.routeLine(from: mainRoute()) ?? RouteLine([]),
            carRoute: carRoute)
    }

    /// Becoming the tracker: one fix, then `ensureRoute`, then tracking with the own route.
    /// Tracking never waits on the network for long: `ensureRoute` is abandoned after `ensureTimeout`.
    private func beginSession(_ key: SessionKey, trip: Trip, car: Car, meetingPoint: CLLocationCoordinate2D?) {
        sessionKey = key
        sessionGeneration += 1
        let generation = sessionGeneration
        let service: CarRouteControlling?
        do {
            service = try carRouteFactory(tripId, key.carId, trip, car, meetingPoint)
        } catch {
            log.error("car route service unavailable: \(error.localizedDescription, privacy: .public)")
            service = nil
        }
        carRoute = service
        let docRoute = TripSessionLogic.routeLine(from: car.route)
        startupTask = Task { [weak self] in
            await self?.runStartup(generation: generation, carId: key.carId, service: service, docRoute: docRoute)
        }
    }

    private func runStartup(generation: Int, carId: String, service: CarRouteControlling?, docRoute: RouteLine?) async {
        if let service, let fix = await tracker.firstFix() {
            guard generation == sessionGeneration else { return }
            _ = await ensureRoute(service, at: fix.coordinate)
        }
        guard generation == sessionGeneration else { return }
        // On failure the service still holds the route it resumed with (nil: main route only).
        startTracking(carId: carId, carRoute: service.map(\.routeLine) ?? docRoute)
        isTracking = tracker.isTracking
        // No reconcile with the car doc here: it may not yet show the route `ensureRoute` just wrote,
        // and the snapshot of that write restarts tracking if it differs.
    }

    /// True if `ensureRoute` succeeded in time. A late success still reaches us as a car snapshot.
    private func ensureRoute(_ service: CarRouteControlling, at location: CLLocationCoordinate2D) async -> Bool {
        let race = EnsureRace()
        let timeout = ensureTimeout
        return await withCheckedContinuation { continuation in
            race.continuation = continuation
            let work = Task { @MainActor [log] in
                do {
                    _ = try await service.ensureRoute(at: location)
                    race.finish(true)
                } catch {
                    log.error("ensureRoute failed, tracking the main route: \(error.localizedDescription, privacy: .public)")
                    race.finish(false)
                }
            }
            let timer = Task { @MainActor [log] in
                try? await Task.sleep(for: timeout)
                if race.finish(false) { log.error("ensureRoute timed out, tracking the main route") }
            }
            race.cancelTimer = { timer.cancel() }
            _ = work
        }
    }

    /// Once-only result for `ensureRoute` versus its timeout.
    @MainActor
    private final class EnsureRace {
        var continuation: CheckedContinuation<Bool, Never>?
        var cancelTimer: (() -> Void)?

        @discardableResult
        func finish(_ success: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            cancelTimer?()
            continuation.resume(returning: success)
            return true
        }
    }

    /// Every published fix goes to the car-route service without blocking tracking. A reroute needs no
    /// action here: the write it made comes back as a car snapshot, which restarts tracking.
    private func handle(fix: LocationFix) {
        guard let service = carRoute, tracker.isTracking else { return }
        let generation = sessionGeneration
        Task { [weak self] in
            let event = await service.handle(fix: fix)
            guard let self, generation == self.sessionGeneration else { return }
            if case .failed(let message) = event { self.log.error("car route update failed: \(message, privacy: .public)") }
        }
    }
}
