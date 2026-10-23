import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("Who is at a stop")
struct StopArrivalTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    // A stop 20 km along a line running due north from (3, 101): 1 degree of latitude is about 111 km.
    let stopOffset = 20_000.0
    var target: StopArrival.Target { .init(latitude: 3 + stopOffset / 111_195, longitude: 101, routeOffset: stopOffset) }

    func position(offset: Double?, age: TimeInterval = 5, along: Double? = nil) -> Position {
        let meters = along ?? offset ?? 0
        return Position(
            id: nil, location: GeoPoint(latitude: 3 + meters / 111_195, longitude: 101), speed: 25, heading: 0,
            routeOffset: offset ?? 0, convoyOffset: offset, battery: 0.8, updatedAt: now.addingTimeInterval(-age))
    }

    func car(_ id: String, number: Int, joining: Bool = false) -> Car {
        Car(id: id, name: "Car \(number)", color: "#2563EB", trackerUserId: "u-\(id)", isLead: number == 1, route: nil,
            mergeOffset: nil, state: joining ? .joining : .convoy, number: number)
    }

    func status(_ offset: Double?, age: TimeInterval = 5, pace: Double? = 0.04) -> StopArrival.Status {
        StopArrival.status(
            position: position(offset: offset, age: age), offset: offset, target: target, pace: pace, speed: 25, now: now)
    }

    @Test func hereWithin150MetersEitherSide() {
        #expect(status(stopOffset - 149) == .here)
        #expect(status(stopOffset + 149) == .here)
        #expect(status(stopOffset) == .here)
        #expect(status(stopOffset - 200) != .here)
        #expect(status(stopOffset + 200) != .here)
    }

    @Test func aStaleFixIsNeverHere() {
        // Exactly at the stop, but the last fix is 61 s old.
        #expect(status(stopOffset, age: 61) != .here)
        #expect(status(stopOffset, age: 60) == .here)
        if case .away(let distance, _) = status(stopOffset, age: 300) { #expect(distance == 0) } else { Issue.record("expected away") }
    }

    @Test func minutesAwayFromOffsetAndPace() {
        // 3 km short at 0.06 s/m: 180 s, "3 min away".
        let s = status(stopOffset - 3_000, pace: 0.06)
        #expect(s == .away(distance: 3_000, seconds: 180))
        #expect(StopArrival.words(s) == "3 min away")
        // No pace from the viewer: the car's own speed, 25 m/s: 120 s.
        let own = status(stopOffset - 3_000, pace: nil)
        #expect(own == .away(distance: 3_000, seconds: 120))
    }

    @Test func aJoiningCarAtTheMeetingPointUsesItsTimeToMerge() {
        let meet = StopArrival.Target(latitude: target.latitude, longitude: 101, routeOffset: 0, isMeeting: true)
        let far = position(offset: nil, along: stopOffset - 9_000)
        let away = StopArrival.status(
            position: far, offset: nil, target: meet, pace: 0.04, speed: 25, timeToMerge: 420, now: now)
        #expect(away == .away(distance: 9_000, seconds: 420) || { if case .away(_, 420) = away { true } else { false } }())
        #expect(StopArrival.words(away) == "7 min away")
        // Within 150 m of the meeting point on a fresh fix, the joining car is here without a main-route offset.
        let near = StopArrival.status(
            position: position(offset: nil, along: stopOffset - 100), offset: nil, target: meet, pace: nil, speed: 25,
            timeToMerge: 5, now: now)
        #expect(near == .here)
        // No time to merge: a straight line over the viewer's pace.
        let noTime = StopArrival.status(
            position: far, offset: nil, target: meet, pace: 0.04, speed: 25, timeToMerge: nil, now: now)
        if case .away(_, let seconds?) = noTime { #expect(abs(seconds - 360) < 5) } else { Issue.record("expected a time") }
    }

    @Test func noPositionIsUnknownAndNeverHere() {
        let s = StopArrival.status(position: nil, offset: nil, target: target, pace: 0.04, speed: 25, now: now)
        #expect(s == .unknown)
        #expect(StopArrival.words(s) == "Waiting for location")
    }

    @Test func threeOfFourHereCountsEveryCarOnce() {
        let cars = [car("c1", number: 1), car("c2", number: 2), car("c3", number: 3, joining: true), car("c4", number: 4)]
        let positions = [
            "c1": position(offset: stopOffset), "c2": position(offset: stopOffset - 80),
            // The joining car has pulled in on its own road: within 150 m, no main-route offset.
            "c3": position(offset: nil, along: stopOffset + 30),
            "c4": position(offset: stopOffset - 2_000),
        ]
        let snapshot = ConvoyOrdering.order(cars: cars, positions: positions, now: now)
        let tally = StopArrival.tally(
            target: target, convoy: snapshot.convoy, joining: snapshot.joining, pace: 0.06, now: now)
        #expect(tally.total == 4)
        #expect(tally.title == "3 of 4 here")
        #expect(tally.rows.map(\.id) == ["c1", "c2", "c3", "c4"])
        #expect(tally.rows.map(\.isHere) == [true, true, true, false])
        #expect(StopArrival.words(tally.rows[3].status) == "2 min away")
        #expect(!tally.allHere)
    }

    @Test func allHereAndAJoinerWithNoPosition() {
        let cars = [car("c1", number: 1), car("c2", number: 2, joining: true)]
        let snapshot = ConvoyOrdering.order(cars: cars, positions: ["c1": position(offset: stopOffset)], now: now)
        let tally = StopArrival.tally(
            target: target, convoy: snapshot.convoy, joining: snapshot.joining, pace: nil, now: now)
        #expect(tally.title == "1 of 2 here")
        #expect(tally.rows[1].status == .unknown)
        let done = ConvoyOrdering.order(
            cars: cars, positions: ["c1": position(offset: stopOffset), "c2": position(offset: nil, along: stopOffset)], now: now)
        #expect(StopArrival.tally(target: target, convoy: done.convoy, joining: done.joining, pace: nil, now: now).allHere)
    }

    @Test func aSkippedStopHasNoCard() {
        func stop(_ id: String, _ offset: Double, skipped: Bool = false) -> PlannedStop {
            var s = PlannedStop(
                id: nil, name: id, coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: offset, kind: .fuel,
                minutes: nil, order: 0, skipped: skipped ? true : nil)
            s.id = id
            return s
        }
        let stops = [stop("a", 10_000), stop("b", 20_000, skipped: true), stop("c", 30_000)]
        #expect(StopArrival.target(stopId: "a", in: stops)?.routeOffset == 10_000)
        #expect(StopArrival.target(stopId: "b", in: stops) == nil)
        #expect(StopArrival.target(stopId: "zzz", in: stops) == nil)
        // "stop 2 of 2" for c: the skipped one is not counted.
        let place = StopArrival.place(of: "c", in: stops)
        #expect(place?.index == 2 && place?.count == 2)
        #expect(StopArrival.place(of: "b", in: stops) == nil)
    }

    @Test func aMeetingStopMakesAMeetingTarget() {
        var s = PlannedStop(
            id: "m", name: "Petronas", coordinate: GeoPoint(latitude: 3, longitude: 101), routeOffset: 0, kind: .meet,
            minutes: nil, order: 0)
        s.id = "m"
        #expect(StopArrival.target(stopId: "m", in: [s])?.isMeeting == true)
    }
}
