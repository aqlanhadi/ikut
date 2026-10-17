import FirebaseAuth
import FirebaseFirestore
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

    func start(tripId: String, carId: String, mainRoute: RouteLine, carRoute: RouteLine?) {
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

    @Test func routeLineDecoding() {
        #expect(TripSessionLogic.routeLine(from: nil) == nil)
        #expect(TripSessionLogic.routeLine(from: "") == nil)
        #expect(TripSessionLogic.routeLine(from: "_p~iF~ps|U_ulLnnqC")?.coordinates.count == 2)
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
}
