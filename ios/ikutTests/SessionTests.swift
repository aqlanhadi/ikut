import FirebaseAuth
import FirebaseFirestore
import CoreLocation
import Foundation
import Testing
@testable import ikut

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

struct SessionLogicTests {
    @Test func tracksOnlyTrackerOfActiveTrip() {
        #expect(TripSessionLogic.shouldTrack(userId: "u1", tripStatus: .active, isMember: true, trackerUserId: "u1"))
        #expect(!TripSessionLogic.shouldTrack(userId: "u1", tripStatus: .active, isMember: true, trackerUserId: "u2"))
        #expect(!TripSessionLogic.shouldTrack(userId: "u1", tripStatus: .active, isMember: true, trackerUserId: nil))
        #expect(!TripSessionLogic.shouldTrack(userId: "u1", tripStatus: .ended, isMember: true, trackerUserId: "u1"))
        #expect(!TripSessionLogic.shouldTrack(userId: "u1", tripStatus: nil, isMember: true, trackerUserId: "u1"))
        #expect(!TripSessionLogic.shouldTrack(userId: "u1", tripStatus: .active, isMember: false, trackerUserId: "u1"))
        #expect(!TripSessionLogic.shouldTrack(userId: "", tripStatus: .active, isMember: true, trackerUserId: ""))
    }

    @Test func explainerOnlyOnceAndOnlyWhenAsked() {
        #expect(TripSessionLogic.shouldPresentAlwaysExplainer(action: .showAlwaysExplainer, alreadyShown: false))
        #expect(!TripSessionLogic.shouldPresentAlwaysExplainer(action: .showAlwaysExplainer, alreadyShown: true))
        #expect(!TripSessionLogic.shouldPresentAlwaysExplainer(action: .ready, alreadyShown: false))
        // Always already granted: nothing to explain.
        let action = LocationAccess.nextAction(status: .always, accuracy: .full, context: .goingToBackground)
        #expect(!TripSessionLogic.shouldPresentAlwaysExplainer(action: action, alreadyShown: false))
        // When In Use while going to background: explain.
        let wiu = LocationAccess.nextAction(status: .whenInUse, accuracy: .full, context: .goingToBackground)
        #expect(TripSessionLogic.shouldPresentAlwaysExplainer(action: wiu, alreadyShown: false))
    }

    @Test func pauseIsActiveUntilItExpires() {
        let now = Date()
        let expiry = TripSessionLogic.pauseExpiry
        #expect(!TripSessionLogic.isPaused(pausedAt: nil, now: now))
        #expect(TripSessionLogic.isPaused(pausedAt: now, now: now))
        #expect(TripSessionLogic.isPaused(pausedAt: now.addingTimeInterval(-expiry + 1), now: now))
        #expect(!TripSessionLogic.isPaused(pausedAt: now.addingTimeInterval(-expiry), now: now))
        // A stale pause is not a pause.
        #expect(!TripSessionLogic.isPaused(pausedAt: now.addingTimeInterval(-3 * expiry), now: now))
        // Clock skew: a pause stamped slightly in the future still counts.
        #expect(TripSessionLogic.isPaused(pausedAt: now.addingTimeInterval(30), now: now))
    }

    @Test func isPausedReadsTheCar() {
        let now = Date()
        var car = testCar()
        #expect(!TripSessionLogic.isPaused(car, now: now))
        car.pausedAt = now.addingTimeInterval(-60)
        #expect(TripSessionLogic.isPaused(car, now: now))
        car.pausedAt = now.addingTimeInterval(-TripSessionLogic.pauseExpiry - 1)
        #expect(!TripSessionLogic.isPaused(car, now: now))
        #expect(!TripSessionLogic.isPaused(nil, now: now))
    }

    @Test func routeLineDecoding() {
        #expect(TripSessionLogic.routeLine(from: nil) == nil)
        #expect(TripSessionLogic.routeLine(from: "") == nil)
        #expect(TripSessionLogic.routeLine(from: "_p~iF~ps|U_ulLnnqC")?.coordinates.count == 2)
    }
}

private let mainPolyline = "_p~iF~ps|U_ulLnnqC"
private let ownPolyline = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"

