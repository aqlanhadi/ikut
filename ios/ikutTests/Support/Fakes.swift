import CoreLocation
import Foundation
import MapKit
@testable import ikut

// Test doubles shared by more than one test file.

// MARK: - Trip session

@MainActor
final class FakeTrackingController: TrackingControlling {
    private(set) var isTracking = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastCarId: String?
    private(set) var lastCarRoute: RouteLine?
    /// Records `isTracking` at the moment of each stop() call, to check ordering.
    var onStop: (() -> Void)?
    var onFix: ((LocationFix) -> Void)?
    /// What `firstFix()` returns; nil makes it return nil right away.
    var firstFixResult: LocationFix? = LocationFix(
        latitude: 38.5, longitude: -119.0, speed: 10, course: 90, timestamp: Date())
    /// Shared event log to check ordering against the fake car-route service.
    var events: EventLog?
    private(set) var carRoutes: [RouteLine?] = []

    func firstFix() async -> LocationFix? {
        events?.add("firstFix")
        return firstFixResult
    }

    /// Delivers a fix the way `TrackingService` does: only while tracking.
    func emit(_ fix: LocationFix) {
        guard isTracking else { return }
        onFix?(fix)
    }

    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?) {
        events?.add("start")
        carRoutes.append(carRoute)
        isTracking = true
        startCount += 1
        lastCarId = carId
        lastCarRoute = carRoute
    }

    func stop() {
        stopCount += 1
        isTracking = false
        onStop?()
    }
}

@MainActor
final class EventLog {
    private(set) var items: [String] = []
    func add(_ item: String) { items.append(item) }
}

@MainActor
final class FakeCarRoute: CarRouteControlling {
    var routeLine: RouteLine?
    var ensureError: Error?
    /// When set, `ensureRoute` never returns (an offline write).
    var ensureHangs = false
    var nextEvent: CarRouteEvent = .none
    var events: EventLog?
    private(set) var ensureCalls = 0
    private(set) var handled: [LocationFix] = []

    func ensureRoute(at location: CLLocationCoordinate2D) async throws -> CarRoutePlan {
        ensureCalls += 1
        events?.add("ensure")
        if ensureHangs { try await Task.sleep(for: .seconds(60)) }
        if let ensureError { throw ensureError }
        return CarRoutePlan(route: nil, mergeOffset: nil, state: .joining, kind: .merges)
    }

