import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("Next stop on the panel")
struct NextStopTests {
    func stop(_ name: String, _ offset: Double, skipped: Bool = false) -> PlannedStop {
        var stop = PlannedStop(
            id: nil, name: name, coordinate: GeoPoint(latitude: 0, longitude: 0), routeOffset: offset,
            kind: .fuel, minutes: nil, order: 0, skipped: skipped ? true : nil)
        stop.id = name
        return stop
    }

    @Test func skipsSkippedAndPassedStops() {
        let stops = [stop("Passed", 10_000), stop("Skipped", 40_000, skipped: true), stop("Tapah", 60_000), stop("Ipoh", 90_000)]
        #expect(NextStop.next(in: stops, from: 30_000)?.name == "Tapah")
        // Unsorted input still picks the nearest ahead.
        #expect(NextStop.next(in: stops.reversed(), from: 30_000)?.name == "Tapah")
        #expect(NextStop.next(in: stops, from: 61_000)?.name == "Ipoh")
    }

    @Test func noStopAhead() {
        #expect(NextStop.cell(stops: [], offset: 1_000, pace: 0.1) == nil)
        let allPassed = [stop("A", 1_000), stop("B", 2_000)]
        #expect(NextStop.cell(stops: allPassed, offset: 5_000, pace: 0.1) == nil)
        let allSkipped = [stop("A", 9_000, skipped: true)]
        #expect(NextStop.cell(stops: allSkipped, offset: 0, pace: 0.1) == nil)
        // A car still joining has no main-route offset.
        #expect(NextStop.cell(stops: [stop("A", 9_000)], offset: nil, pace: 0.1) == nil)
    }

    @Test func justPastTheStopStillCountsAsHere() throws {
        let stops = [stop("R&R Tapah", 20_000), stop("Ipoh", 50_000)]
        let cell = try #require(NextStop.cell(stops: stops, offset: 20_100, pace: 0.1))
        #expect(cell.name == "R&R Tapah")
        #expect(cell.isHere)
        #expect(cell.detail == "Here")
        // Well past: gone.
        #expect(NextStop.cell(stops: stops, offset: 20_200, pace: 0.1)?.name == "Ipoh")
    }

    @Test func cellText() throws {
        let stops = [stop("R&R Tapah", 38_000)]
        let cell = try #require(NextStop.cell(stops: stops, offset: 20_000, pace: 12 * 60 / 18_000))
        #expect(cell.name == "R&R Tapah")
        #expect(cell.detail == "18 km · 12 min")
        #expect(NextStop.cell(stops: stops, offset: 20_000, pace: nil)?.detail == "18 km")
        #expect(NextStop.cell(stops: stops, offset: 37_000, pace: 0.05)?.detail == "1.0 km · 1 min")
        #expect(NextStop.cell(stops: stops, offset: 37_500, pace: 0.05)?.detail == "500 m · 1 min")
    }

    @Test func paceFromEtaThenSpeed() {
        #expect(NextStop.pace(travelTimeToGo: 3_000, remaining: 60_000, speed: 25) == 0.05)
        #expect(NextStop.pace(travelTimeToGo: nil, remaining: 60_000, speed: 25) == 0.04)
        // Close to the end, the ETA is too coarse to spread: use speed.
        #expect(NextStop.pace(travelTimeToGo: 30, remaining: 300, speed: 20) == 0.05)
        #expect(NextStop.pace(travelTimeToGo: nil, remaining: 1_000, speed: nil) == nil)
    }

    @Test func aJoiningCarSeesTheMeetingPointOnly() throws {
        var meet = stop("Petronas Sungai Buloh", 0)
        meet.kind = .meet
        let stops = [meet, stop("Tapah", 60_000)]
        let cell = try #require(NextStop.joiningCell(stops: stops, distance: 9_000, seconds: 420))
        #expect(cell.name == "Petronas Sungai Buloh")
        #expect(cell.stopId == "Petronas Sungai Buloh")
        #expect(cell.detail == "9.0 km · 7 min")
        #expect(NextStop.joiningCell(stops: stops, distance: 100, seconds: 5)?.detail == "Here")
        // No meeting point, a skipped one, or an unknown distance: no cell.
        #expect(NextStop.joiningCell(stops: [stop("Tapah", 60_000)], distance: 9_000, seconds: 420) == nil)
        var skipped = meet
        skipped.skipped = true
        #expect(NextStop.joiningCell(stops: [skipped], distance: 9_000, seconds: 420) == nil)
        #expect(NextStop.joiningCell(stops: stops, distance: nil, seconds: nil) == nil)
    }

    @Test func afterTheLeaveAJoiningCarSeesTheNextStopAheadOfWhereItsRoadMeetsTheMainRoute() throws {
        var meet = stop("Petronas Sungai Buloh", 0)
        meet.kind = .meet
        meet.leftAt = Date(timeIntervalSince1970: 1_000)
        meet.leftBy = "u1"
        let stops = [meet, stop("Behind", 2_000), stop("Tapah", 60_000)]
        // 9 km of its own road to the merge, which is 10 km along the main route: Tapah is 50 km past it.
        let cell = try #require(NextStop.joiningCell(
            stops: stops, distance: 9_000, seconds: 420, mergeOffset: 10_000, pace: 0.05))
        #expect(cell.name == "Tapah")
        #expect(cell.stopId == "Tapah")
        #expect(cell.detail == "59 km · 49 min")
        // No pace: the distance alone. No known merge place: nothing to measure from.
        #expect(NextStop.joiningCell(stops: stops, distance: 9_000, seconds: 420, mergeOffset: 10_000)?.detail == "59 km")
        #expect(NextStop.joiningCell(stops: stops, distance: 9_000, seconds: 420) == nil)
        // No stop left ahead: no cell.
        #expect(NextStop.joiningCell(stops: [meet], distance: 9_000, seconds: 420, mergeOffset: 10_000) == nil)
    }

    @Test func aCarThatWillMeetAlongTheWayAlsoSeesTheNextStopBeforeLeave() throws {
        var meet = stop("Petronas Sungai Buloh", 0)
        meet.kind = .meet
        let stops = [meet, stop("Tapah", 60_000)]
        #expect(NextStop.joiningCell(stops: stops, distance: 9_000, seconds: 420, mergeOffset: 10_000, pace: 0.05, skipsMeet: false)?.name
            == "Petronas Sungai Buloh")
        #expect(NextStop.joiningCell(stops: stops, distance: 9_000, seconds: 420, mergeOffset: 10_000, pace: 0.05, skipsMeet: true)?.name
            == "Tapah")
    }

    @Test func noMeetingAlongTheWayButtonOnceTheMeetingPointWasLeft() {
        var meet = stop("m", 0)
        meet.kind = .meet
        #expect(SkipAnswers.canSkip(stop: meet, isLeadCar: false, carOffset: nil, tripStarted: true, isJoining: true))
        meet.leftAt = Date(timeIntervalSince1970: 1_000)
        meet.leftBy = "u1"
        #expect(!SkipAnswers.canSkip(stop: meet, isLeadCar: false, carOffset: nil, tripStarted: true, isJoining: true))
    }
}
