import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("Skipping a stop for everyone")
struct StopSkipAllTests {
    func stop(
        kind: PlannedStopKind = .fuel, arrivedAt: Date? = nil, leftAt: Date? = nil, skipped: Bool = false
    ) -> PlannedStop {
        PlannedStop.fixture(
            offset: 60_000, coordinate: GeoPoint(latitude: 3, longitude: 101), kind: kind,
            minutes: kind == .meet ? nil : 20, skipped: skipped ? true : nil, arrivedAt: arrivedAt, leftAt: leftAt,
            leftBy: leftAt == nil ? nil : "u1")
    }

    func can(_ s: PlannedStop, org: Bool = true, started: Bool = true, reached: Bool = false) -> Bool {
        StopSkipAll.canSkip(stop: s, isOrganizer: org, tripStarted: started, carReached: reached)
    }

    // MARK: Who may

    @Test func theOrganizerSkipsAStopNobodyHasReached() {
        #expect(can(stop()))
    }

    @Test func onlyTheOrganizerAndOnlyAfterTheStart() {
        #expect(!can(stop(), org: false))
        #expect(!can(stop(), started: false))
    }

    @Test func notOnceACarIsThereOrTheLeadCarMarkedItsArrival() {
        #expect(!can(stop(), reached: true))
        #expect(!can(stop(arrivedAt: Fixtures.t0)))
    }

    @Test func notOnAStopAlreadyLeftOrSkipped() {
        #expect(!can(stop(leftAt: Fixtures.t0)))
        #expect(!can(stop(skipped: true)))
    }

    @Test func aMeetingPointCannotBeSkippedForEveryone() {
        // The organizer Leaves it (4a); a car still joining skips its own way in (5b).
        #expect(!can(stop(kind: .meet)))
        #expect(!StopSkipAll.isSkippable(stop: stop(kind: .meet), tripStarted: true, carReached: false))
    }

    @Test func aCarSeenAtTheStopAMomentAgoCountsAsReached() {
        func row(_ status: StopArrival.Status) -> StopArrival.Row {
            .init(id: "c", car: Car.fixture("c", name: "Car", number: 2), status: status)
        }
        #expect(StopSkipAll.carReached([row(.here)]))
        #expect(StopSkipAll.carReached([row(.away(distance: 5_000, seconds: 200)), row(.lastSeenHere)]))
        #expect(!StopSkipAll.carReached([row(.away(distance: 5_000, seconds: 200)), row(.unknown), row(.passed)]))
        #expect(!StopSkipAll.carReached([]))
    }

    // MARK: Words

    @Test func theWordsAreTheCanvasOnes() {
        #expect(StopSkipAll.caption == "For everyone. The route stays as it is.")
        #expect(StopSkipAll.confirmSentence(stop: stop()) == "Skip R&R Tapah for everyone? You can’t undo this, and the route stays as it is.")
    }

    @Test func theOrganizerIsNamedFromTheirMemberNotFromTheLeadCar() {
        func car(_ id: String, _ name: String, number: Int, lead: Bool) -> Car {
            Car.fixture(id, name: name, number: number, lead: lead)
        }
        // The lead car moved to Wyna; Aqlan's car (number 1) is not the lead.
        let cars = [car("c1", "Aqlan’s Myvi", number: 1, lead: false), car("c2", "Wyna’s X70", number: 2, lead: true)]
        #expect(StopSkipAll.passengerLine(organizerName: "Aqlan", cars: cars) == "Aqlan can skip this stop for everyone.")
        // Member not loaded yet: car number 1, never the lead car.
        #expect(StopSkipAll.passengerLine(organizerName: nil, cars: cars) == "Aqlan can skip this stop for everyone.")
        #expect(StopSkipAll.passengerLine(organizerName: "", cars: cars) == "Aqlan can skip this stop for everyone.")
        #expect(StopSkipAll.passengerLine(organizerName: nil, cars: []) == "The organizer can skip this stop for everyone.")
    }

    // MARK: The highway jump (4b check 1)

