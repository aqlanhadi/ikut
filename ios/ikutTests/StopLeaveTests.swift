import FirebaseAuth
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("Leaving a planned stop")
@MainActor
struct StopLeaveTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func stop(
        _ id: String = "s1", at offset: Double = 20_000, kind: PlannedStopKind = .fuel, minutes: Int? = 20,
        meetAt: Date? = nil, arrivedAt: Date? = nil, leftAt: Date? = nil, skipped: Bool = false
    ) -> PlannedStop {
        var s = PlannedStop(
            id: nil, name: "R&R Tapah", coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: offset, kind: kind,
            minutes: kind == .meet ? nil : minutes, meetAt: meetAt, order: 0, skipped: skipped ? true : nil,
            arrivedAt: arrivedAt, leftAt: leftAt, leftBy: leftAt == nil ? nil : "u1")
        s.id = id
        return s
    }

    // MARK: Leaving at

    @Test func leavingAtIsTheLeadCarsArrivalPlusThePlannedLength() {
        let s = stop(arrivedAt: t0)
        #expect(StopLeave.leavingAt(s) == t0.addingTimeInterval(20 * 60))
        // Every phone reads the same stored arrival, so every phone gets the same line.
        let utc = TimeZone(identifier: "UTC")!, en = Locale(identifier: "en_GB")
        let arrived = Date(timeIntervalSince1970: 1_799_996_400)   // on the hour, UTC
        let line = StopLeave.leavingLine(stop(arrivedAt: arrived), locale: en, timeZone: utc)
        let expected = ConvoyFormat.clock(arrived.addingTimeInterval(1200), locale: en, timeZone: utc)
        #expect(line == "Leaving at \(expected)")
        #expect(expected.hasSuffix(":20"))
    }

    @Test func noTimeWithoutALengthOrAnArrival() {
        #expect(StopLeave.leavingAt(stop(arrivedAt: nil)) == nil)
        #expect(StopLeave.leavingAt(stop(minutes: nil, arrivedAt: t0)) == nil)
        #expect(StopLeave.leavingLine(stop(minutes: nil, arrivedAt: t0)) == nil)
    }

    @Test func aMeetingPointLeavesAtItsMeetTime() {
        let meet = stop(kind: .meet, meetAt: t0)
        #expect(StopLeave.leavingAt(meet) == t0)
        // An arrival never moves a meeting time; a meeting point with no time has no line.
        #expect(StopLeave.leavingAt(stop(kind: .meet, meetAt: t0, arrivedAt: t0.addingTimeInterval(999))) == t0)
        #expect(StopLeave.leavingAt(stop(kind: .meet)) == nil)
    }

    // MARK: Who may

    @Test func onlyTheLeadCarsTrackerOrTheOrganizerCanLeaveAStopStillToDo() {
        let s = stop()
        #expect(StopLeave.canLeave(stop: s, isLeadTracker: true, isOrganizer: false, tripStarted: true))
        #expect(StopLeave.canLeave(stop: s, isLeadTracker: false, isOrganizer: true, tripStarted: true))
        #expect(!StopLeave.canLeave(stop: s, isLeadTracker: false, isOrganizer: false, tripStarted: true))
        #expect(!StopLeave.canLeave(stop: s, isLeadTracker: true, isOrganizer: true, tripStarted: false))
        #expect(!StopLeave.canLeave(stop: stop(skipped: true), isLeadTracker: true, isOrganizer: true, tripStarted: true))
        #expect(!StopLeave.canLeave(stop: stop(leftAt: t0), isLeadTracker: true, isOrganizer: true, tripStarted: true))
    }

    @Test func aLeftStopIsDoneForEveryone() {
        let left = stop("a", at: 10_000, leftAt: t0)
        let next = stop("b", at: 30_000)
        #expect(left.isLeft && !left.isOpen && left.isActive)
        // Next stop moves on, even for a car still beside the left stop.
        #expect(NextStop.next(in: [left, next], from: 10_050)?.name == next.name)
        #expect(NextStop.cell(stops: [left], offset: 10_050, pace: 0.1) == nil)
        // The card closes: no target, no place among the stops.
        #expect(StopArrival.target(stopId: "a", in: [left, next]) == nil)
        #expect(StopArrival.place(of: "a", in: [left, next]) == nil)
        #expect(StopArrival.place(of: "b", in: [left, next])?.count == 1)
        // A left meeting point is not the joining car's next stop any more.
        let meet = stop("m", at: 0, kind: .meet, leftAt: t0)
        #expect(NextStop.joiningCell(stops: [meet], distance: 5_000, seconds: 300) == nil)
        // And a car cannot be offered the skip button on it.
        #expect(!SkipAnswers.canSkip(stop: left, isLeadCar: false, carOffset: 1_000, tripStarted: true))
        // No approach pill for it.
        var watch = StopApproach()
        #expect(watch.check(stops: [left], myOffset: 9_000).isEmpty)
        #expect(!StopApproach.isShowing(left, distance: 1_500))
    }

    // MARK: arrivedAt

    func position(at meters: Double, age: TimeInterval = 5, now: Date) -> Position {
        Position(
            id: nil, location: GeoPoint(latitude: 3 + meters / 111_195, longitude: 101), speed: 20, heading: 0,
            routeOffset: meters, convoyOffset: meters, battery: 0.8, updatedAt: now.addingTimeInterval(-age))
    }

    @Test func theLeadCarMarksItsArrivalOnceAtAStopWithALength() {
        let now = t0
        func marks(_ s: PlannedStop, lead: Bool = true, started: Bool = true, at: Double = 19_900, age: TimeInterval = 5) -> Bool {
            StopLeave.stopToMarkArrived(
                stops: [s], isLeadTracker: lead, tripStarted: started, position: position(at: at, age: age, now: now),
                offset: at, now: now) != nil
        }
        #expect(marks(stop()))
        #expect(!marks(stop(), at: 15_000), "still short of the stop")
        #expect(!marks(stop(), age: 90), "a stale fix is not here")
        #expect(!marks(stop(), lead: false), "only the lead car's phone")
        #expect(!marks(stop(), started: false))
        #expect(!marks(stop(arrivedAt: now)), "written once")
        #expect(!marks(stop(minutes: nil)), "no planned length, nothing to count from")
        #expect(!marks(stop(kind: .meet, meetAt: now)), "a meeting point has its own time")
        #expect(!marks(stop(skipped: true)))
        #expect(!marks(stop(leftAt: now)))
    }

    private final class Quiet: AlertAnnouncing {
        func announce(event: TripEvent, distance: Double?) async -> Bool { false }
        func announce(alert: TripAlert) -> Bool { true }
    }

    @Test func theMapModelWritesArrivedAtOnceForTheLeadCar() async {
        let model = MapDemo.model()
        model.tripStarted = true
        let lead = model.convoy.convoy.first?.convoyOffset ?? 0
        var s = stop("s1", at: lead + 40)
        s.coordinate = model.convoy.convoy[0].position.location
        final class Writes: @unchecked Sendable { var list: [String] = [] }
        let writes = Writes()
        model.arrivalWriter = { tripId, stopId in writes.list.append("\(tripId)/\(stopId)") }
        model.startHazardAlerts(announcer: Quiet(), userId: "u-c1", tripId: "demo")
        model.setStops([s])
        model.setCars(model.cars)
        model.setCars(model.cars)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(writes.list == ["demo/s1"])
        // The stop now carries arrivedAt (the listener brings it back): nothing more is written.
        s.arrivedAt = t0
        model.setStops([s])
        model.setCars(model.cars)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(writes.list.count == 1)
    }

    // MARK: Words

    func car(_ id: String, _ name: String, number: Int) -> Car {
        Car(id: id, name: name, color: "#2563EB", trackerUserId: "u-\(id)", isLead: number == 1, route: nil,
            mergeOffset: nil, state: .convoy, number: number)
    }

    func row(_ id: String, _ name: String, _ status: StopArrival.Status, number: Int = 2) -> StopArrival.Row {
        .init(id: id, car: car(id, name, number: number), status: status)
    }

    @Test func theOwnerWordCutsThePossessive() {
        #expect(StopLeave.ownerWord(car("c", "Hafiz’s Myvi", number: 2)) == "Hafiz")
        #expect(StopLeave.ownerWord(car("c", "Hafiz's Myvi", number: 2)) == "Hafiz")
        #expect(StopLeave.ownerWord(car("c", "Red Myvi", number: 2)) == "Red Myvi")
        #expect(StopLeave.ownerWord(car("c", "’s car", number: 2)) == "’s car")
    }

    @Test func waitingLineNamesWhoIsStillComing() {
        let here = row("c1", "Aqlan’s Myvi", .here, number: 1)
        let hafiz = row("c2", "Hafiz’s Axia", .away(distance: 2_000, seconds: 180))
        #expect(StopLeave.waitingLine([here, hafiz], leaving: "c1") == "Hafiz is 3 min away")
        #expect(StopLeave.waitingLine([here, row("c2", "Hafiz’s Axia", .away(distance: 9_000, seconds: nil))], leaving: "c1")
            == "Hafiz is 9.0 km away")
        #expect(StopLeave.waitingLine([here, row("c2", "Hafiz’s Axia", .unknown)], leaving: "c1") == "Hafiz is still on the way")
        #expect(StopLeave.waitingLine([here, hafiz, row("c3", "Wyna’s Bezza", .unknown, number: 3)], leaving: "c1")
            == "Hafiz and 1 more are still on the way")
        #expect(StopLeave.waitingLine([here, row("c2", "Hafiz’s Axia", .here)], leaving: "c1") == nil)
        // My own car is not waited for, even if the organizer taps from a car that has not arrived.
        #expect(StopLeave.waitingLine([row("c1", "Aqlan’s Myvi", .away(distance: 900, seconds: 60), number: 1)], leaving: "c1") == nil)
    }

    @Test func theConfirmIsOneSentence() {
        let s = stop()
        #expect(StopLeave.confirmSentence(stop: s, waiting: "Hafiz is 3 min away") == "Leave R&R Tapah now? Hafiz is 3 min away.")
        #expect(StopLeave.confirmSentence(stop: s, waiting: nil) == "Leave R&R Tapah now? Everyone is here.")
        #expect(StopLeave.confirmSentence(stop: stop(kind: .meet), waiting: nil)
            == "Start the convoy from R&R Tapah now? Everyone is here.")
        #expect(StopLeave.waitingForLead(leadCar: car("c1", "Aqlan’s Myvi", number: 1)) == "Aqlan taps Leave when everyone’s ready")
        #expect(StopLeave.waitingForLead(leadCar: nil) == "The lead car taps Leave when everyone’s ready")
    }
}