private func testTrip(route: String = mainPolyline, status: TripStatus = .active) -> Trip {
    Trip(
        id: "t1", name: "T", code: "ABC123", organizerId: "u1", route: route,
        destination: Destination(name: "KB", coordinate: GeoPoint(latitude: 6.1, longitude: 102.2)),
        status: status)
}

private func testCar(route: String? = nil, tracker: String? = "u1") -> Car {
    Car(
        id: "c1", name: "Car", color: "#000000", trackerUserId: tracker, isLead: true,
        route: route, mergeOffset: nil, state: .joining, number: 1)
}

private let testMember = Member(id: "u1", displayName: "A", carId: "c1", role: .organizer)

private let someFix = LocationFix(latitude: 38.6, longitude: -120.3, speed: 10, course: 90, timestamp: Date())

@MainActor
private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
}

@MainActor
private struct Rig {
    let events = EventLog()
    let tracker = FakeTrackingController()
    let carRoute = FakeCarRoute()
    let session: TripSession

    init(ensureTimeout: Duration = .seconds(5)) {
        let carRoute = self.carRoute
        tracker.events = events
        carRoute.events = events
        session = TripSession(
            tripId: "t1", userId: "u1", tracker: tracker,
            carRouteFactory: { _, _, _, _ in carRoute }, ensureTimeout: ensureTimeout)
    }

    func becomeTracker(car: Car = testCar()) {
        session.applyForTesting(trip: testTrip(), member: testMember, car: car)
    }
}

@MainActor
struct SessionCarRouteTests {
    @Test func becomingTrackerEnsuresRouteOnceThenStartsWithOwnRoute() async throws {
        let rig = Rig()
        rig.carRoute.routeLine = TripSessionLogic.routeLine(from: ownPolyline)
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        #expect(rig.events.items == ["firstFix", "ensure", "start"])
        #expect(rig.carRoute.ensureCalls == 1)
        #expect(rig.tracker.startCount == 1)
        #expect(rig.tracker.carRoutes.first??.coordinates.count == 3)
        #expect(rig.session.isTracking)
    }

    @Test func ensureFailureFallsBackToMainRoute() async throws {
        let rig = Rig()
        rig.carRoute.ensureError = RouteError.noRoute
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.startCount == 1)
        #expect(rig.tracker.carRoutes.count == 1)
        #expect(rig.tracker.carRoutes[0] == nil)
        #expect(rig.events.items == ["firstFix", "ensure", "start"])
    }

    @Test func hangingEnsureTimesOutAndTracksMainRoute() async throws {
        let rig = Rig(ensureTimeout: .milliseconds(100))
        rig.carRoute.ensureHangs = true
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.startCount == 1)
        #expect(rig.tracker.carRoutes[0] == nil)
    }

    @Test func everyFixReachesHandle() async throws {
        let rig = Rig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        for i in 0..<3 {
            rig.tracker.emit(LocationFix(latitude: 38.5 + Double(i) / 100, longitude: -120, speed: 5, course: 0, timestamp: Date()))
        }
        try await eventually { rig.carRoute.handled.count == 3 }
        #expect(rig.carRoute.handled.count == 3)
        #expect(rig.carRoute.handled.map(\.latitude) == [38.5, 38.51, 38.52])
    }

    @Test func rerouteRestartsExactlyOnceViaTheSnapshot() async throws {
        let rig = Rig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.startCount == 1)

        // The service reports a reroute; that alone must not restart.
        rig.carRoute.nextEvent = .rerouted(CarRoutePlan(route: ownPolyline, mergeOffset: 10, state: .joining, kind: .merges))
        rig.tracker.emit(someFix)
        try await eventually { rig.carRoute.handled.count == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.tracker.startCount == 1)

        // The snapshot of the write restarts with the new route; repeats (e.g. a state change) do not.
        rig.becomeTracker(car: testCar(route: ownPolyline))
        #expect(rig.tracker.startCount == 2)
        #expect(rig.tracker.carRoutes[1]?.coordinates.count == 3)
        var converted = testCar(route: ownPolyline)
        converted.state = .convoy
        rig.becomeTracker(car: converted)
        #expect(rig.tracker.startCount == 2)
    }

    @Test func startupSnapshotMatchingOwnRouteDoesNotRestart() async throws {
        let rig = Rig()
        rig.carRoute.routeLine = TripSessionLogic.routeLine(from: ownPolyline)
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        // Our own write comes back with the route we already track.
        rig.becomeTracker(car: testCar(route: ownPolyline))
        #expect(rig.tracker.startCount == 1)
    }

    @Test func losingTrackerDutyStopsEverything() async throws {
        let rig = Rig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        rig.tracker.emit(someFix)
        try await eventually { rig.carRoute.handled.count == 1 }

        rig.becomeTracker(car: testCar(tracker: nil))
        #expect(!rig.tracker.isTracking)
        #expect(!rig.session.isTracking)
        rig.tracker.emit(someFix)
        // Even a fix delivered by a stale callback is dropped.
        rig.tracker.onFix?(someFix)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.carRoute.handled.count == 1)
    }

    @Test func losingDutyDuringStartupNeverStartsTracking() async throws {
        let rig = Rig()
        rig.carRoute.ensureHangs = true
        rig.becomeTracker()
        try await eventually { rig.carRoute.ensureCalls == 1 }
        rig.becomeTracker(car: testCar(tracker: nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.tracker.startCount == 0)
        #expect(!rig.session.isTracking)
    }
}