    /// The route is not rebuilt, so on a highway R&R it still turns off at the slip road and back. Cars that stay on
    /// the highway project onto the far end of that detour: each car's offset jumps forward by the detour's length
    /// (a few hundred metres) as it passes the slip road, at slightly different moments.
    private func car(_ id: String, number: Int) -> Car {
        Car.fixture(id, number: number, lead: number == 1)
    }
    private func pos(_ offset: Double) -> Position {
        Position.fixture(
            location: GeoPoint(latitude: 3, longitude: 101), speed: 28, routeOffset: offset, convoyOffset: offset)
    }
    private func order(_ lead: Double, _ behind: Double) -> ConvoySnapshot {
        ConvoyOrdering.order(
            cars: [car("a", number: 1), car("b", number: 2)], positions: ["a": pos(lead), "b": pos(behind)],
            now: Fixtures.t0)
    }

    @Test func aJumpOfAFewHundredMetresDoesNotSeparateACloseConvoy() {
        // The lead car has jumped 400 m and the second has not yet: 100 m apart becomes 500 m, far from 5 km / 5 min.
        let snap = order(60_500, 60_000)
        #expect(snap.convoy.map(\.id) == ["a", "b"])
        #expect(snap.convoy[1].gap?.isSeparated == false)
        #expect(snap.convoy[1].gap?.hasDrifted != true)
        // Once the second car has jumped too, the gap is the true 100 m again.
        #expect(order(60_500, 60_400).convoy[1].gap?.distance == 100)
    }

    @Test func aJumpNeverReordersCarsThatStayInTheirOrder() {
        // The order is by offset; the jump moves every car by the same length, so the lead stays the lead.
        for jump in stride(from: 0.0, through: 500, by: 100) {
            #expect(order(60_100 + jump, 60_000).convoy.map(\.id) == ["a", "b"])
        }
    }

    @Test func aJumpOnlyFlagsAConvoyThatWasWithin400mOfTheLimit() {
        // The edge case: 4.8 km apart, the lead jumps 400 m: 5.2 km reads as separated until the second car jumps
        // too (about 14 s at 100 km/h). A convoy that far apart is on its way to a warning anyway.
        #expect(order(64_800, 60_000).convoy[1].gap?.isSeparated == false)
        #expect(order(65_200, 60_000).convoy[1].gap?.isSeparated == true)
        #expect(order(65_200, 60_400).convoy[1].gap?.isSeparated == false)
    }

    @Test func aJumpAheadOfAHazardFiresItsApproachOnceAndNeverMissesIt() {
        // Hazard at 61_000. A 400 m jump from 60_050 (950 m short) lands 550 m short: still outside 500 m, then the
        // next fixes fire it once.
        var core = ApproachCore()
        let hazard = [ApproachCore.Candidate(id: "h", offset: 61_000)]
        #expect(core.evaluate(candidates: hazard, myOffset: 60_050).isEmpty)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_450).isEmpty)
        let fired = core.evaluate(candidates: hazard, myOffset: 60_550)
        #expect(fired.count == 1 && fired[0].distance == 450)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_600).isEmpty)
    }

    @Test func aJumpInsideTheWindowStillFiresWithItsRealDistance() {
        // From 900 m short to 500 m short in one fix: fires at the first fix inside 500 m.
        var core = ApproachCore()
        let hazard = [ApproachCore.Candidate(id: "h", offset: 61_000)]
        #expect(core.evaluate(candidates: hazard, myOffset: 60_100).isEmpty)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_500).map(\.distance) == [500])
    }

    @Test func aJumpBackwardsNeverRepeatsAnAlert() {
        // The bend before the slip road: the offset steps back 400 m; the alert already fired stays fired.
        var core = ApproachCore()
        let hazard = [ApproachCore.Candidate(id: "h", offset: 61_000)]
        #expect(core.evaluate(candidates: hazard, myOffset: 60_600).count == 1)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_200).isEmpty)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_700).isEmpty)
    }

    @Test func onlyAJumpLongerThanTheAlertWindowCanSkipOverAHazard() {
        // The one way to miss: the hazard sits inside the jumped stretch, more than 500 m short before the jump and
        // already behind after it. That needs a jump over 500 m; a slip road's detour is a few hundred metres.
        var core = ApproachCore()
        let hazard = [ApproachCore.Candidate(id: "h", offset: 60_300)]
        #expect(core.evaluate(candidates: hazard, myOffset: 59_700).isEmpty)
        #expect(core.evaluate(candidates: hazard, myOffset: 60_400).isEmpty)   // a 700 m jump
        var near = ApproachCore()
        #expect(near.evaluate(candidates: hazard, myOffset: 59_850).count == 1)   // 450 m short: fires first
    }
}
