import CoreLocation
import FirebaseFirestore
import Foundation
import Testing
@testable import ikut

private func fix(_ lon: Double = 0, speed: Double = 0) -> LocationFix {
    LocationFix(latitude: 0, longitude: lon, speed: speed, course: 90, timestamp: Date())
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

    @Test func aHeartbeatCarriesTheBatteryOfTheMoment() async {
        let p = make()
        var level = 0.8
        p.refresh = { old in
            var p = old
            p.battery = level
            return p
        }
        p.submit(position(1, battery: 0.8))
        await settle()
        level = 0.5
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
        await deliver(fix(farEast, speed: -1))  // a cell fix 167 m away, no speed
        #expect(service.power == .full)
        #expect(source.powers == [.low, .full])
        #expect(writer.written.count == before + 1)
        #expect(writer.written.last?.location.longitude == farEast)
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

    /// The lead car's phone in low power: a drive-off reaches `MoveOff` as soon as the first coarse fix after 100 m
    /// brings full power back; the 500 m rule itself then needs the car to be seen moving.
    @Test func theLeadCarsMoveOffStillEndsThePhaseFromLowPower() async {
        let service = make()
        await deliver(fix(0))
        service.setConvoyStopped(true)
        await clock.advance(by: 125)
        #expect(service.power == .low)
        var moveOff = ConvoyStop.MoveOff()
        let since = Date(timeIntervalSince1970: 1_000)
        let here = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        // Heartbeats while parked: the same place, two minutes at rest, so the car has settled.
        let first = moveOff.check(phase: since, here: here, at: since.addingTimeInterval(0), moving: false)
        let second = moveOff.check(phase: since, here: here, at: since.addingTimeInterval(125), moving: false)
        #expect(!first && !second)
        await deliver(fix(farEast, speed: -1))
        #expect(service.power == .full)
        // Full-rate fixes from there: 50 m apart at 12 m/s.
        var ended = false
        for i in 1...20 where !ended {
            let lon = Double(i) * 0.0005 + farEast
            ended = moveOff.check(
                phase: since, here: CLLocationCoordinate2D(latitude: 0, longitude: lon),
                at: since.addingTimeInterval(125 + Double(i) * 4), moving: true)
        }
        #expect(ended)
    }
}

// MARK: - Session wiring and the screen

@MainActor
struct StoppedBatteryScreenTests {
    @Test func theScreenMaySleepWhileTheConvoyIsStopped() {
        #expect(ScreenAwake.shouldHold(preference: true, onScreen: true, tripRunning: true, appActive: true))
        #expect(!ScreenAwake.shouldHold(
            preference: true, onScreen: true, tripRunning: true, appActive: true, convoyStopped: true))
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
