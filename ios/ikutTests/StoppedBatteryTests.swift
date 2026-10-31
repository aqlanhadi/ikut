import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

private func fix(_ lon: Double = 0, speed: Double = 0, accuracy: Double = 10) -> LocationFix {
    LocationFix(
        latitude: 0, longitude: lon, speed: speed, course: 90, timestamp: Date(), horizontalAccuracy: accuracy)
}

private func position(_ lon: Double, speed: Double = 0, battery: Double? = 0.8) -> Position {
    var p = Position.fixture(
        location: GeoPoint(latitude: 0, longitude: lon), speed: speed, routeOffset: lon * 1000, updatedAt: nil)
    p.battery = battery
    return p
}

private let route = RouteLine((0...10).map { CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.01) })

/// About 167 m east of lon 0 at the equator.
private let farEast = 0.0015

// MARK: - Publisher

@MainActor
struct LowPowerPublisherTests {
    let clock = TestClock()
    let writer = FakeWriter()

    func make() -> PositionPublisher {
        PositionPublisher(tripId: "t", carId: "c", writer: writer, clock: clock)
    }

    @Test func lowPowerHeartbeatIs45SecondsWhateverTheSpeed() async {
        let p = make()
        p.submit(position(1, speed: 20))
        await settle()
        p.setLowPower(true)
        await clock.advance(by: 44)
        #expect(writer.written.count == 1)
        await clock.advance(by: 1.5)
        #expect(writer.written.count == 2)
        await clock.advance(by: 45)
        #expect(writer.written.count == 3)
    }

    @Test func aFixThatShowsNothingNewWaitsForTheHeartbeat() async {
        let p = make()
        p.submit(position(1))
        await settle()
        p.setLowPower(true)
        await clock.advance(by: 6)
        p.submit(position(2), urgent: false)
        await clock.advance(by: 30)
        #expect(writer.written.count == 1)
        await clock.advance(by: 10)
        #expect(writer.written.count == 2)
        #expect(writer.written[1].location.longitude == 2)
    }

    @Test func aFixThatMovedGoesOutAfterTheMinInterval() async {
        let p = make()
        p.submit(position(1))
        await settle()
        p.setLowPower(true)
        await clock.advance(by: 6)
        p.submit(position(2), urgent: true)
        await settle()
        #expect(writer.written.count == 2)
    }

    @Test func leavingLowPowerReplansTheWrite() async {
        let p = make()
        p.submit(position(1, speed: 20))
        await settle()
        p.setLowPower(true)
        await clock.advance(by: 20)
        p.setLowPower(false)
        await clock.advance(by: 0.5)  // 10 s moving interval, 20.5 s since the write
        #expect(writer.written.count == 2)
    }

    @Test func aFailedHeartbeatIsRetriedAfterFiveSecondsNotAnotherHeartbeat() async {
        let p = make()
        p.submit(position(1))
        await settle()
        p.setLowPower(true)
        writer.failNext = 1
        await clock.advance(by: 46)
        #expect(writer.written.count == 2)  // the heartbeat, refused
        await clock.advance(by: 4)
        #expect(writer.written.count == 2)
        await clock.advance(by: 1.5)
        #expect(writer.written.count == 3)
    }

    @Test func aHeartbeatCarriesTheBatteryOfTheMoment() async {
        let p = make()
        final class Level { var value = 0.8 }
        let level = Level()
        p.refresh = { old in
            var fresh = old
            fresh.battery = level.value
            return fresh
        }
        p.submit(position(1, battery: 0.8))
        await settle()
        level.value = 0.5
        await clock.advance(by: 31)
        #expect(writer.written.count == 2)
        #expect(writer.written[1].battery == 0.5)
    }
}

// MARK: - Service

@MainActor
struct StoppedBatteryTests {
    let source = FakeSource()
    let writer = FakeWriter()
    let clock = TestClock()

    func make() -> TrackingService {
        let service = TrackingService(source: source, writer: writer, clock: clock, batteryLevel: { 0.5 })
        service.start(tripId: "t", carId: "c", mainRoute: route, carRoute: nil)
        return service
    }

    func deliver(_ f: LocationFix) async {
        source.onFix?(f)
        await settle()
    }