/// Runs against the local emulators with this branch's rules (`tools/with-rules.mjs`). Start them first, then:
/// `TEST_RUNNER_IKUT_EMULATOR_TESTS=1 xcodebuild test ...`
@Suite(.emulator, .serialized)
@MainActor
struct StopLeaveEmulatorTests {
    init() throws {
        Backend.configure()
        try Auth.auth().signOut()
    }

    /// The organizer (and lead car) marks its arrival once, then taps Leave once; a car that is neither cannot, and
    /// the left stop takes no more skip answers.
    @Test func theOrganizerLeavesAStopOnce() async throws {
        let trip = try await EmulatorTrip.make(name: "Leave", route: Fixtures.longRoute)
        let code = try await trip.code()
        let route = BuiltRoute(distance: 205_000, travelTime: 9_600, name: "E1", polyline: Fixtures.longRoute.polyline)
        let tapah = PlannedStop(
            id: "tapah", name: "R&R Tapah", coordinate: GeoPoint(latitude: 4.2, longitude: 101.2), routeOffset: 62_000,
            kind: .fuel, minutes: 20, order: 0)
        try await TripService.saveStops(tripId: trip.tripId, plan: StopPlanSave(route: route, stops: [tapah], removedIds: []))
        let ref = Firestore.firestore().document(FirestorePaths.stop(tripId: trip.tripId, stopId: "tapah"))

        // Before the start there is nothing to mark or leave.
        await #expect(throws: (any Error).self) { try await StopLeaveService.markArrived(tripId: trip.tripId, stopId: "tapah") }
        await #expect(throws: (any Error).self) {
            try await StopLeaveService.leave(tripId: trip.tripId, stopId: "tapah", userId: trip.uid)
        }
        await TripService.markStarted(tripId: trip.tripId)

