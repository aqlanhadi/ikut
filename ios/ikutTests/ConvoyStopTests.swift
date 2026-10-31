import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("The convoy's stopped phase")
struct ConvoyStopTests {
    let t0 = Fixtures.t0

    func trip(stoppedAt: Date?, status: TripStatus = .active) -> Trip {
        var trip = Trip.fixture(status: status, startedAt: t0.addingTimeInterval(-3_600))
        trip.stoppedAt = stoppedAt
        trip.stoppedBy = stoppedAt == nil ? nil : "lead"
        trip.stoppedEventId = stoppedAt == nil ? nil : "e1"
        return trip
    }

    // MARK: Start and end

    @Test func weveStoppedStartsThePhaseForEveryPhone() {
        let phase = ConvoyStop.current(trip(stoppedAt: t0), now: t0.addingTimeInterval(60))
        #expect(phase == ConvoyStop(since: t0, by: "lead", eventId: "e1"))
    }

    @Test func noPhaseBeforeWeveStoppedOrAfterContinue() {
        // Continue deletes the fields: the trip reads as it did before the stop.
        #expect(ConvoyStop.current(trip(stoppedAt: nil), now: t0) == nil)
        #expect(ConvoyStop.current(nil, now: t0) == nil)
    }

    @Test func anEndedTripHasNoPhase() {
        #expect(ConvoyStop.current(trip(stoppedAt: t0, status: .ended), now: t0) == nil)
    }

    @Test func aForgottenPhaseEndsByItselfAfter90Minutes() {
        let stopped = trip(stoppedAt: t0)
        #expect(ConvoyStop.current(stopped, now: t0.addingTimeInterval(89 * 60 + 59)) != nil)
        #expect(ConvoyStop.current(stopped, now: t0.addingTimeInterval(90 * 60)) == nil)
        #expect(ConvoyStop.endsAt(t0) == t0.addingTimeInterval(5_400))
    }

    // MARK: Who may

    @Test func onlyTheLeadCarsTrackerOrTheOrganizerStartsOrEndsIt() {
        #expect(ConvoyStop.mayStartOrEnd(isLeadTracker: true, isOrganizer: false))
        #expect(ConvoyStop.mayStartOrEnd(isLeadTracker: false, isOrganizer: true))
        #expect(!ConvoyStop.mayStartOrEnd(isLeadTracker: false, isOrganizer: false))
    }

    @Test func onlyWeveStoppedByTheLeadOrOrganizerStartsANewPhase() {
        func starts(_ reason: StopClosedReason, lead: Bool = false, org: Bool = false, active: Bool = false) -> Bool {
            ConvoyStop.startsWith(reason: reason, isLeadTracker: lead, isOrganizer: org, active: active)
        }
        #expect(starts(.stopped, lead: true))
        #expect(starts(.stopped, org: true))
        // The asker's own We've stopped closes the request only; a cancel never stops the convoy.
        #expect(!starts(.stopped))
        #expect(!starts(.cancelled, lead: true, org: true))
        // A second request closed while stopped keeps the phase that is on.
        #expect(!starts(.stopped, lead: true, active: true))
    }

    // MARK: What is held

    @Test func alertsBeyondTheStopPointAreHeldWhileStopped() {
        #expect(ConvoyStop.holds(offset: 20_400, stopOffset: 20_000))
        // Before the stop point: cars still coming in are warned as usual.
        #expect(!ConvoyStop.holds(offset: 19_800, stopOffset: 20_000))
        #expect(!ConvoyStop.holds(offset: 20_000, stopOffset: 20_000))
        // No stop point known (no lead car on the route), nothing held.
        #expect(!ConvoyStop.holds(offset: 20_400, stopOffset: nil))
    }