@MainActor
final class PauseWrites {
    var items: [Date?] = []
}

@MainActor
final class PauseClock {
    var now = Date()
}

@MainActor
struct SessionPauseTests {
    private func makeRig(_ clock: PauseClock = PauseClock()) -> (rig: PausedRig, writes: PauseWrites) {
        let writes = PauseWrites()
        return (PausedRig(clock: clock, writes: writes), writes)
    }

    @Test func pauseStopsTrackingBeforeTheWrite() async throws {
        let (rig, writes) = makeRig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        var trackingAtWrite: Bool?
        rig.onWrite = { trackingAtWrite = rig.tracker.isTracking }
        try await rig.session.pauseSharing()
        #expect(trackingAtWrite == false)
        #expect(!rig.tracker.isTracking)
        #expect(!rig.session.isTracking)
        #expect(rig.session.isPaused)
        #expect(writes.items.count == 1)
        #expect(writes.items[0] != nil)
        // The snapshot of the write (and others) does not restart tracking while paused.
        var paused = testCar()
        paused.pausedAt = writes.items[0]
        rig.becomeTracker(car: paused)
        rig.becomeTracker(car: testCar())
        #expect(!rig.tracker.isTracking)
        #expect(rig.tracker.startCount == 1)
    }

    @Test func pausedFixesAreDropped() async throws {
        let (rig, _) = makeRig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        try await rig.session.pauseSharing()
        rig.tracker.onFix?(someFix)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.carRoute.handled.isEmpty)
    }

    @Test func resumeClearsThenRestarts() async throws {
        let (rig, writes) = makeRig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        try await rig.session.pauseSharing()
        #expect(rig.tracker.startCount == 1)
        try await rig.session.resumeSharing()
        #expect(writes.items.count == 2)
        #expect(writes.items[1] == nil)
        #expect(!rig.session.isPaused)
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.isTracking)
        #expect(rig.tracker.startCount == 2)
    }

    @Test func failedResumeStaysPaused() async throws {
        let (rig, _) = makeRig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        try await rig.session.pauseSharing()
        rig.failWrites = true
        await #expect(throws: (any Error).self) { try await rig.session.resumeSharing() }
        #expect(rig.session.isPaused)
        #expect(!rig.tracker.isTracking)
    }

    @Test func stalePauseIsTreatedAsNotPaused() async throws {
        let clock = PauseClock()
        let (rig, _) = makeRig(clock)
        var stale = testCar()
        stale.pausedAt = clock.now.addingTimeInterval(-TripSessionLogic.pauseExpiry - 60)
        rig.becomeTracker(car: stale)
        #expect(!rig.session.isPaused)
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.isTracking)

        // A fresh pause on the doc (e.g. after a relaunch) keeps a new session from tracking.
        let (other, _) = makeRig(clock)
        var fresh = testCar()
        fresh.pausedAt = clock.now.addingTimeInterval(-60)
        other.becomeTracker(car: fresh)
        #expect(other.session.isPaused)
        try await Task.sleep(for: .milliseconds(50))
        #expect(other.tracker.startCount == 0)
    }

    @Test func losingTrackerDutyWhilePausedClearsLocalPause() async throws {
        let (rig, _) = makeRig()
        rig.becomeTracker()
        try await eventually { rig.tracker.isTracking }
        try await rig.session.pauseSharing()
        #expect(rig.session.isPaused)
        rig.becomeTracker(car: testCar(tracker: nil))
        #expect(!rig.session.isPaused)
        // Getting the car back later starts normally, not paused.
        rig.becomeTracker(car: testCar())
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.isTracking)
    }

    @Test func pauseIsIgnoredWhenNotTracker() async throws {
        let (rig, writes) = makeRig()
        rig.becomeTracker(car: testCar(tracker: "u2"))
        try await rig.session.pauseSharing()
        #expect(!rig.session.isPaused)
        #expect(writes.items.isEmpty)
    }

    @Test func pauseExpiresOnItsOwn() async throws {
        let (rig, _) = makeRig()
        // The doc carries a pause that has 50 ms left, so the expiry timer is scheduled for ~50 ms.
        rig.clock.now = Date()
        var paused = testCar()
        paused.pausedAt = rig.clock.now.addingTimeInterval(-TripSessionLogic.pauseExpiry + 0.05)
        rig.becomeTracker(car: paused)
        #expect(rig.session.isPaused)
        #expect(!rig.tracker.isTracking)
        // By the time the timer fires the clock is past the expiry.
        rig.clock.now = Date().addingTimeInterval(1)
        try await eventually { rig.tracker.isTracking }
        #expect(rig.tracker.isTracking)
        #expect(!rig.session.isPaused)
    }
}