    func handle(fix: LocationFix) async -> CarRouteEvent {
        handled.append(fix)
        return nextEvent
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

// MARK: - Tracking

@MainActor
final class TestClock: TrackingClock {
    private(set) var now: TimeInterval = 1_000
    private var sleepers: [(deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []

    func sleep(until deadline: TimeInterval) async throws {
        if deadline <= now { return }
        try await withCheckedThrowingContinuation { sleepers.append((deadline, $0)) }
    }

    /// Moves time forward in one step, waking sleepers whose deadline has passed.
    func advance(by seconds: TimeInterval) async {
        now += seconds
        let due = sleepers.filter { $0.deadline <= now }
        sleepers.removeAll { $0.deadline <= now }
        for s in due { s.continuation.resume() }
        await settle()
    }
}

/// Lets queued main-actor tasks run.
@MainActor func settle() async {
    for _ in 0..<30 { await Task.yield() }
}

@MainActor
final class FakeWriter: PositionWriting {
    private(set) var written: [Position] = []
    /// When true, writes stay in flight until `completeAll()`.
    var slow = false
    private var pending: [CheckedContinuation<Void, Never>] = []

    nonisolated func write(_ position: Position, tripId: String, carId: String) async throws {
        await record(position)
    }

    private func record(_ p: Position) async {
        written.append(p)
        if slow { await withCheckedContinuation { pending.append($0) } }
    }

    func completeAll() async {
        let p = pending
        pending = []
        for c in p { c.resume() }
        await settle()
    }
}

@MainActor
final class FakeSource: LocationSource {
    var onFix: (@Sendable (LocationFix) -> Void)?
    private(set) var started = 0
    private(set) var stopped = 0
    func start(onFix: @escaping @Sendable (LocationFix) -> Void) { started += 1; self.onFix = onFix }
    func stop() { stopped += 1; onFix = nil }
}

// MARK: - Convoy

/// An ETA that always answers 30 minutes.
struct StubETA: ETAProviding {
    func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval { 1800 }
}

/// Records every alert and spoken event; `eventResult` is what a spoken event answers.
@MainActor
final class FakeAnnouncer: AlertAnnouncing {
    var eventResult = true
    var calls: [(id: String?, distance: Double?)] = []
    func announce(event: TripEvent, distance: Double?) async -> Bool {
        calls.append((event.id, distance))
        return eventResult
    }
    var alerts: [TripAlert] = []
    func announce(alert: TripAlert) -> Bool {
        alerts.append(alert)
        return true
    }
}

// MARK: - Routes

/// Hands out the car's own route from a queue (the last one repeats); an empty queue drives straight there.
struct CarRouteFakeDirections: CarRouteDirections {
    var routes: Box
    final class Box: @unchecked Sendable {
        var queue: [[CLLocationCoordinate2D]]
        var calls: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
        var fail = false
        init(_ q: [[CLLocationCoordinate2D]] = []) { queue = q }
    }
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        routes.calls.append((from, to))
        if routes.fail { throw RouteError.noRoute }
        if routes.queue.isEmpty { return line(from, to) }
        return routes.queue.count > 1 ? routes.queue.removeFirst() : routes.queue[0]
    }
}

final class CarRouteFakeWriter: CarRouteWriting, @unchecked Sendable {
    var writes: [CarRoutePlan] = []
    func write(_ plan: CarRoutePlan, tripId: String, carId: String) async throws { writes.append(plan) }
}

/// A leg along `points` at 25 m/s unless told otherwise.
func leg(_ points: [CLLocationCoordinate2D], seconds: Double? = nil, name: String = "E1") -> RouteLeg {
    let length = RouteLine(points).length
    return RouteLeg(coordinates: points, distance: length, travelTime: seconds ?? length / 25, name: name)
}

/// Straight roads between any two points, 25 m/s, counting the requests it gets. The first `failures` requests throw
/// `error` before it answers (they are not in `starts`), and a destination in `noRoadTo` (latitude) never has a road.
final class StraightRoads: LegRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(CLLocationCoordinate2D, CLLocationCoordinate2D)] = []
    private var _starts: [CLLocationCoordinate2D] = []
    private var _failures: Int
    private let error: Error
    var noRoadTo: Set<Double> = []

    init(failures: Int = 0, error: Error = RouteError.noRoute) {
        _failures = failures
        self.error = error
    }

    var requests: Int { lock.withLock { _requests.count } }
    /// Where each answered leg starts.
    var starts: [CLLocationCoordinate2D] { lock.withLock { _starts } }

    func leg(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> RouteLeg {
        let fail = lock.withLock {
            _requests.append((from, to))
            if _failures > 0 { _failures -= 1; return true }
            _starts.append(from)
            return false
        }
        if fail { throw error }
        if lock.withLock({ noRoadTo.contains(to.latitude) }) { throw RouteError.noRoute }
        return ikutTests.leg(line(from, to))
    }
}

/// A sleep that records how long it was asked for; asked for `hangFor`, it stays asleep until the test is over.
final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var _items: [Duration] = []
    private let hangFor: Duration?
    init(hangFor: Duration? = nil) { self.hangFor = hangFor }
    var items: [Duration] { lock.withLock { _items } }
    func add(_ d: Duration) { lock.withLock { _items.append(d) } }
    func sleep(_ d: Duration) async throws {
        add(d)
        if d == hangFor { try await Task.sleep(for: .seconds(3_600)) }
    }
}

// MARK: - Joining and searching

struct FakeJoinAPI: JoinAPI {
    var preview: TripPreview
    var joinResult = JoinResult(tripId: "t1", carId: "c9", trackerTaken: false)
    func preview(code: String) async throws -> TripPreview { preview }
    func join(code: String, displayName: String, car: JoinCarChoice, tracker: Bool) async throws -> JoinResult {
        joinResult
    }
}

/// Never answers; records what was typed.
@MainActor
final class FakeSuggestions: SuggestionSource {
    var onUpdate: ((String, Result<[SearchSuggestion], Error>) -> Void)?
    var asked: [(String, MKCoordinateRegion)] = []
    func update(query: String, region: MKCoordinateRegion) { asked.append((query, region)) }
    func stop() {}
}