    @Test func aCarPastTheStopPointKeepsItsAlerts() {
        // At the stop, or a car park's length past the lead car: hold beyond the stop point.
        #expect(ConvoyStop.holdPoint(stopOffset: 20_000, myOffset: 19_000) == 20_000)
        #expect(ConvoyStop.holdPoint(stopOffset: 20_000, myOffset: 20_150) == 20_000)
        // 2 km on (missed the exit, or drove on): it is driving towards what lies ahead, so nothing is held.
        #expect(ConvoyStop.holdPoint(stopOffset: 20_000, myOffset: 22_000) == nil)
        #expect(!ConvoyStop.holds(offset: 22_400, stopOffset: ConvoyStop.holdPoint(stopOffset: 20_000, myOffset: 22_000)))
        // Unknown either way: nothing held.
        #expect(ConvoyStop.holdPoint(stopOffset: nil, myOffset: 19_000) == nil)
        #expect(ConvoyStop.holdPoint(stopOffset: 20_000, myOffset: nil) == nil)
    }

    // MARK: The lead car moves off (#682)

    /// About `meters` north of (3, 101).
    func spot(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 3 + meters / 111_000, longitude: 101)
    }

    struct Fix {
        var meters: Double
        /// Seconds after `t0`.
        var at: TimeInterval
        var moving: Bool
        var phase: Date? = Fixtures.t0
    }

    func rest(_ meters: Double, _ at: TimeInterval) -> Fix { Fix(meters: meters, at: at, moving: false) }
    func drive(_ meters: Double, _ at: TimeInterval) -> Fix { Fix(meters: meters, at: at, moving: true) }

    /// What `MoveOff` says at each fix, in order, from a fresh watch.
    func moveOff(_ fixes: [Fix]) -> [Bool] {
        var watch = ConvoyStop.MoveOff()
        var said: [Bool] = []
        for fix in fixes {
            said.append(watch.check(phase: fix.phase, here: spot(fix.meters), at: t0.addingTimeInterval(fix.at), moving: fix.moving))
        }
        return said
    }

    /// Parked at 0 m for 2 minutes: the anchor settles there.
    var settled: [Fix] { [rest(0, 0), rest(10, 60), rest(5, 125)] }

    @Test func aSettledLeadCarDrivingOffMoreThan500mEndsThePhaseOnce() {
        let said = moveOff(settled + [drive(300, 200), drive(560, 230), drive(900, 260)])
        #expect(said == settled.map { _ in false } + [false, true, false])
    }

    @Test func oneCoarseFixWhileParkedNeverEndsIt() {
        // Anchored at rest at 0 m, then one jumpy fix 700 m away with speed 0, then back.
        let said = moveOff(settled + [rest(700, 140), rest(0, 150), drive(450, 200)])
        #expect(!said.contains(true))
    }

    @Test func aLeadCarStillRollingInDoesNotEndIt() {
        // We've stopped tapped while the lead car is still driving in: moving fixes at 0 m and 550 m.
        #expect(moveOff([drive(0, 0), drive(550, 30)]) == [false, false])
    }

    @Test func aRedLightShortOfTheCarParkDoesNotSettle() {
        // Tapped at a red light (40 s at rest), then a 600 m drive on to the car park.
        let said = moveOff([rest(0, 0), rest(0, 40), drive(300, 60), drive(600, 90)])
        #expect(!said.contains(true))
    }

    @Test func aMistakenWeveStoppedEndsAt2kmWithoutSettling() {
        // The lead car never stops: measured from its first fix, 2 km on.
        let said = moveOff([drive(0, 0), drive(1_500, 60), drive(2_100, 80)])
        #expect(said == [false, false, true])
    }

    @Test func aNewPhaseStartsAfresh() {
        let later = t0.addingTimeInterval(1_800)
        var fixes = settled + [drive(600, 200)]
        // Stopped again 600 m on, not settled yet: a short drive says nothing.
        fixes += [Fix(meters: 600, at: 1_800, moving: false, phase: later), Fix(meters: 1_200, at: 1_830, moving: true, phase: later)]
        #expect(moveOff(fixes) == settled.map { _ in false } + [true, false, false])
    }

    @Test func noPhaseForgetsEverything() {
        let fixes = settled + [Fix(meters: 2_000, at: 130, moving: false, phase: nil), drive(2_600, 140)]
        #expect(!moveOff(fixes).contains(true))
    }
}

/// What the map holds while the convoy is stopped (D122), through the model.
@MainActor
@Suite("The map while the convoy is stopped")
struct ConvoyStopMapTests {
    let t0 = Fixtures.t0
    let phase = ConvoyStop(since: Fixtures.t0.addingTimeInterval(-600), by: "u1", eventId: "e1")

