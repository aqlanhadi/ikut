import CoreLocation
import Foundation
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