    @Test func aCarAtRestInAStoppedConvoyDropsToLowPowerAfterTwoMinutes() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 119)
        #expect(service.power == .full)
        await clock.advance(by: 2)
        #expect(service.power == .low)
        #expect(source.powers == [.low])
    }

    @Test func aConvoyThatIsNotStoppedNeverDropsToLowPower() async {
        let service = make()
        await deliver(fix(0))
        await clock.advance(by: 600)
        #expect(service.power == .full)
        #expect(source.powers.isEmpty)
    }

    @Test func aCarStillDrivingInAStoppedConvoyKeepsFullTracking() async {
        let service = make()
        service.setConvoyStopped(true)
        for i in 1...8 {  // 4 minutes of driving, a fix every 30 s
            await clock.advance(by: 30)
            await deliver(fix(Double(i) * 0.003, speed: 15))
        }
        #expect(service.power == .full)
        #expect(source.powers.isEmpty)
    }

    @Test func aCarCreepingInThroughTheCarParkDoesNotSettleUntilItIsStill() async {
        let service = make()
        service.setConvoyStopped(true)
        for i in 1...6 {  // slow (under parked speed) but 150 m between fixes: always further than the rest radius
            await clock.advance(by: 60)
            await deliver(fix(Double(i) * 0.0015, speed: 2))
        }
        #expect(service.power == .full)
        await clock.advance(by: 121)
        #expect(service.power == .low)
    }

    @Test func lowPowerHeartbeatKeepsTheCarAliveAndJitterIsNotWrittenEarly() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        let before = writer.written.count
        await clock.advance(by: 20)
        await deliver(fix(0.0003))  // a coarse fix 33 m off: still at rest
        #expect(service.power == .low)
        #expect(writer.written.count == before)
        await clock.advance(by: 30)
        #expect(writer.written.count == before + 1)
        #expect(writer.written.last?.battery == 0.5)
    }

    @Test func movingOffBringsFullPowerBackAtOnceAndWritesTheFix() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        let before = writer.written.count
        await clock.advance(by: 6)
        await deliver(fix(farEast, speed: -1, accuracy: 30))  // a cell fix surely over 100 m away, no speed
        #expect(service.power == .full)
        #expect(source.powers == [.low, .full])
        #expect(writer.written.count == before + 1)
        #expect(writer.written.last?.location.longitude == farEast)
    }

    @Test func aCellFixFarOffButTooInaccurateToTellDoesNothing() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        let before = writer.written.count
        var seen = 0
        service.onFix = { _ in seen += 1 }
        await clock.advance(by: 6)
        await deliver(fix(0.0027, speed: -1, accuracy: 1_000))  // 300 m off, 1 km accuracy
        #expect(service.power == .low)
        #expect(source.powers == [.low])
        await clock.advance(by: 50)
        #expect(writer.written.count > before)  // the heartbeat still comes, with the parked place
        #expect(writer.written.allSatisfy { $0.location.longitude == 0 })
        #expect(seen == 0)
    }

    @Test func aDroppedCellJumpLeavesTheBuildersStateAlone() async {
        // A joining car: its own route runs from the north down onto the main route at lon 0.02.
        let own = RouteLine([
            CLLocationCoordinate2D(latitude: 0.02, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.02),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.05),
        ])
        let service = TrackingService(source: source, writer: writer, clock: clock, batteryLevel: { 0.5 })
        service.start(tripId: "t", carId: "c", mainRoute: route, carRoute: own)
        func at(_ lat: Double, _ lon: Double, speed: Double = 0, accuracy: Double = 10) -> LocationFix {
            LocationFix(
                latitude: lat, longitude: lon, speed: speed, course: 90, timestamp: Date(), horizontalAccuracy: accuracy)
        }
        await deliver(at(0.02, 0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        // A cell jump past the merge point, too inaccurate to tell: dropped, and it must not mark the car as merged.
        await deliver(at(0, 0.03, speed: -1, accuracy: 5_000))
        #expect(service.power == .low)
        // The car really moves off, still on its way to the main route.
        await clock.advance(by: 6)
        await deliver(at(0.0199, 0, speed: 8))
        #expect(service.power == .full)
        #expect(writer.written.last?.convoyOffset == nil)
    }

    @Test func aFixFasterThanParkedSpeedBringsFullPowerBack() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        await deliver(fix(0.0002, speed: 8))  // the speed MoveOff reads as moving
        #expect(service.power == .full)
    }

    @Test func continueBringsFullPowerBackAtOnce() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        service.setConvoyStopped(false)
        #expect(service.power == .full)
        #expect(source.powers == [.low, .full])
        await clock.advance(by: 600)
        #expect(service.power == .full)
    }

    @Test func aPhaseEndedBeforeTheTimerNeverLowersPower() async {
        let service = make()
        service.setConvoyStopped(true)
        await clock.advance(by: 100)
        service.setConvoyStopped(false)
        await clock.advance(by: 100)
        #expect(source.powers.isEmpty)
    }

    @Test func aRestartedTrackerDuringAStopSettlesAgain() async {
        let service = make()
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        #expect(service.power == .low)
        service.start(tripId: "t", carId: "c", mainRoute: route, carRoute: nil)  // the car's route changed
        #expect(service.power == .full)
        await clock.advance(by: 121)
        #expect(service.power == .low)
    }

    @Test func stoppingTrackingEndsLowPowerAndTheTimer() async {
        let service = make()
        service.setConvoyStopped(true)
        await clock.advance(by: 121)
        service.stop()
        #expect(service.power == .full)
        #expect(service.convoyStopped)
    }
}