@MainActor
final class PausedRig {
    let events = EventLog()
    let tracker = FakeTrackingController()
    let carRoute = FakeCarRoute()
    let clock: PauseClock
    var failWrites = false
    var onWrite: (() -> Void)?
    private(set) var session: TripSession!

    init(clock: PauseClock, writes: PauseWrites) {
        self.clock = clock
        let carRoute = self.carRoute
        session = TripSession(
            tripId: "t1", userId: "u1", tracker: tracker,
            carRouteFactory: { _, _, _, _ in carRoute }, ensureTimeout: .seconds(5),
            clock: { [clock] in clock.now },
            pauseWriter: { [unowned self] _, date in
                self.onWrite?()
                if self.failWrites { throw RouteError.noRoute }
                writes.items.append(date)
            })
    }

    func becomeTracker(car: Car = testCar()) {
        session.applyForTesting(trip: testTrip(), member: testMember, car: car)
    }
}

/// Runs against the local emulators; see TripServiceTests.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["IKUT_EMULATOR_TESTS"] == "1"), .serialized)
@MainActor
struct SessionEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    private struct Setup {
        var tripId: String
        var carId: String
        var uid: String
    }

    private func makeTrip() async throws -> Setup {
        try await AuthModel().signInAsGuest(name: "Aqlan")
        let uid = try #require(Auth.auth().currentUser?.uid)
        let ids = try await TripService.createTrip(
            name: "Session", destination: DestinationResult(
                name: "Kota Bharu", subtitle: "Kelantan",
                coordinate: .init(latitude: 6.1254, longitude: 102.2381)),
            route: BuiltRoute(distance: 205_400, travelTime: 8_700, name: "E1", polyline: "_p~iF~ps|U_ulLnnqC"),
            organizer: TripOrganizer(id: uid, displayName: "Aqlan"))
        return Setup(tripId: ids.tripId, carId: ids.carId, uid: uid)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func carRef(_ s: Setup) -> DocumentReference {
        Firestore.firestore().document(FirestorePaths.car(tripId: s.tripId, carId: s.carId))
    }

    @Test func trackerStartsAndNonTrackerDoesNot() async throws {
        let s = try await makeTrip()
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: tracker)
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking }
        #expect(tracker.isTracking)
        #expect(tracker.lastCarId == s.carId)
        #expect(tracker.lastCarRoute == nil)
        #expect(session.isTracking)

        // A listener for someone who is not the tracker never starts.
        let other = FakeTrackingController()
        let otherSession = TripSession(tripId: s.tripId, userId: "someone-else", tracker: other)
        otherSession.start()
        defer { otherSession.stop() }
        try await Task.sleep(for: .seconds(1))
        #expect(other.startCount == 0)
        #expect(!otherSession.isTracking)
    }


    @Test func farTrackerGetsOwnRouteMergeOffsetAndJoiningState() async throws {
        let s = try await makeTrip()
        let tracker = FakeTrackingController()
        // Far east of the main route's start; the fake route drives to it, then follows it.
        tracker.firstFixResult = LocationFix(
            latitude: 38.5, longitude: -119.0, speed: 10, course: 270, timestamp: Date())
        let directions = SessionFakeDirections(coordinates: [
            .init(latitude: 38.5, longitude: -119.0), .init(latitude: 38.5, longitude: -120.2),
            .init(latitude: 40.7, longitude: -120.95),
        ])
        let session = TripSession(
            tripId: s.tripId, userId: s.uid, tracker: tracker,
            carRouteFactory: { tripId, carId, trip, car in
                try CarRouteService(
                    tripId: tripId, carId: carId, mainRoute: trip.route,
                    destination: .init(latitude: 40.7, longitude: -120.95),
                    route: car.route, state: car.state, directions: directions)
            })
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking }
        #expect(tracker.isTracking)

        try await eventually { session.car?.route != nil }
        let car = try await carRef(s).getDocument(as: Car.self)
        #expect(car.route != nil)
        #expect(car.mergeOffset != nil)
        #expect(car.state == .joining)
        // Started once with the car doc as it was (the route is computed before tracking starts),
        // then restarted at most once by the snapshot if it raced; never more.
        #expect(tracker.startCount <= 2)
        #expect(tracker.lastCarRoute != nil)
    }

    @Test func releasingTrackerDutyStopsTracking() async throws {
        let s = try await makeTrip()
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: tracker)
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking }
        #expect(tracker.isTracking)

        try await carRef(s).updateData(["trackerUserId": FieldValue.delete()])
        try await eventually { !tracker.isTracking }
        #expect(!tracker.isTracking)
        #expect(!session.isTracking)
    }

    @Test func positionsAreExposedByCarId() async throws {
        let s = try await makeTrip()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: FakeTrackingController())
        session.start()
        defer { session.stop() }
        var b = PositionBuilder(mainRoute: RouteLine(Polyline.decode("_p~iF~ps|U_ulLnnqC")), carRoute: nil)
        let p = b.build(
            from: LocationFix(latitude: 38.5, longitude: -120.2, speed: 5, course: 90, timestamp: Date()),
            battery: 0.5)
        try await FirestorePositionWriter().write(p, tripId: s.tripId, carId: s.carId)
        try await eventually { session.positions[s.carId] != nil }
        #expect(session.positions[s.carId]?.speed == 5)
    }

    @Test func leaveStopsTrackingFirstReleasesDutyAndDeletesMember() async throws {
        let s = try await makeTrip()
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: tracker)
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking }

        // Once the member doc is gone the car is unreadable, so watch for the release as it happens.
        let released = Flag()
        let watch = carRef(s).addSnapshotListener { snapshot, _ in
            if let snapshot, snapshot.exists, snapshot.data()?["trackerUserId"] == nil { released.set() }
        }
        defer { watch.remove() }
        let memberGone = Flag()
        let watchMember = Firestore.firestore()
            .document(FirestorePaths.member(tripId: s.tripId, userId: s.uid))
            .addSnapshotListener { snapshot, _ in
                if let snapshot, !snapshot.exists { memberGone.set() }
            }
        defer { watchMember.remove() }

        var stoppedBeforeAwait = false
        tracker.onStop = { stoppedBeforeAwait = true }
        let leaving = Task { try await session.leave() }
        // leave() runs synchronously up to its first suspension: tracking is already stopped here.
        await Task.yield()
        #expect(stoppedBeforeAwait)
        #expect(!tracker.isTracking)
        try await leaving.value

        // The deleted member can no longer read its own doc, so the watcher above is the check.
        try await eventually { memberGone.value }
        #expect(memberGone.value)
        try await eventually { released.value }
        #expect(released.value)
        #expect(tracker.startCount == 1)
    }

    @Test func endTripSetsStatusAndStopsTracking() async throws {
        let s = try await makeTrip()
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: tracker)
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking && session.isOrganizer }
        #expect(session.isOrganizer)

        let ending = Task { try await session.endTrip() }
        await Task.yield()
        #expect(!tracker.isTracking)
        try await ending.value

        let trip = try await Firestore.firestore().document(FirestorePaths.trip(s.tripId)).getDocument(as: Trip.self)
        #expect(trip.status == .ended)
        #expect(trip.endedAt != nil)
        try await eventually { session.isEnded }
        #expect(session.isEnded)
        #expect(!tracker.isTracking)
    }

    @Test func otherMembersSeeEndedAndStopTracking() async throws {
        let s = try await makeTrip()
        nonisolated(unsafe) let organizerUser = try #require(Auth.auth().currentUser)
        let code = try await Firestore.firestore().document(FirestorePaths.trip(s.tripId))
            .getDocument(as: Trip.self).code

        // A second user joins as the tracker of a new car.
        try Auth.auth().signOut()
        try await AuthModel().signInAsGuest(name: "Siti")
        let uid2 = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: code, displayName: "Siti", car: .new(name: "Siti's car", color: "#D9480F"), tracker: true)
        let tracker2 = FakeTrackingController()
        let session2 = TripSession(tripId: s.tripId, userId: uid2, tracker: tracker2)
        session2.start()
        defer { session2.stop() }
        try await eventually { tracker2.isTracking }
        #expect(tracker2.isTracking)
        #expect(tracker2.lastCarId == joined.carId)

        // The organizer ends the trip.
        try await Auth.auth().updateCurrentUser(organizerUser)
        let organizerTracker = FakeTrackingController()
        let organizerSession = TripSession(tripId: s.tripId, userId: s.uid, tracker: organizerTracker)
        organizerSession.start()
        defer { organizerSession.stop() }
        try await eventually { organizerSession.isOrganizer && organizerTracker.isTracking }
        try await organizerSession.endTrip()

        try await eventually { session2.isEnded && !tracker2.isTracking }
        #expect(session2.isEnded)
        #expect(!tracker2.isTracking)
        #expect(!organizerTracker.isTracking)
    }

    @Test func pausedAtIsWrittenAndSeenByAnotherMember() async throws {
        let s = try await makeTrip()
        nonisolated(unsafe) let trackerUser = try #require(Auth.auth().currentUser)
        let code = try await Firestore.firestore().document(FirestorePaths.trip(s.tripId))
            .getDocument(as: Trip.self).code

        // A second member joins another car and listens to the trip.
        try Auth.auth().signOut()
        try await AuthModel().signInAsGuest(name: "Siti")
        _ = try await LiveJoinAPI().join(
            code: code, displayName: "Siti", car: .new(name: "Siti's car", color: "#D9480F"), tracker: false)
        nonisolated(unsafe) let otherUser = try #require(Auth.auth().currentUser)
        // The tracker pauses.
        try await Auth.auth().updateCurrentUser(trackerUser)
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: s.tripId, userId: s.uid, tracker: tracker)
        session.start()
        defer { session.stop() }
        try await eventually { tracker.isTracking }
        #expect(tracker.isTracking)
        try await session.pauseSharing()
        #expect(!tracker.isTracking)
        #expect(session.isPaused)
        let doc = try await carRef(s).getDocument(as: Car.self)
        #expect(TripSessionLogic.isPaused(doc, now: Date()))

        // The other member reads it and the car counts as paused.
        try await Auth.auth().updateCurrentUser(otherUser)
        let seen = try await carRef(s).getDocument(as: Car.self)
        #expect(TripSessionLogic.isPaused(seen, now: Date()))

        // A member who is not the tracker cannot clear or set it.
        await #expect(throws: (any Error).self) {
            try await carRef(s).updateData(["pausedAt": FieldValue.delete()])
        }
        await #expect(throws: (any Error).self) {
            try await carRef(s).updateData(["pausedAt": Timestamp(date: Date())])
        }

        // Resuming clears it.
        try await Auth.auth().updateCurrentUser(trackerUser)
        try await session.resumeSharing()
        try await eventually { tracker.isTracking }
        #expect(tracker.isTracking)
        let resumed = try await carRef(s).getDocument(as: Car.self)
        #expect(resumed.pausedAt == nil)
    }
}

private struct SessionFakeDirections: CarRouteDirections {
    var coordinates: [CLLocationCoordinate2D]
    func route(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> [CLLocationCoordinate2D] {
        coordinates
    }
}