    func model() -> TripMapModel { TripMapModel(session: nil, convoy: ConvoyModel(clock: { Fixtures.t0 })) }

    func at(_ offset: Double, speed: Double = 0, age: TimeInterval = 5) -> Position {
        Position.fixture(speed: speed, convoyOffset: offset, updatedAt: t0.addingTimeInterval(-age))
    }

    /// Lead car "1", another car "2", my car "3", with the planned stops given.
    func feed(_ m: TripMapModel, _ positions: [String: Position], leadIs: String? = "1", stops: [PlannedStop] = []) {
        let cars = ["1", "2", "3"].map { Car.fixture($0, lead: $0 == leadIs, tracker: "u\($0)") }
        m.setStops(stops)
        m.apply(trip: nil, myCar: cars[2], myCarId: "3", positions: positions, isTracker: true)
        m.setCars(cars)
    }

    @Test func theStopPointIsTheLeadCarElseTheFrontCar() {
        let m = model()
        let parked = ["1": at(5_000), "2": at(6_000), "3": at(4_000)]
        feed(m, parked)
        #expect(m.stopPointOffset == nil)          // not stopped
        m.convoyStop = phase
        #expect(m.stopPointOffset == 5_000)        // the lead car, not the car further on
        feed(m, parked, leadIs: nil)
        #expect(m.stopPointOffset == 6_000)        // no lead car on the route: the front car
    }

    @Test func aLeadCarPullingAwayHoldsNothing() {
        let m = model()
        m.convoyStop = phase
        feed(m, ["1": at(5_000, speed: 20), "2": at(4_900), "3": at(4_000)])
        #expect(m.stopPointOffset == nil)
        // A stale fix says nothing about moving: the stop point stays.
        let quiet = model()
        quiet.convoyStop = phase
        feed(quiet, ["1": at(5_000, speed: 20, age: 600), "2": at(4_900), "3": at(4_000)])
        #expect(quiet.stopPointOffset == 5_000)
    }

    @Test func thePlannedStopTheConvoyIsPullingIntoStillAlerts() {
        let m = model()
        m.convoyStop = phase
        // The lead car parked at 20,000 just short of R&R Tapah (20,100); a stop much further on waits.
        let stops = [PlannedStop.fixture("near", offset: 20_100), PlannedStop.fixture("far", offset: 30_000, order: 1)]
        feed(m, ["1": at(20_000), "2": at(19_900), "3": at(18_200, speed: 25)], stops: stops)
        #expect(m.approachableStops.map(\.id) == ["near"])
        var watch = StopApproach()
        #expect(watch.check(stops: m.approachableStops, myOffset: 18_200).map(\.stopId) == ["near"])
        m.convoyStop = nil
        #expect(m.approachableStops.map(\.id) == ["near", "far"])
    }

    @Test func theGapWarningAndTheStaleColourWaitWhileStopped() {
        let m = model()
        // Together first, then car 3 falls 7 km behind: the gap warning; car 2 has gone quiet.
        feed(m, ["1": at(9_000, speed: 25), "2": at(8_950, speed: 25), "3": at(8_900, speed: 25)])
        feed(m, ["1": at(9_000, speed: 25), "2": at(8_950, speed: 25, age: 300), "3": at(2_000, speed: 25)])
        #expect(m.separationWarning != nil)
        #expect(m.convoy.convoyRows.first { $0.id == "2" }?.subtitleIsWarning == true)
        m.convoyStop = phase
        #expect(m.separationWarning == nil)
        #expect(m.convoy.convoyRows.first { $0.id == "2" }?.subtitleIsWarning == false)
    }

    @Test func onlyARulesRefusalFallsBackToClosingTheRequestAlone() {
        let denied = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.permissionDenied.rawValue)
        let offline = NSError(domain: FirestoreErrorDomain, code: FirestoreErrorCode.unavailable.rawValue)
        #expect(StopService.isRefusal(denied))
        #expect(!StopService.isRefusal(offline))
        #expect(!StopService.isRefusal(URLError(.timedOut)))
    }
}
