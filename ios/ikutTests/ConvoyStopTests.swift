import CoreLocation
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

    // MARK: The lead car moves off

    /// About `meters` north of (3, 101).
    func spot(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 3 + meters / 111_000, longitude: 101)
    }

    /// What `MoveOff` says at each fix, in order, from a fresh watch.
    func moveOff(_ fixes: [(phase: Date?, meters: Double)], moving: Set<Int> = []) -> [Bool] {
        var watch = ConvoyStop.MoveOff()
        var said: [Bool] = []
        for (i, fix) in fixes.enumerated() {
            said.append(watch.check(phase: fix.phase, here: spot(fix.meters), moving: moving.contains(i)))
        }
        return said
    }

    @Test func aLeadCarStillRollingInIsAnchoredWhereItComesToRest() {
        // The organizer tapped We've stopped while the lead car was still driving into the R&R: 700 m on, it parks.
        let said = moveOff([(t0, 0), (t0, 400), (t0, 700), (t0, 900), (t0, 1_300)], moving: [0, 1])
        #expect(said == [false, false, false, false, true])
        // A lead car that never slows down (We've stopped by mistake) is measured from its first fix.
        let never = moveOff([(t0, 0), (t0, 300), (t0, 600)], moving: [0, 1, 2])
        #expect(never == [false, false, true])
    }

    @Test func theLeadCarMovingMoreThan500mFromWhereItStoodEndsThePhaseOnce() {
        // The anchor, moving about the car park, then off; said once.
        let said = moveOff([(t0, 0), (t0, 300), (t0, 480), (t0, 560), (t0, 900)])
        #expect(said == [false, false, false, true, false])
    }

    @Test func aNewPhaseTakesANewAnchor() {
        // Stopped again 600 m on: the new anchor is there, so staying put says nothing.
        let later = t0.addingTimeInterval(1_800)
        let said = moveOff([(t0, 0), (t0, 600), (later, 600), (later, 700), (later, 1_200)])
        #expect(said == [false, true, false, false, true])
    }

    @Test func noPhaseForgetsTheAnchor() {
        // The same phase seen again (a listener blip) anchors where the car is now.
        let said = moveOff([(t0, 0), (nil, 2_000), (t0, 2_000), (t0, 2_300)])
        #expect(said == [false, false, false, false])
    }
}