// MARK: - Session wiring and the screen

@MainActor
struct StoppedBatteryScreenTests {
    @Test func theScreenMaySleepWhileTheConvoyIsStopped() {
        #expect(ScreenAwake.shouldHold(preference: true, onScreen: true, tripRunning: true, appActive: true))
        #expect(!ScreenAwake.shouldHold(
            preference: true, onScreen: true, tripRunning: true, appActive: true, trackerAtRest: true))
    }

    @Test func aCarThatIsNotAtRestKeepsTheScreenHeldWhateverTheConvoyDoes() {
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: "t1", userId: "u1", tracker: tracker, clock: { Fixtures.t0 })
        var stopped = Trip.fixture(route: Fixtures.longRoute.polyline, startedAt: Fixtures.t0.addingTimeInterval(-3_600))
        stopped.stoppedAt = Fixtures.t0
        session.applyForTesting(
            trip: stopped, member: Member(id: "u1", displayName: "A", carId: "c1", role: .organizer),
            car: Car.fixture("c1", lead: true, state: .convoy, tracker: "u1"))
        // A stopped convoy alone changes nothing: a moving car, or a phone with no tracker, is not at rest.
        #expect(session.convoyStopped)
        #expect(!session.trackerAtRest)
        #expect(ScreenAwake.shouldHold(
            preference: true, onScreen: true, tripRunning: true, appActive: true, trackerAtRest: session.trackerAtRest))
        tracker.onPowerChange?(true)
        #expect(session.trackerAtRest)
        tracker.onPowerChange?(false)
        #expect(!session.trackerAtRest)
    }

    @Test func theDutyForwardsTheStoppedPhaseToTheTracker() {
        let tracker = FakeTrackingController()
        let duty = TrackingDuty(
            tripId: "t", tracker: tracker, carRouteFactory: { _, _, _, _, _ in throw CocoaError(.fileNoSuchFile) },
            ensureTimeout: .seconds(1))
        duty.setConvoyStopped(true)
        #expect(tracker.convoyStopped)
        duty.setConvoyStopped(false)
        #expect(!tracker.convoyStopped)
    }
}

// MARK: - The session path (D124)

@MainActor
struct StoppedBatterySessionTests {
    let t0 = Fixtures.t0

    private final class Time {
        var now: Date
        init(_ d: Date) { now = d }
    }

    private func trip(stoppedAt: Date?) -> Trip {
        var trip = Trip.fixture(route: Fixtures.longRoute.polyline, startedAt: t0.addingTimeInterval(-3_600))
        trip.id = "t1"
        trip.stoppedAt = stoppedAt
        trip.stoppedBy = stoppedAt == nil ? nil : "u1"
        trip.stoppedEventId = stoppedAt == nil ? nil : "e1"
        return trip
    }