        try await StopLeaveService.markArrived(tripId: trip.tripId, stopId: "tapah")
        let arrived = try await ref.getDocument(as: PlannedStop.self)
        let arrivedAt = try #require(arrived.arrivedAt)
        #expect(abs(arrivedAt.timeIntervalSinceNow) < 60)
        #expect(StopLeave.leavingAt(arrived) == arrivedAt.addingTimeInterval(20 * 60))
        // Written once: the second try is refused and the time stays.
        await #expect(throws: (any Error).self) { try await StopLeaveService.markArrived(tripId: trip.tripId, stopId: "tapah") }
        #expect(try await ref.getDocument(as: PlannedStop.self).arrivedAt == arrivedAt)

        try await StopLeaveService.leave(tripId: trip.tripId, stopId: "tapah", userId: trip.uid)
        let left = try await ref.getDocument(as: PlannedStop.self)
        #expect(left.isLeft && left.leftBy == trip.uid && !left.isOpen)
        #expect(left.arrivedAt == arrivedAt)
        await #expect(throws: (any Error).self) {
            try await StopLeaveService.leave(tripId: trip.tripId, stopId: "tapah", userId: trip.uid)
        }

        // A car that is neither the lead car nor the organizer cannot leave; a left stop takes no skip answer.
        try Auth.auth().signOut()
        try await Auth.auth().signInAnonymously()
        let joiner = try #require(Auth.auth().currentUser?.uid)
        let joined = try await LiveJoinAPI().join(
            code: code, displayName: "Wyna", car: .new(name: "Wyna's X70", color: TripService.palette[1]), tracker: true)
        await #expect(throws: (any Error).self) {
            try await StopLeaveService.leave(tripId: trip.tripId, stopId: "tapah", userId: joiner)
        }
        await #expect(throws: (any Error).self) {
            try await StopAnswerService.skip(tripId: trip.tripId, stopId: "tapah", carId: joined.carId, userId: joiner)
        }
    }
}
