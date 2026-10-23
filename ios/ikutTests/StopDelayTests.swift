import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

@Suite("ETAs with planned stops")
struct StopDelayTests {
    static let now = Fixtures.t0
    static let pace = 0.1

    func stop(
        _ name: String, _ offset: Double, minutes: Int? = nil, kind: PlannedStopKind = .fuel, meetAt: Date? = nil,
        arrivedAt: Date? = nil, left: Bool = false, skipped: Bool = false
    ) -> PlannedStop {
        var s = PlannedStop(
            id: name, name: name, coordinate: GeoPoint(latitude: 0, longitude: 0), routeOffset: offset, kind: kind,
            minutes: minutes, meetAt: meetAt, order: 0, skipped: skipped ? true : nil, arrivedAt: arrivedAt)
        if left { s.leftAt = Self.now; s.leftBy = "u1" }
        return s
    }

    func extra(_ stops: [PlannedStop], from offset: Double = 0, pace: Double? = pace) -> TimeInterval {
        StopDelay.seconds(stops: stops, from: offset, now: Self.now, pace: pace)
    }

    @Test func noStopsAddNothing() { #expect(extra([]) == 0) }

    @Test func twoStopsAheadAddTheirLengths() {
        #expect(extra([stop("A", 10_000, minutes: 20), stop("B", 20_000, minutes: 15)]) == 35 * 60)
    }

    @Test func aStopWithNoLengthAddsNothing() { #expect(extra([stop("A", 10_000)]) == 0) }

    @Test func aPassedStopIsNotCounted() {
        let stops = [stop("Passed", 5_000, minutes: 20), stop("Ahead", 30_000, minutes: 15)]
        #expect(extra(stops, from: 10_000) == 15 * 60)
    }

    @Test func aSkippedOrLeftStopIsNotCounted() {
        let stops = [
            stop("Skipped", 10_000, minutes: 20, skipped: true), stop("Left", 12_000, minutes: 30, left: true),
            stop("Open", 14_000, minutes: 10),
        ]
        #expect(extra(stops) == 10 * 60)
    }

    @Test func atAStopCountsWhatIsLeftOfIt() {
        // Arrived 5 minutes ago with 20 planned: 15 minutes left, not 20.
        let here = stop("Here", 10_000, minutes: 20, arrivedAt: Self.now.addingTimeInterval(-300))
        #expect(extra([here, stop("Next", 20_000, minutes: 10)], from: 10_000) == 25 * 60)
        // Past its time (the lead car has not tapped Leave): nothing left, not negative.
        let over = stop("Over", 10_000, minutes: 20, arrivedAt: Self.now.addingTimeInterval(-1500))
        #expect(extra([over], from: 10_000) == 0)
    }

    @Test func aMeetingPointLaterThanTheDriveAddsTheWait() {
        // 1 000 m at 0.1 s/m is 100 s; meeting in 10 minutes waits 500 s more.
        let meet = stop("Meet", 1_000, kind: .meet, meetAt: Self.now.addingTimeInterval(600))
        #expect(extra([meet]) == 500)
        // Reached after the meeting time: no wait.
        #expect(extra([meet.with(meetAt: Self.now.addingTimeInterval(60))]) == 0)
        // Without a pace the drive is unknown: not counted.
        #expect(extra([meet], pace: nil) == 0)
    }

    @Test func aCarPastTheFirstStopCountsOnlyTheRest() {
        let stops = [stop("Meet", 0, kind: .meet, meetAt: Self.now.addingTimeInterval(600)), stop("R&R", 8_000, minutes: 20)]
        #expect(extra(stops, from: 3_000) == 20 * 60)
    }

    @Test func theNextStopCellWaitsForTheMeetingTime() throws {
        let meet = stop("Meet", 1_000, kind: .meet, meetAt: Self.now.addingTimeInterval(600))
        let cell = try #require(NextStop.cell(stops: [meet], offset: 0, pace: Self.pace, now: Self.now))
        #expect(cell.seconds == 600)
        let early = try #require(NextStop.cell(stops: [meet], offset: 0, pace: Self.pace))
        #expect(early.seconds == 100)
        let fuel = stop("Tapah", 5_000, minutes: 20)
        #expect(NextStop.cell(stops: [fuel], offset: 0, pace: Self.pace, now: Self.now)?.seconds == 500)
    }
}

private extension PlannedStop {
    func with(meetAt: Date) -> PlannedStop { var s = self; s.meetAt = meetAt; return s }
}

@Suite("The panel's arrival with stops")
@MainActor
struct StopETAModelTests {
    private struct Fixed: ETAProviding {
        func travelTime(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TimeInterval { 1800 }
    }

    private func model() -> ConvoyModel {
        let origin = CLLocationCoordinate2D(latitude: 3.0, longitude: 101.0)
        let route = RouteLine((0...20).map { i in
            CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude + Double(i) * 1000 / 111_320) })
        let m = ConvoyModel(provider: Fixed(), clock: { Fixtures.t0 })
        m.setMainRoute(route)
        let at = route.coordinate(atOffset: 10_000)!
        let position = Position(
            location: GeoPoint(latitude: at.latitude, longitude: at.longitude), speed: 25, heading: 90,
            routeOffset: 10_000, convoyOffset: 10_000, battery: nil, updatedAt: Fixtures.t0)
        let car = Car(id: "1", name: "Car 1", color: "#2563EB", trackerUserId: nil, isLead: true, route: nil,
                      mergeOffset: nil, state: .convoy, number: 1)
        m.update(cars: [car], positions: ["1": position])
        return m
    }

    private func planned(_ id: String, _ offset: Double, _ minutes: Int) -> PlannedStop {
        PlannedStop(id: id, name: id, coordinate: GeoPoint(latitude: 0, longitude: 0), routeOffset: offset,
                    kind: .fuel, minutes: minutes, order: 0)
    }

    @Test func destinationArrivalIncludesTheStopsAhead() async {
        let m = model()
        await m.waitForETA()
        let drive = Fixtures.t0.addingTimeInterval(1800)
        #expect(m.arrival(forCar: "1") == drive)
        m.setStops([planned("a", 12_000, 20), planned("b", 15_000, 15), planned("passed", 5_000, 30)])
        let withStops = m.arrival(forCar: "1")?.timeIntervalSince(drive) ?? 0
        #expect(abs(withStops - 35 * 60) < 0.01)
        #expect(m.driveArrival(forCar: "1") == drive)
    }
}