    private let member = Member(id: "u1", displayName: "A", carId: "c1", role: .organizer)
    private let car = Car.fixture("c1", lead: true, state: .convoy, tracker: "u1")

    @Test func theStoppedFlagGoesOnWithTheSnapshotOffOnContinueAndOffAtTheCap() {
        let time = Time(t0)
        let tracker = FakeTrackingController()
        let session = TripSession(tripId: "t1", userId: "u1", tracker: tracker, clock: { time.now })
        session.applyForTesting(trip: trip(stoppedAt: nil), member: member, car: car)
        #expect(!tracker.convoyStopped)
        session.applyForTesting(trip: trip(stoppedAt: t0), member: member, car: car)
        #expect(tracker.convoyStopped)
        // Continue: the snapshot comes back without stoppedAt.
        session.applyForTesting(trip: trip(stoppedAt: nil), member: member, car: car)
        #expect(!tracker.convoyStopped)
        // A phase nobody ends: over at 90 minutes, whatever the trip says.
        session.applyForTesting(trip: trip(stoppedAt: t0), member: member, car: car)
        #expect(tracker.convoyStopped)
        time.now = t0.addingTimeInterval(ConvoyStop.cap - 1)
        session.applyForTesting(trip: trip(stoppedAt: t0), member: member, car: car)
        #expect(tracker.convoyStopped)
        time.now = t0.addingTimeInterval(ConvoyStop.cap + 1)
        session.applyForTesting(trip: trip(stoppedAt: t0), member: member, car: car)
        #expect(!tracker.convoyStopped)
    }

    /// The lead car's phone in low power, end to end through the session: a coarse fix brings full tracking back, its
    /// positions follow, and `MoveOff` then ends the phase (Continue is written).
    @Test func theLeadCarsMoveOffEndsThePhaseFromLowPowerThroughTheSession() async {
        let time = Time(t0.addingTimeInterval(130))
        let source = FakeSource()
        let clock = TestClock()
        let service = TrackingService(source: source, writer: FakeWriter(), clock: clock, batteryLevel: { 0.5 })
        var resumed = 0
        let carRoute = FakeCarRoute()
        let session = TripSession(
            tripId: "t1", userId: "u1", tracker: service, carRouteFactory: { _, _, _, _, _ in carRoute },
            clock: { time.now }, stopResumer: { _ in resumed += 1 })
        func positions(_ lon: Double, speed: Double) -> [String: Position] {
            [
                "c1": Position.fixture(
                    location: GeoPoint(latitude: 0, longitude: lon), speed: speed, updatedAt: time.now)
            ]
        }
        let stopped = trip(stoppedAt: t0)
        session.applyForTesting(trip: stopped, member: member, car: car, positions: positions(0, speed: 0))
        // Startup: one fix, then tracking.
        await waitUntil { source.onFix != nil && source.started == 1 }
        source.onFix?(fix(0))
        await waitUntil { service.isTracking }
        #expect(service.isTracking)
        await settle()
        source.onFix?(fix(0))
        await settle()
        // Two minutes at rest: low power, and the car's own positions show it parked (the heartbeats).
        await clock.advance(by: 125)
        #expect(service.power == .low)
        #expect(session.trackerAtRest)
        session.applyForTesting(trip: stopped, member: member, car: car, positions: positions(0, speed: 0))
        time.now = time.now.addingTimeInterval(125)
        session.applyForTesting(trip: stopped, member: member, car: car, positions: positions(0, speed: 0))
        #expect(resumed == 0)
        // A coarse fix well away: full tracking again.
        source.onFix?(fix(farEast, speed: -1, accuracy: 30))
        await settle()
        #expect(service.power == .full)
        #expect(!session.trackerAtRest)
        // Moving positions follow at full rate, 67 m apart; past 500 m from where it rested the phase ends.
        for i in 1...10 where resumed == 0 {
            time.now = time.now.addingTimeInterval(4)
            session.applyForTesting(
                trip: stopped, member: member, car: car, positions: positions(Double(i) * 0.0006 + farEast, speed: 12))
            await settle()
        }
        await waitUntil { resumed == 1 }
        #expect(resumed == 1)
    }
}
